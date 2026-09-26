defmodule Imp.SavingReqLLMTransportTest do
  use ExUnit.Case, async: false

  @fused_path "/tmp/imp-retained-training/fused"
  @transport_opts [
    cache: false,
    temperature: 0,
    seed: 17,
    max_tokens: 32,
    max_retries: 0,
    timeout: 120_000,
    req_http_options: [retry: false, max_retries: 0]
  ]

  test "exact stopped MLX program shape round-trips with strict no-retry options" do
    program = stopped_program_shape()

    dumped = program |> Imp.dump() |> json_round_trip()

    assert get_in(dumped, ["lm", "opts"]) == [
             ["cache", false],
             ["temperature", 0],
             ["seed", 17],
             ["max_tokens", 32],
             ["max_retries", 0],
             ["timeout", 120_000],
             ["req_http_options", [["retry", false], ["max_retries", 0]]]
           ]

    loaded = Imp.load!(dumped)

    assert loaded.config == [json_fallback: false]
    assert loaded.lm.opts == @transport_opts
    assert loaded.lm.model["id"] == @fused_path
    assert loaded.lm.model["model"] == @fused_path
  end

  test "saved strict no-retry ReqLLM program loads in a fresh BEAM" do
    root = tmp_dir("fresh-beam")
    artifact = Path.join(root, "program.json")
    receipt = Path.join(root, "receipt.bin")
    :ok = Imp.save!(stopped_program_shape(), artifact)

    code = """
    loaded = Imp.read!(#{inspect(artifact)})
    lm = Imp.ProgramAccess.lm(loaded)
    File.write!(#{inspect(receipt)}, :erlang.term_to_binary({lm.model, lm.opts, loaded.config}, [:deterministic]))
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    {model, opts, config} = receipt |> File.read!() |> :erlang.binary_to_term([:safe])
    assert model["id"] == @fused_path
    assert model["model"] == @fused_path
    assert opts == @transport_opts
    assert config == [json_fallback: false]
  end

  test "saved ReqLLM input envelope round-trips without admitting unknown keys" do
    program =
      Imp.predict("question -> answer",
        lm:
          Imp.req_llm("openai:gpt-test",
            input_envelope: [max_bytes: 8_192, reservation_tokens: 4_096]
          )
      )

    dumped = program |> Imp.dump() |> json_round_trip()
    loaded = Imp.load!(dumped)

    assert loaded.lm.opts[:input_envelope] == [max_bytes: 8_192, reservation_tokens: 4_096]

    opts = get_in(dumped, ["lm", "opts"])

    assert_raise ArgumentError, ~r/unknown saved ReqLLM input_envelope key/, fn ->
      dumped
      |> put_in(
        ["lm", "opts"],
        replace_option(opts, "input_envelope", [
          ["max_bytes", 8_192],
          ["tokenizer", "untrusted"]
        ])
      )
      |> Imp.load!()
    end
  end

  test "saved reasoning effort round-trips and remains narrowly allowlisted" do
    program =
      Imp.predict("question -> answer",
        lm:
          Imp.req_llm("openrouter:provider/model",
            reasoning_effort: :high,
            openrouter_reasoning_wire: :nested
          )
      )

    dumped = program |> Imp.dump() |> json_round_trip()
    loaded = Imp.load!(dumped)
    assert loaded.lm.opts[:reasoning_effort] == "high"
    assert loaded.lm.opts[:openrouter_reasoning_wire] == :nested

    root = tmp_dir("openrouter-reasoning-fresh-beam")
    artifact = Path.join(root, "program.json")
    receipt = Path.join(root, "receipt.bin")
    :ok = Imp.save!(program, artifact)

    code = """
    loaded = Imp.read!(#{inspect(artifact)})
    File.write!(#{inspect(receipt)}, :erlang.term_to_binary(Imp.ProgramAccess.lm(loaded).opts, [:deterministic]))
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    fresh_opts = receipt |> File.read!() |> :erlang.binary_to_term([:safe])
    assert fresh_opts[:reasoning_effort] == "high"

    opts = get_in(dumped, ["lm", "opts"])

    for invalid <- ["invented", ["high"], %{"effort" => "high"}, 3] do
      assert_raise ArgumentError, ~r/reasoning_effort/, fn ->
        dumped
        |> put_in(["lm", "opts"], replace_option(opts, "reasoning_effort", invalid))
        |> Imp.load!()
      end
    end

    for invalid <- ["sideways", ["nested"], 1] do
      assert_raise ArgumentError, ~r/openrouter_reasoning_wire/, fn ->
        dumped
        |> put_in(["lm", "opts"], replace_option(opts, "openrouter_reasoning_wire", invalid))
        |> Imp.load!()
      end
    end
  end

  test "unknown and malformed saved ReqLLM transport options fail closed" do
    dumped = stopped_program_shape() |> Imp.dump() |> json_round_trip()
    opts = get_in(dumped, ["lm", "opts"])
    unknown_key = "imp_unknown_saved_option_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert_raise ArgumentError, ~r/unknown saved ReqLLM options key/, fn ->
      dumped
      |> put_in(["lm", "opts"], opts ++ [[unknown_key, true]])
      |> Imp.load!()
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert_raise ArgumentError, ~r/saved ReqLLM max_retries must be a non-negative integer/, fn ->
      dumped
      |> put_in(["lm", "opts"], replace_option(opts, "max_retries", "0"))
      |> Imp.load!()
    end

    assert_raise ArgumentError, ~r/saved ReqLLM seed must be a positive integer/, fn ->
      dumped
      |> put_in(["lm", "opts"], replace_option(opts, "seed", 0))
      |> Imp.load!()
    end

    assert_raise ArgumentError,
                 ~r/unknown saved ReqLLM req_http_options key: "adapter"/,
                 fn ->
                   dumped
                   |> put_req_http_options([["retry", false], ["adapter", "unsafe"]])
                   |> Imp.load!()
                 end

    assert_raise ArgumentError,
                 ~r/saved ReqLLM req_http_options retry must be a boolean/,
                 fn ->
                   dumped
                   |> put_req_http_options([["retry", "false"], ["max_retries", 0]])
                   |> Imp.load!()
                 end

    assert_raise ArgumentError, ~r/duplicate saved ReqLLM req_http_options key/, fn ->
      dumped
      |> put_req_http_options([["retry", false], ["retry", false], ["max_retries", 0]])
      |> Imp.load!()
    end

    assert_raise ArgumentError, ~r/saved ReqLLM req_http_options must be a list/, fn ->
      dumped
      |> put_in(["lm", "opts"], replace_option(opts, "req_http_options", %{"retry" => false}))
      |> Imp.load!()
    end
  end

  # An atom tag the VM does not know loads as its text: loading creates no
  # atom, and a saved program still loads in a VM that never created the names
  # its metadata carries (an optimizer report repeats its demos' field names).
  test "fresh-program metadata creates no atom from an unknown atom tag" do
    dumped = stopped_program_shape() |> Imp.dump() |> json_round_trip()
    unknown = "imp_unknown_training_metadata_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    poisoned =
      update_in(dumped, ["metadata", "entries"], fn entries ->
        entries ++ [[%{"__imp_type__" => "atom", "value" => unknown}, "unsafe"]]
      end)

    loaded = Imp.load!(poisoned)
    assert loaded.metadata[unknown] == "unsafe"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  defp stopped_program_shape do
    model = %{
      provider: :openai,
      id: @fused_path,
      model: @fused_path,
      base_url: "http://127.0.0.1:18822/v1",
      extra: %{openai_compatible_backend: :mlx_lm}
    }

    lm = Imp.req_llm(model, opts: @transport_opts)

    "utterance -> route: enum[R17,R42,R68,R93]"
    |> Imp.predict(
      lm: lm,
      adapter: Imp.Adapter.Chat,
      config: [json_fallback: false]
    )
    |> Imp.ProgramAccess.put_metadata(:training_artifact, %{
      job_id: "mlx-retained-job",
      provider: :mlx_lm,
      base_model: "mlx-community/Qwen2.5-0.5B-Instruct-4bit@pinned",
      result_model: @fused_path,
      artifact_sha256: "d52aca6b:049e9e01:5b0934bc:56e4a120:a6d669fb:21bc5c70:68c527e0:f994dc44"
    })
  end

  defp put_req_http_options(dumped, http_options) do
    update_in(dumped, ["lm", "opts"], fn opts ->
      Enum.map(opts, fn
        ["req_http_options", _old] -> ["req_http_options", http_options]
        entry -> entry
      end)
    end)
  end

  defp replace_option(opts, key, value) do
    Enum.map(opts, fn
      [^key, _old] -> [key, value]
      entry -> entry
    end)
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp tmp_dir(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-saving-req-llm-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end

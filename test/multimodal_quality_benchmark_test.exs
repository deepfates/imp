defmodule MultimodalQualityBenchmarkTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.MultimodalCheckpoint, as: Checkpoint
  alias DSEx.BenchmarkTruth.MultimodalManifest, as: Manifest
  alias DSEx.BenchmarkTruth.MultimodalRunner, as: Runner

  @manifest "benchmarks/data/multimodal/manifest.json"
  @openai_manifest "benchmarks/data/multimodal/openai-responses-manifest.json"
  @secret "gemini-test-secret-that-must-never-persist"

  defmodule UnsafeProviderError do
    defexception [:message, :status, :response_body]
  end

  defmodule ProviderFake do
    def generate_text(model, messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      mode = Keyword.get(opts, :fake_mode, :pass)
      send(test_pid, {:provider_dispatch, model, messages, opts})

      text =
        messages
        |> List.last()
        |> Map.fetch!(:content)
        |> Enum.filter(&(&1.type == :text))
        |> Enum.map_join("", & &1.text)

      cond do
        mode == :capability_error ->
          {:error, {:unsupported_capability, "PDF file input is unsupported"}}

        mode == :unsafe_exception ->
          {:error,
           %UnsafeProviderError{
             message: "provider rejected credential #{Keyword.fetch!(opts, :api_key)}",
             status: 400,
             response_body: ["improper" | :tail]
           }}

        true ->
          answer = answer(text, mode)

          body =
            if mode == :malformed_output,
              do: "answer=#{answer}",
              else: Jason.encode!(%{"answer" => answer})

          usage =
            if mode == :malformed_usage,
              do: %{input_tokens: 100},
              else: %{input_tokens: 100, output_tokens: 5}

          {:ok,
           %ReqLLM.Response{
             id: "fake-multimodal-response",
             model: model_name(model),
             context: ReqLLM.Context.new(messages),
             message: ReqLLM.Context.assistant(body),
             object: nil,
             usage: usage,
             finish_reason: :stop,
             provider_meta: %{api_type: api_type(model)}
           }}
      end
    end

    defp model_name("openai:" <> model), do: model
    defp model_name("google:" <> model), do: model
    defp api_type("openai:" <> _model), do: "responses"
    defp api_type("google:" <> _model), do: "generateContent"

    defp answer(text, mode) do
      answer =
        cond do
          String.contains?(text, "How many blue circles") -> 3
          String.contains?(text, "left or right") -> "left"
          String.contains?(text, "BATCH CODE") -> "MINT-47"
          String.contains?(text, "BIN value") -> "C-12"
          String.contains?(text, "sum their Units") -> 35
          String.contains?(text, "which owner") -> "Priya"
        end

      if mode == :wrong_document and String.contains?(text, "attached synthetic PDF"),
        do: "wrong",
        else: answer
    end
  end

  test "plan validates assets and records redacted shapes without provider calls or claims" do
    artifact = Runner.run(mode: :plan, manifest: @manifest, max_concurrency: 2)

    assert artifact["mode"] == "plan"

    assert artifact["summary"] == %{
             "complete" => true,
             "failed" => 6,
             "passed" => 0,
             "total" => 6
           }

    refute artifact["claims"]["image_quality"]
    refute artifact["claims"]["document_quality"]
    refute artifact["claims"]["native_file_support"]

    assert artifact["claims"]["audio"] == %{
             "claimed" => false,
             "status" => "unsupported_unproven"
           }

    refute_received {:provider_dispatch, _, _, _}

    encoded = Jason.encode!(artifact)
    refute encoded =~ "data:image"
    refute encoded =~ "base64"
  end

  test "provider-shaped live fake proves typed image and native PDF dispatch with exact accounting" do
    checkpoint = tmp_path("passing-checkpoint.json")

    artifact =
      live_run(checkpoint,
        max_concurrency: 2,
        client_opts: [test_pid: self(), fake_mode: :pass]
      )

    assert artifact["claims"]["multimodal_quality"]
    assert artifact["claims"]["image_quality"]
    assert artifact["claims"]["document_quality"]
    assert artifact["claims"]["native_file_support"]
    assert artifact["families"]["image"]["score"] == 1.0
    assert artifact["families"]["native_document"]["score"] == 1.0

    assert artifact["usage"] == %{
             "cost" => %{"total_nano_usd" => 255_000, "total_usd" => "0.000255000"},
             "input_tokens" => 600,
             "output_tokens" => 30,
             "total_tokens" => 630
           }

    dispatches = collect_dispatches(6)

    assert Enum.all?(dispatches, fn {model, _message, opts} ->
             model == "google:gemini-2.5-flash" and Keyword.fetch!(opts, :temperature) == 0
           end)

    parts =
      Enum.map(dispatches, fn {_model, message, _opts} -> message.content |> List.first() end)

    image_parts = Enum.filter(parts, &(&1.type == :image_url))
    file_parts = Enum.filter(parts, &(&1.type == :file))

    assert length(image_parts) == 4
    assert Enum.all?(image_parts, &String.starts_with?(&1.url, "data:image/png;base64,"))
    assert length(file_parts) == 2

    assert Enum.all?(
             file_parts,
             &(&1.media_type == "application/pdf" and String.starts_with?(&1.data, "%PDF-"))
           )

    encoded = Jason.encode!(artifact)
    refute encoded =~ @secret
    refute encoded =~ "data:image/png;base64"
    refute encoded =~ Base.encode64(File.read!("benchmarks/data/multimodal/project-register.pdf"))
    refute File.read!(checkpoint) =~ @secret
  end

  test "OpenAI Responses profile requires exact API identity and dispatches supported image and PDF parts" do
    artifact =
      live_run(tmp_path("openai-profile.json"),
        manifest: @openai_manifest,
        client_opts: [test_pid: self(), fake_mode: :pass]
      )

    assert artifact["provider"]["profile"] ==
             "openai-gpt-4.1-mini-2025-04-14-responses"

    assert artifact["claims"]["multimodal_quality"]

    dispatches = collect_dispatches(6)

    assert Enum.all?(dispatches, fn {model, _message, opts} ->
             model == "openai:gpt-4.1-mini-2025-04-14" and
               Keyword.fetch!(opts, :temperature) == 0 and
               not Keyword.has_key?(opts, :seed) and
               not Keyword.has_key?(opts, :top_p)
           end)

    assert Enum.all?(artifact["rows"], fn row ->
             row["effective_model"] == "gpt-4.1-mini-2025-04-14" and
               row["effective_api"] == "responses" and
               row["effective_api_evidence"] == "provider_response_metadata"
           end)
  end

  test "exception structs become redacted structured provider failures without crashing scrubber" do
    artifact =
      live_run(tmp_path("structured-provider-error.json"),
        client_opts: [test_pid: self(), fake_mode: :unsafe_exception]
      )

    assert Enum.all?(artifact["rows"], &(&1["outcome"] == "provider_error"))

    assert Enum.all?(artifact["rows"], fn row ->
             row["failure"] == %{
               "category" => "MultimodalQualityBenchmarkTest.UnsafeProviderError",
               "exception" => "MultimodalQualityBenchmarkTest.UnsafeProviderError",
               "http_status" => 400,
               "message" => "provider rejected credential [REDACTED]",
               "provider_code" => nil,
               "request_id" => nil
             }
           end)

    refute Jason.encode!(artifact) =~ @secret
  end

  test "asset drift and manifest tampering fail before dispatch" do
    manifest = Manifest.load!(@manifest)

    drifted =
      put_in(manifest.payload, ["assets", "shape_board", "sha256"], String.duplicate("0", 64))

    assert_raise ArgumentError, ~r/asset drift detected/, fn -> Manifest.validate!(drifted) end

    tampered_path = tmp_path("tampered-manifest.json")

    @manifest
    |> File.read!()
    |> String.replace("image_shape_count_blue_circles", "image_shape_count_blue_circlez",
      global: false
    )
    |> then(&File.write!(tampered_path, &1))

    assert_raise ArgumentError, ~r/manifest checksum mismatch/, fn ->
      Manifest.load!(tampered_path)
    end

    refute_received {:provider_dispatch, _, _, _}
  end

  test "unsupported preregistered capability and provider capability errors fail closed" do
    manifest = Manifest.load!(@manifest)
    unsupported = put_in(manifest.payload, ["provider", "capabilities", "native_pdf"], false)

    assert_raise ArgumentError, ~r/capabilities.native_pdf/, fn ->
      Manifest.validate!(unsupported)
    end

    artifact =
      live_run(tmp_path("capability-checkpoint.json"),
        client_opts: [test_pid: self(), fake_mode: :capability_error]
      )

    assert Enum.all?(artifact["rows"], &(&1["outcome"] == "capability_error"))
    refute artifact["claims"]["multimodal_quality"]
    refute artifact["claims"]["native_file_support"]
  end

  test "malformed output and malformed usage are retained as failures" do
    malformed =
      live_run(tmp_path("malformed-output.json"),
        client_opts: [test_pid: self(), fake_mode: :malformed_output]
      )

    assert Enum.all?(malformed["rows"], &(&1["outcome"] == "malformed_output"))
    refute malformed["claims"]["multimodal_quality"]
    collect_dispatches(6)

    bad_usage =
      live_run(tmp_path("malformed-usage.json"),
        client_opts: [test_pid: self(), fake_mode: :malformed_usage]
      )

    assert Enum.all?(bad_usage["rows"], &(&1["outcome"] == "malformed_usage"))
    assert bad_usage["usage"]["total_tokens"] == 0
    refute bad_usage["claims"]["multimodal_quality"]
  end

  test "a document-family failure suppresses image and document claims together" do
    artifact =
      live_run(tmp_path("false-claim-checkpoint.json"),
        client_opts: [test_pid: self(), fake_mode: :wrong_document]
      )

    assert artifact["families"]["image"]["passing"]
    refute artifact["families"]["native_document"]["passing"]
    refute artifact["claims"]["image_quality"]
    refute artifact["claims"]["document_quality"]
    refute artifact["claims"]["multimodal_quality"]
    refute artifact["claims"]["native_file_support"]
  end

  test "durable completed rows resume after a controlled crash without redispatch" do
    checkpoint = tmp_path("crash-resume.json")

    assert_raise RuntimeError, ~r/injected multimodal runner crash/, fn ->
      live_run(checkpoint,
        max_concurrency: 1,
        crash_after_rows: 1,
        client_opts: [test_pid: self(), fake_mode: :pass]
      )
    end

    assert length(collect_dispatches(1)) == 1

    artifact =
      live_run(checkpoint,
        max_concurrency: 1,
        client_opts: [test_pid: self(), fake_mode: :pass]
      )

    assert artifact["summary"]["passed"] == 6
    assert length(collect_dispatches(5)) == 5
    refute_received {:provider_dispatch, _, _, _}
  end

  test "unresolved durable intent is ambiguous and resume refuses provider dispatch" do
    manifest = Manifest.load!(@manifest)
    checkpoint_path = tmp_path("ambiguous.json")
    provider = manifest.payload["provider"]

    identity = %{
      "api" => provider["api"],
      "campaign_id" => manifest.payload["campaign_id"],
      "generation" => provider["generation"],
      "manifest_sha256" => manifest.sha256,
      "req_llm_model" => provider["req_llm_model"]
    }

    checkpoint = Checkpoint.load!(checkpoint_path, identity)

    Checkpoint.record_intents!(checkpoint_path, checkpoint, [
      List.first(manifest.payload["samples"])
    ])

    assert_raise ArgumentError, ~r/ambiguous multimodal dispatch outcome/, fn ->
      live_run(checkpoint_path, client_opts: [test_pid: self(), fake_mode: :pass])
    end

    refute_received {:provider_dispatch, _, _, _}
  end

  defp live_run(checkpoint, opts) do
    {manifest, opts} = Keyword.pop(opts, :manifest, @manifest)

    Runner.run(
      [
        api_key: @secret,
        checkpoint: checkpoint,
        manifest: manifest,
        mode: :live,
        req_module: ProviderFake
      ] ++ opts
    )
  end

  defp collect_dispatches(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:provider_dispatch, model, [message], opts}, 1_000
      {model, message, opts}
    end)
  end

  defp tmp_path(name) do
    dir = Path.join(System.tmp_dir!(), "dsex-multimodal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end
end

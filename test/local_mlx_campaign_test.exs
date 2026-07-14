defmodule DSEx.BenchmarkTruth.LocalMLXCampaignTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.LocalMLXCampaign

  @artifact_path Path.expand(
                   "../benchmarks/results/local-mlx/local-mlx-ada199b-20260713.json",
                   __DIR__
                 )

  test "admits only complete matched improvement with fusion and save/load equivalence" do
    baseline = [row("one", "R17", "R42"), row("two", "R42", "R42")] |> expand_rows() |> result()
    trained = [row("one", "R17", "R17"), row("two", "R42", "R42")] |> expand_rows() |> result()

    assert %{
             "admissible" => true,
             "official_fusion_completed" => true,
             "save_load_equivalent" => true,
             "row_identity_preserved" => true
           } = LocalMLXCampaign.acceptance(baseline, trained, trained)

    malformed = put_in(trained, ["rows", Access.at(0), "status"], "error")
    refute LocalMLXCampaign.acceptance(baseline, malformed, trained)["admissible"]

    reordered = Map.update!(trained, "rows", &Enum.reverse/1)
    refute LocalMLXCampaign.acceptance(baseline, trained, reordered)["admissible"]
  end

  test "restores runtime credentials only when portable deployment configuration matches" do
    runtime_lm =
      DSEx.req_llm("openai:default_model",
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    loaded =
      DSEx.predict("question -> answer", lm: runtime_lm)
      |> DSEx.Saving.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> DSEx.Saving.load()

    refute Keyword.has_key?(DSEx.ProgramAccess.lm(loaded).opts, :api_key)

    restored = LocalMLXCampaign.restore_runtime_credentials!(loaded, runtime_lm)
    assert DSEx.ProgramAccess.lm(restored) == runtime_lm

    mismatched =
      DSEx.req_llm("openai:other_model",
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    assert_raise RuntimeError, ~r/changed its credential-free deployment LM/, fn ->
      LocalMLXCampaign.restore_runtime_credentials!(loaded, mismatched)
    end
  end

  test "restores an exact MLX path identity after secret-shaped persistence redaction" do
    run_id = String.duplicate("a", 64)
    model_path = "/private/tmp/dsex-mlx/#{run_id}/fused"

    runtime_lm =
      local_mlx_lm(model_path,
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    portable =
      DSEx.predict("question -> answer", lm: runtime_lm)
      |> DSEx.Saving.dump()
      |> Jason.encode!()
      |> Jason.decode!()

    assert get_in(portable, ["lm", "model", "id"]) == model_path
    assert get_in(portable, ["lm", "model", "model"]) == model_path

    loaded = DSEx.Saving.load(portable)

    restored = LocalMLXCampaign.restore_runtime_credentials!(loaded, runtime_lm)
    assert DSEx.ProgramAccess.lm(restored) == runtime_lm

    wrong_path =
      local_mlx_lm("/private/tmp/dsex-mlx/#{String.duplicate("b", 64)}/fused",
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    assert_raise RuntimeError, ~r/changed its credential-free deployment LM/, fn ->
      LocalMLXCampaign.restore_runtime_credentials!(loaded, wrong_path)
    end

    wrong_endpoint =
      local_mlx_lm(model_path,
        api_key: "local",
        base_url: "http://127.0.0.1:18822/v1"
      )

    assert_raise RuntimeError, ~r/changed its credential-free deployment LM/, fn ->
      LocalMLXCampaign.restore_runtime_credentials!(loaded, wrong_endpoint)
    end

    wrong_backend = %{
      runtime_lm
      | model: put_in(runtime_lm.model, [:extra, :openai_compatible_backend], :other_backend)
    }

    assert_raise RuntimeError, ~r/changed its credential-free deployment LM/, fn ->
      LocalMLXCampaign.restore_runtime_credentials!(loaded, wrong_backend)
    end
  end

  test "independently validates the committed canonical campaign artifact" do
    artifact = @artifact_path |> File.read!() |> Jason.decode!()
    assert {:ok, ^artifact} = LocalMLXCampaign.validate_artifact(artifact)

    tampered = put_in(artifact, ["fused", "accuracy"], 1.0)
    assert {:error, [:invalid_run_envelope]} = LocalMLXCampaign.validate_artifact(tampered)
  end

  test "rejects re-enveloped canonical, metric, fusion, and persistence forgeries" do
    artifact = @artifact_path |> File.read!() |> Jason.decode!()

    cases = [
      {[:canonical_dataset],
       &put_in(&1, ["dataset", "payload_sha256"], "sha256:" <> String.duplicate("0", 64))},
      {[:canonical_dataset], &put_in(&1, ["dataset", "file_sha256"], String.duplicate("0", 64))},
      {[:canonical_model],
       &put_in(&1, ["model", "tree", "files", Access.at(0), "sha256"], String.duplicate("0", 64))},
      {[:recomputed_acceptance, :recomputed_effect], &put_in(&1, ["fused", "accuracy"], 1.0)},
      {[:official_fusion, :recomputed_acceptance],
       &put_in(&1, ["fusion", "result", "exit_status"], 1)},
      {[:recomputed_acceptance],
       &put_in(&1, ["reloaded", "rows", Access.at(0), "actual"], "R42")},
      {[:recomputed_acceptance], &put_in(&1, ["acceptance", "admissible"], false)}
    ]

    for {expected_errors, mutate} <- cases do
      assert {:error, errors} =
               artifact |> reenvelope(mutate) |> LocalMLXCampaign.validate_artifact()

      assert Enum.all?(expected_errors, &(&1 in errors))
    end

    assert {:error, errors} =
             artifact
             |> reenvelope(& &1, "dirty")
             |> LocalMLXCampaign.validate_artifact()

    assert :clean_run in errors
  end

  test "accepts a written rejected artifact as valid evidence for Mix to reject" do
    artifact = @artifact_path |> File.read!() |> Jason.decode!()
    baseline = artifact["baseline"]
    acceptance = LocalMLXCampaign.acceptance(baseline, baseline, baseline)

    rejected =
      artifact
      |> reenvelope(fn value ->
        value
        |> Map.put("status", "rejected")
        |> Map.put("fused", baseline)
        |> Map.put("reloaded", baseline)
        |> Map.put("effect", %{"accuracy_delta" => 0.0, "macro_f1_delta" => 0.0})
        |> Map.put("acceptance", acceptance)
      end)

    assert rejected["status"] == "rejected"
    refute rejected["acceptance"]["admissible"]
    assert {:ok, ^rejected} = LocalMLXCampaign.validate_artifact(rejected)
  end

  test "validates the newly emitted observed adapter lane contract" do
    artifact = @artifact_path |> File.read!() |> Jason.decode!()
    base_server = get_in(artifact, ["baseline", "server"])
    model_id = base_server["advertised_model_path"]

    current_server =
      Map.merge(base_server, %{
        "adapter_path" => nil,
        "model_id" => model_id,
        "resolved_model_path" => model_id
      })

    adapter_server =
      Map.put(current_server, "adapter_path", artifact["training"]["job"]["result_model"])

    current =
      artifact
      |> put_in(["baseline", "server"], current_server)
      |> put_in(["fused", "server"], current_server)
      |> put_in(["reloaded", "server"], current_server)
      |> put_in(
        ["adapter_inference"],
        %{
          "status" => "observed_not_admitted",
          "reason" => "test",
          "server" => adapter_server
        }
      )
      |> reenvelope(& &1)

    assert {:ok, ^current} = LocalMLXCampaign.validate_artifact(current)
  end

  test "serves baseline, adapter, and fused lanes with exact model and adapter requests" do
    root = Path.join(System.tmp_dir!(), "dsex-fake-mlx-#{System.unique_integer([:positive])}")
    script = Path.join(root, "fake_mlx_server.py")
    port = free_port()
    File.mkdir_p!(root)
    File.write!(script, fake_mlx_server())
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    executable = System.find_executable("python3")
    assert is_binary(executable)

    lanes = [
      {"baseline", nil},
      {"adapter", Path.join(root, "adapter")},
      {"fused", nil}
    ]

    for {name, adapter_path} <- lanes do
      model_path = Path.join(root, name)
      File.mkdir_p!(model_path)
      if adapter_path, do: File.mkdir_p!(adapter_path)

      server =
        LocalMLXCampaign.exercise_server_lane_for_test!(
          model_path: model_path,
          adapter_path: adapter_path,
          port: port,
          executable: executable,
          executable_args: [script]
        )

      {expected_model, 0} = System.cmd("realpath", [model_path])
      expected_model = String.trim(expected_model)
      assert server["model_id"] == expected_model
      assert server["advertised_model_ids"] == ["wrong-first-model", expected_model]
      assert server["adapter_path"] == adapter_path
    end

    requests =
      root
      |> Path.join("requests.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    expected_models =
      Enum.map(lanes, fn {name, _adapter} ->
        {model, 0} = System.cmd("realpath", [Path.join(root, name)])
        String.trim(model)
      end)

    assert Enum.map(requests, & &1["model"]) == expected_models

    assert Enum.map(requests, &Map.get(&1, "adapters")) == [nil, Path.join(root, "adapter"), nil]
  end

  test "rejects an occupied selected port before inspecting campaign inputs" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert_raise RuntimeError, ~r/MLX campaign port #{port} is unavailable/, fn ->
      LocalMLXCampaign.run!(
        cwd: File.cwd!(),
        dataset: "missing-dataset.json",
        root: Path.join(System.tmp_dir!(), "unused-#{System.unique_integer([:positive])}"),
        artifact: Path.join(System.tmp_dir!(), "unused-artifact.json"),
        model_path: "missing-model",
        port: port,
        require_clean: false
      )
    end
  end

  defp row(id, expected, actual) do
    %{
      "id" => id,
      "expected" => expected,
      "actual" => actual,
      "status" => "ok",
      "correct" => expected == actual
    }
  end

  defp expand_rows(rows) do
    for repetition <- 0..19, row <- rows do
      Map.update!(row, "id", &"#{&1}-#{repetition}")
    end
  end

  defp result(rows) do
    correct = Enum.count(rows, & &1["correct"])

    %{
      "rows" => rows,
      "total" => length(rows),
      "correct" => correct,
      "failures" => 0,
      "accuracy" => correct / length(rows),
      "macro_f1" => macro_f1(rows)
    }
  end

  defp macro_f1(rows) do
    ["R17", "R42", "R68", "R93"]
    |> Enum.map(fn label ->
      tp = Enum.count(rows, &(&1["expected"] == label and &1["actual"] == label))
      fp = Enum.count(rows, &(&1["expected"] != label and &1["actual"] == label))
      fn_ = Enum.count(rows, &(&1["expected"] == label and &1["actual"] != label))
      if 2 * tp + fp + fn_ == 0, do: 0.0, else: 2 * tp / (2 * tp + fp + fn_)
    end)
    |> then(&(Enum.sum(&1) / 4))
  end

  defp reenvelope(artifact, mutate, workspace_state \\ "clean") do
    payload = artifact |> Map.drop(["generated_at", "git_sha", "run_context"]) |> mutate.()

    DSEx.BenchmarkTruth.RunContext.new!(
      source_commits: %{"dsex" => "deepfates/dsex@test-revision"},
      workspace_state: workspace_state
    )
    |> DSEx.BenchmarkTruth.RunContext.finish(payload)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp local_mlx_lm(model_path, opts) do
    model = %{
      provider: :openai,
      id: model_path,
      model: model_path,
      base_url: Keyword.fetch!(opts, :base_url),
      extra: %{openai_compatible_backend: :mlx_lm}
    }

    DSEx.req_llm(model, Keyword.delete(opts, :base_url))
  end

  defp fake_mlx_server do
    """
    import http.server
    import json
    import os
    import pathlib
    import sys

    args = sys.argv[1:]
    model = os.path.realpath(args[args.index("--model") + 1])
    port = int(args[args.index("--port") + 1])
    log_path = pathlib.Path(model).parent / "requests.jsonl"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def send_json(self, status, value):
            encoded = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            if self.path.startswith("/v1/models"):
                self.send_json(200, {"object": "list", "data": [
                    {"id": "wrong-first-model"}, {"id": model}
                ]})
            else:
                self.send_json(404, {"error": "not found"})

        def do_POST(self):
            length = int(self.headers["Content-Length"])
            body = json.loads(self.rfile.read(length).decode())
            with log_path.open("a") as log:
                log.write(json.dumps(body) + "\\n")
            self.send_json(200, {
                "id": "chatcmpl-fake",
                "object": "chat.completion",
                "model": body["model"],
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": "pong"},
                    "finish_reason": "stop"
                }],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
            })

    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
    """
  end
end

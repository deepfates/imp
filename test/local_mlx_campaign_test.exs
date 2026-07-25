defmodule Imp.BenchmarkTruth.LocalMLXCampaignTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.LocalMLXCampaign

  @artifact_path Path.expand(
                   "../benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json",
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
      Imp.req_llm("openai:default_model",
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    loaded =
      Imp.predict("question -> answer", lm: runtime_lm)
      |> Imp.Saving.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.Saving.load()

    refute Keyword.has_key?(Imp.ProgramAccess.lm(loaded).opts, :api_key)

    restored = LocalMLXCampaign.restore_runtime_credentials!(loaded, runtime_lm)
    assert Imp.ProgramAccess.lm(restored) == runtime_lm

    mismatched =
      Imp.req_llm("openai:other_model",
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    assert_raise RuntimeError, ~r/changed its credential-free deployment LM/, fn ->
      LocalMLXCampaign.restore_runtime_credentials!(loaded, mismatched)
    end
  end

  test "restores an exact MLX path identity after secret-shaped persistence redaction" do
    run_id = String.duplicate("a", 64)
    model_path = "/private/tmp/imp-mlx/#{run_id}/fused"

    runtime_lm =
      local_mlx_lm(model_path,
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    portable =
      Imp.predict("question -> answer", lm: runtime_lm)
      |> Imp.Saving.dump()
      |> Jason.encode!()
      |> Jason.decode!()

    assert get_in(portable, ["lm", "model", "id"]) == model_path
    assert get_in(portable, ["lm", "model", "model"]) == model_path

    loaded = Imp.Saving.load(portable)

    restored = LocalMLXCampaign.restore_runtime_credentials!(loaded, runtime_lm)
    assert Imp.ProgramAccess.lm(restored) == runtime_lm

    wrong_path =
      local_mlx_lm("/private/tmp/imp-mlx/#{String.duplicate("b", 64)}/fused",
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

  test "validates the current Imp artifact and evaluation contract identities" do
    artifact = @artifact_path |> File.read!() |> Jason.decode!()
    legacy_command = get_in(artifact, ["training", "manifest", "command"])
    adapter_digests = get_in(artifact, ["training", "job", "metadata", "artifact_sha256"])
    fused_tree = get_in(artifact, ["fusion", "tree"])

    current =
      reenvelope(artifact, fn value ->
        value
        |> Map.put("artifact_type", "imp_mlx_weight_training_campaign")
        |> put_in(["training", "manifest", "artifact_type"], "imp_mlx_lm_sft_run")
        |> put_in(["training", "manifest", "schema_version"], 2)
        |> put_in(["training", "manifest", "training_command"], legacy_command)
        |> put_in(["training", "manifest", "fused_tree"], fused_tree)
        |> put_in(["training", "manifest", "spec", "artifact_mode"], "fused_model")
        |> put_in(["training", "job", "metadata", "adapter_sha256"], adapter_digests)
        |> put_in(["evaluation_contract", "adapter"], "Imp.Adapter.Chat")
        |> put_in(
          ["evaluation_contract", "sha256"],
          "8d5ecfbe6b926ca5edf20d9d6a037579ba9ad23767f6a8aeee84e76613939cee"
        )
      end)

    assert {:ok, ^current} = LocalMLXCampaign.validate_artifact(current)
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
    legacy_adapter_path = get_in(artifact, ["training", "job", "result_model"])
    run_dir = Path.dirname(legacy_adapter_path)
    fused_path = Path.join(run_dir, "fused")
    adapter_path = Path.join(run_dir, "adapter")

    current_server =
      Map.merge(base_server, %{
        "adapter_path" => nil,
        "model_id" => model_id,
        "resolved_model_path" => model_id
      })

    adapter_server = Map.put(current_server, "adapter_path", adapter_path)

    current =
      artifact
      |> put_in(["training", "job", "result_model"], fused_path)
      |> put_in(["training", "job", "metadata", "adapter_path"], "../adapter")
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

  test "serves every lane without reusing a cache entry for redacted model paths" do
    root = Path.join(System.tmp_dir!(), "imp-fake-mlx-#{System.unique_integer([:positive])}")
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

    probe_messages = [%{role: :user, content: "probe"}]
    base_url = "http://127.0.0.1:#{port}/v1"

    baseline_lm = local_mlx_lm(Path.join(root, "baseline"), api_key: "local", base_url: base_url)
    fused_lm = local_mlx_lm(Path.join(root, "fused"), api_key: "local", base_url: base_url)

    refute Imp.Clients.ReqLLM.cache_key(baseline_lm, probe_messages, []) ==
             Imp.Clients.ReqLLM.cache_key(fused_lm, probe_messages, [])

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

    Imp.BenchmarkTruth.RunContext.new!(
      source_commits: %{"imp" => "deepfates/imp@test-revision"},
      workspace_state: workspace_state
    )
    |> Imp.BenchmarkTruth.RunContext.finish(payload)
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

    Imp.req_llm(model, Keyword.delete(opts, :base_url))
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

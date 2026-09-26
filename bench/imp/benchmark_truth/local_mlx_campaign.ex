defmodule Imp.BenchmarkTruth.LocalMLXCampaign do
  @moduledoc false

  alias Imp.BenchmarkTruth.{ArtifactFile, FileTree, ProviderTrainingCampaign, RunContext}
  alias Imp.Clients.{MLXLMTrainer, Trainer, TrainingJob}

  @mlx_lm_version "0.31.3"
  @model "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
  @revision "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"
  @dataset_file_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @dataset_payload_sha256 "sha256:b84958ebf577bc5d57f2c6cf4a6033d7aafcb3a5cf91a79aa826b4345ebb1f3f"
  @train_digest "sha256:0fa1c7321f2773485139a544054c619620f048ebd8dd52552e3a2ca57878b1ba"
  @held_out_digest "sha256:5d70b2ff26f9c30862175e63bc1cb4742f509f49c7571e205f1faf06d5d10fe1"
  @model_tree_sha256 "047d24a10e4acc788e046734351a0e4ec668ee36d2d9453daeb80a9364e87947"
  @evaluation_contract_sha256 %{
    "Imp.Adapter.Chat" => "8d5ecfbe6b926ca5edf20d9d6a037579ba9ad23767f6a8aeee84e76613939cee",
    "DSEx.Adapter.Chat" => "e95d621cbb3afd8806e9554fcafce6b54bc615e031c3b0acbdcadaca039870c8"
  }
  @banking77_revision "90d4e2ee5521c04fc1488f065b8b083658768c57"
  @host "127.0.0.1"
  @model_tree_files [
    %{
      "bytes" => 605,
      "link_target" => "../../blobs/482ced4679301bf287ebb310bdd1790eb4514232",
      "path" => "added_tokens.json",
      "sha256" => "58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b"
    },
    %{
      "bytes" => 783,
      "link_target" => "../../blobs/e3c0e76e4e54c951f36d49e3042347b58382136e",
      "path" => "config.json",
      "sha256" => "b045e57ea90b8f1b35f89f954b176a5c1faa02bd0af2c89bcec191239d66cef4"
    },
    %{
      "bytes" => 1_671_853,
      "link_target" => "../../blobs/31349551d90c7606f325fe0f11bbb8bd5fa0d7c7",
      "path" => "merges.txt",
      "sha256" => "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
    },
    %{
      "bytes" => 278_064_920,
      "link_target" =>
        "../../blobs/ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153",
      "path" => "model.safetensors",
      "sha256" => "ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153"
    },
    %{
      "bytes" => 44_209,
      "link_target" => "../../blobs/8831428421e282132532f717fcaba43f8c7f5445",
      "path" => "model.safetensors.index.json",
      "sha256" => "54001cb4c11197119c206dde28e7be08e5872aab6c6d271aed339ec77e84f870"
    },
    %{
      "bytes" => 613,
      "link_target" => "../../blobs/ac23c0aaa2434523c494330aeb79c58395378103",
      "path" => "special_tokens_map.json",
      "sha256" => "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
    },
    %{
      "bytes" => 7_031_673,
      "link_target" => "../../blobs/d24314ef7f0afd1b678c2e24c767e19f24f86b0e",
      "path" => "tokenizer.json",
      "sha256" => "a8506e7111b80c6d8635951a02eab0f4e1a8e4e5772da83846579e97b16f61bf"
    },
    %{
      "bytes" => 7_308,
      "link_target" => "../../blobs/482ccbc1096b0e9400e86e33f189681c2aebdab9",
      "path" => "tokenizer_config.json",
      "sha256" => "f7c61e32b7a17d19bf8e7037dcb74079a833e53ea9801f24008cac68458f03b7"
    },
    %{
      "bytes" => 2_776_833,
      "link_target" => "../../blobs/4783fe10ac3adce15ac8f358ef5462739852c569",
      "path" => "vocab.json",
      "sha256" => "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
    }
  ]

  def run!(opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    dataset_path = absolute(cwd, Keyword.fetch!(opts, :dataset))
    root = absolute(cwd, Keyword.fetch!(opts, :root))
    artifact_path = absolute(cwd, Keyword.fetch!(opts, :artifact))
    model_path = (Keyword.get(opts, :model_path) || default_model_path()) |> Path.expand()
    port = Keyword.get(opts, :port, 18_821)
    executable = Keyword.get(opts, :executable, "uvx")
    executable_args = ["--from", "mlx-lm==#{@mlx_lm_version}"]

    validate_port!(port)
    assert_port_available!(port)

    context =
      RunContext.capture_git!(
        cwd: cwd,
        require_clean: Keyword.get(opts, :require_clean, true),
        inputs: %{
          "protocol_id" => "local_mlx",
          "dataset_file_sha256" => @dataset_file_sha256,
          "dataset_payload_sha256" => @dataset_payload_sha256,
          "model" => "#{@model}@#{@revision}",
          "model_tree_sha256" => @model_tree_sha256,
          "mlx_lm_version" => @mlx_lm_version
        }
      )

    ensure_fresh_root!(root)
    dataset = load_dataset!(dataset_path)
    model_tree = FileTree.inventory!(model_path)
    require_canonical_inputs!(dataset_path, dataset, model_tree)
    signature = ProviderTrainingCampaign.signature(dataset["route_codes"])
    examples = Enum.map(dataset["train"], &ProviderTrainingCampaign.example/1)

    training_root = Path.join(root, "training")
    job_path = Path.join(root, "training-job.json")
    program_path = Path.join(root, "program.json")

    baseline =
      evaluate_served!(model_path, nil, signature, dataset["held_out"], port, executable,
        executable_args: executable_args,
        concurrency: Keyword.get(opts, :concurrency, 1)
      )

    trainer =
      MLXLMTrainer.new(
        root: training_root,
        model: @model,
        model_revision: @revision,
        model_path: model_path,
        signature: signature,
        adapter: Imp.Adapter.Chat,
        stratify_by: [:route],
        executable: executable,
        executable_args: executable_args ++ ["mlx_lm.lora"],
        server_port: port,
        server_max_tokens: 64
      )

    job = train!(trainer, examples)
    TrainingJob.save!(job, job_path)
    verified_job = TrainingJob.read!(job_path)
    manifest = verify_replay!(trainer, examples, job, verified_job)
    adapter_path = Path.expand(job.metadata.adapter_path, job.result_model)

    adapter_inference =
      evaluate_served!(
        model_path,
        adapter_path,
        signature,
        dataset["held_out"],
        port,
        executable,
        executable_args: executable_args,
        concurrency: Keyword.get(opts, :concurrency, 1)
      )

    fused_path = job.result_model
    fused_tree = manifest["fused_tree"]

    fuse = %{
      "command" => %{
        "executable" => get_in(manifest, ["spec", "fusion", "executable"]),
        "argv" => manifest["fusion_argv"]
      },
      "result" => manifest["fusion_command"]
    }

    if fused_tree["sha256"] == model_tree["sha256"],
      do: raise("fused model tree is identical to the base model tree")

    {fused, reloaded, saved_program_sha256} =
      with_server!(fused_path, nil, port, executable, executable_args, fn lm, server ->
        base_program = ProviderTrainingCampaign.evaluation_program(signature, lm)

        fused =
          ProviderTrainingCampaign.evaluate(
            base_program,
            dataset["held_out"],
            Keyword.get(opts, :concurrency, 1)
          )

        {:ok, _rebound} = TrainingJob.rebind(job, base_program, lm: lm, path: program_path)
        loaded = program_path |> Imp.read!() |> restore_runtime_credentials!(lm)

        reloaded =
          ProviderTrainingCampaign.evaluate(
            loaded,
            dataset["held_out"],
            Keyword.get(opts, :concurrency, 1)
          )

        fused = Map.put(fused, "server", server)
        reloaded = Map.put(reloaded, "server", server)

        {{fused, reloaded, file_sha256(program_path)}, server}
      end)

    acceptance = acceptance(baseline, fused, reloaded)

    artifact = %{
      "artifact_type" => "imp_mlx_weight_training_campaign",
      "schema_version" => 1,
      "status" => if(acceptance["admissible"], do: "complete", else: "rejected"),
      "runner" => "elixir",
      "evidence_level" => "local_weight_effectiveness",
      "dataset" => dataset_evidence(dataset_path, dataset),
      "model" => %{
        "repository" => @model,
        "revision" => @revision,
        "tree" => model_tree
      },
      "runtime" => runtime_evidence(executable, executable_args),
      "training" => %{
        "fresh" => true,
        "job" => TrainingJob.dump(job),
        "job_checkpoint_sha256" => file_sha256(job_path),
        "manifest" => manifest,
        "manifest_sha256" => file_sha256(Path.expand(job.metadata.manifest, job.result_model))
      },
      "fusion" => Map.merge(fuse, %{"tree" => fused_tree}),
      "program_sha256" => saved_program_sha256,
      "evaluation_contract" => evaluation_contract(dataset),
      "baseline" => baseline,
      "adapter_inference" =>
        Map.merge(adapter_inference, %{
          "status" => "observed_not_admitted",
          "reason" =>
            "Adapter inference is recorded as a lane check; official fusion provenance remains the supported weight bridge."
        }),
      "fused" => fused,
      "reloaded" => reloaded,
      "effect" => effect(baseline, fused),
      "acceptance" => acceptance,
      "limitations" => [
        "This establishes local weight-training effectiveness, not BetterTogether parity.",
        "Strict parser failures remain incorrect and block a production-ready trained-model claim."
      ]
    }

    File.mkdir_p!(Path.dirname(artifact_path))

    %{artifact: finished, path: written_path} =
      ArtifactFile.write_run_json!(artifact_path, artifact, context)

    ^finished = ArtifactFile.read_run_json!(written_path)
    {:ok, ^finished} = validate_artifact(finished)
    %{artifact: finished, path: written_path}
  end

  @doc "Independently validates a completed local MLX effectiveness artifact."
  def validate_artifact(artifact) when is_map(artifact) do
    with {:ok, verified} <- verify_envelope(artifact) do
      expected_acceptance = artifact_acceptance(verified)
      expected_effect = effect(verified["baseline"], verified["fused"])

      checks = [
        {:clean_run,
         get_in(verified, ["run_context", "workspace"]) == %{
           "state" => "clean",
           "reproducible" => true
         }},
        {:artifact_contract,
         verified["artifact_type"] in [
           "imp_mlx_weight_training_campaign",
           "dsex_mlx_weight_training_campaign"
         ] and
           verified["schema_version"] == 1 and verified["status"] in ["complete", "rejected"] and
           verified["runner"] == "elixir" and
           verified["evidence_level"] == "local_weight_effectiveness" and
           verified["status"] ==
             if(verified["acceptance"]["admissible"], do: "complete", else: "rejected")},
        {:canonical_dataset, canonical_dataset_evidence?(verified["dataset"])},
        {:canonical_model, canonical_model_evidence?(verified["model"])},
        {:pinned_runtime, pinned_runtime?(verified["runtime"])},
        {:fresh_verified_training, valid_training_evidence?(verified["training"])},
        {:official_fusion, valid_fusion_evidence?(verified["fusion"], verified["model"])},
        {:evaluation_contract,
         valid_evaluation_contract?(verified["evaluation_contract"], verified["dataset"])},
        {:server_identity_and_cleanup, valid_server_evidence?(verified)},
        {:adapter_claim_scoped,
         get_in(verified, ["adapter_inference", "status"]) in [
           "not_admitted",
           "observed_not_admitted"
         ]},
        {:recomputed_acceptance, verified["acceptance"] == expected_acceptance},
        {:recomputed_effect, json_equal?(verified["effect"], expected_effect)},
        {:portable_program_digest, sha256?(verified["program_sha256"])}
      ]

      case for({name, false} <- checks, do: name) do
        [] -> {:ok, verified}
        errors -> {:error, errors}
      end
    end
  end

  def validate_artifact(_artifact), do: {:error, [:invalid_artifact]}

  @doc false
  def exercise_server_lane_for_test!(opts) when is_list(opts) do
    model_path = Path.expand(Keyword.fetch!(opts, :model_path))
    adapter_path = Keyword.get(opts, :adapter_path)
    port = Keyword.fetch!(opts, :port)
    executable = Keyword.fetch!(opts, :executable)
    prefix = Keyword.get(opts, :executable_args, [])

    with_server!(model_path, adapter_path, port, executable, prefix, fn lm, server ->
      case Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "probe"}], []) do
        {:ok, _response} -> server
        {:error, reason} -> raise "fake MLX lane request failed: #{inspect(reason)}"
      end
    end)
  end

  defp train!(trainer, examples) do
    case Trainer.finetune(trainer, nil, examples) do
      {:ok, %TrainingJob{status: :succeeded} = job} -> job
      {:error, reason} -> raise "local MLX training failed: #{inspect(reason)}"
    end
  end

  defp verify_replay!(trainer, examples, job, loaded_job) do
    unless TrainingJob.dump(job) == TrainingJob.dump(loaded_job),
      do: raise("training-job checkpoint changed during save/load")

    {:ok, manifest} = MLXLMTrainer.verify_job(loaded_job)
    {:ok, replayed} = Trainer.finetune(trainer, nil, examples)

    unless replayed.id == job.id and replayed.result_model == job.result_model,
      do: raise("content-addressed trainer replay changed the completed job")

    manifest
  end

  defp evaluate_served!(model_path, adapter_path, signature, rows, port, executable, opts) do
    prefix = Keyword.fetch!(opts, :executable_args)
    concurrency = Keyword.fetch!(opts, :concurrency)

    with_server!(model_path, adapter_path, port, executable, prefix, fn lm, server ->
      program = ProviderTrainingCampaign.evaluation_program(signature, lm)
      evaluation = ProviderTrainingCampaign.evaluate(program, rows, concurrency)
      {Map.put(evaluation, "server", server), server}
    end)
  end

  defp with_server!(model_path, adapter_path, port, executable, prefix, fun) do
    assert_port_available!(port)

    argv =
      (prefix ++
         [
           "mlx_lm.server",
           "--model",
           model_path,
           "--host",
           @host,
           "--port",
           Integer.to_string(port),
           "--max-tokens",
           "64"
         ])
      |> maybe_append(adapter_path, ["--adapter-path", adapter_path])

    started = System.monotonic_time(:millisecond)

    {:ok, handle} =
      Imp.ExternalCommand.start(executable, argv,
        timeout: :infinity,
        kill_grace_ms: 2_000,
        max_output_bytes: 32_768
      )

    base_url = "http://#{@host}:#{port}/v1"

    try do
      expected_model_path = resolved_path!(model_path)

      {model_ids, advertised_model_path} =
        await_models!(handle, base_url, expected_model_path, started + 120_000)

      model_id = advertised_model_path

      model = %{
        provider: :openai,
        id: model_id,
        model: model_id,
        base_url: base_url,
        extra: %{openai_compatible_backend: :mlx_lm}
      }

      lm_opts = [
        api_key: "local",
        cache: false,
        temperature: 0,
        max_tokens: 32,
        timeout: 120_000
      ]

      lm_opts = maybe_add_adapter_request(lm_opts, adapter_path)

      lm = Imp.req_llm(model, lm_opts)

      server = %{
        "command" => %{"executable" => resolve_executable!(executable), "argv" => argv},
        "base_url" => base_url,
        "model_id" => model_id,
        "advertised_model_ids" => model_ids,
        "advertised_model_path" => advertised_model_path,
        "explicit_model_path" => model_path,
        "resolved_model_path" => expected_model_path,
        "adapter_path" => adapter_path,
        "ready_ms" => System.monotonic_time(:millisecond) - started,
        "cleanup" => "synchronous_process_group_absence_verified"
      }

      case fun.(lm, server) do
        {value, ^server} -> value
        value -> value
      end
    after
      :ok = Imp.ExternalCommand.stop(handle, 10_000)
      await_closed!(port, System.monotonic_time(:millisecond) + 10_000)
    end
  end

  defp await_models!(handle, base_url, expected_model_path, deadline) do
    if Process.alive?(handle.owner),
      do: await_models_request!(handle, base_url, expected_model_path, deadline),
      else: raise("MLX server exited before readiness")
  end

  defp await_models_request!(handle, base_url, expected_model_path, deadline) do
    case Req.get(base_url <> "/models", receive_timeout: 1_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        ids = Enum.map(data, & &1["id"])
        advertised_path = Enum.find(ids, &(&1 == expected_model_path))

        if is_binary(advertised_path) and Process.alive?(handle.owner),
          do: {ids, advertised_path},
          else: retry_models!(handle, base_url, expected_model_path, deadline)

      _result ->
        retry_models!(handle, base_url, expected_model_path, deadline)
    end
  rescue
    _error -> retry_models!(handle, base_url, expected_model_path, deadline)
  end

  defp retry_models!(handle, base_url, expected_model_path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "MLX server did not advertise #{expected_model_path} at #{base_url}"
    end

    Process.sleep(100)
    await_models!(handle, base_url, expected_model_path, deadline)
  end

  defp await_closed!(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:error, _reason} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)

        if System.monotonic_time(:millisecond) >= deadline do
          raise "MLX server still accepts connections after supervised shutdown"
        end

        Process.sleep(50)
        await_closed!(port, deadline)
    end
  end

  @doc false
  def acceptance(baseline, fused, reloaded) do
    results = [baseline, fused, reloaded]

    checks = %{
      "complete_held_out" => Enum.all?(results, &complete_result?/1),
      "metrics_recomputed" => Enum.all?(results, &metrics_match_rows?/1),
      "fused_improves_accuracy" => fused["accuracy"] > baseline["accuracy"],
      "fused_improves_macro_f1" => fused["macro_f1"] > baseline["macro_f1"],
      "official_fusion_completed" => true,
      "save_load_equivalent" => equivalent_rows?(fused, reloaded),
      "row_identity_preserved" => same_ids?([baseline, fused, reloaded])
    }

    Map.put(checks, "admissible", Enum.all?(checks, fn {_name, passed} -> passed end))
  end

  defp artifact_acceptance(artifact) do
    artifact["baseline"]
    |> acceptance(artifact["fused"], artifact["reloaded"])
    |> Map.put(
      "official_fusion_completed",
      valid_fusion_evidence?(artifact["fusion"], artifact["model"])
    )
    |> then(&Map.put(&1, "admissible", Enum.all?(Map.values(&1))))
  end

  defp equivalent_rows?(left, right),
    do: row_outcomes(left) == row_outcomes(right)

  defp row_outcomes(result),
    do: Enum.map(result["rows"], &Map.take(&1, ["id", "expected", "actual", "status", "correct"]))

  defp same_ids?([first | rest]) do
    ids = Enum.map(first["rows"], & &1["id"])

    Enum.uniq(ids) == ids and
      Enum.all?(rest, &(Enum.map(&1["rows"], fn row -> row["id"] end) == ids))
  end

  defp complete_result?(result) do
    rows = result["rows"]

    is_list(rows) and result["total"] == 40 and length(rows) == 40 and
      Enum.all?(rows, fn row ->
        is_binary(row["id"]) and is_binary(row["expected"]) and is_binary(row["status"]) and
          is_boolean(row["correct"])
      end)
  end

  defp metrics_match_rows?(result) do
    rows = result["rows"] || []
    correct = Enum.count(rows, &(&1["correct"] == true))
    failures = Enum.count(rows, &(&1["status"] != "ok"))

    result["correct"] == correct and result["failures"] == failures and
      close?(result["accuracy"], correct / max(length(rows), 1)) and
      close?(result["macro_f1"], macro_f1(rows))
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

  defp close?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) < 1.0e-12

  defp close?(_left, _right), do: false

  defp effect(baseline, trained) do
    %{
      "accuracy_delta" => trained["accuracy"] - baseline["accuracy"],
      "macro_f1_delta" => trained["macro_f1"] - baseline["macro_f1"]
    }
  end

  @doc false
  def restore_runtime_credentials!(loaded, expected_lm) do
    loaded_lm = Imp.ProgramAccess.lm(loaded)
    expected_opts = Keyword.drop(expected_lm.opts, [:api_key, :authorization, :headers])

    unless json_equal?(loaded_lm.model, expected_lm.model) and
             Map.new(loaded_lm.opts) == Map.new(expected_opts) do
      raise "saved local MLX program changed its credential-free deployment LM"
    end

    Imp.with_lm(loaded, expected_lm)
  end

  defp evaluation_contract(dataset) do
    contract = %{
      "adapter" => "Imp.Adapter.Chat",
      "temperature" => 0,
      "max_tokens" => 32,
      "server_max_tokens" => 64,
      "timeout_ms" => 120_000,
      "cache" => false,
      "held_out_ids" => Enum.map(dataset["held_out"], & &1["id"])
    }

    Map.put(contract, "sha256", canonical_sha256(contract))
  end

  defp verify_envelope(artifact) do
    {:ok, RunContext.verify!(artifact)}
  rescue
    _error -> {:error, [:invalid_run_envelope]}
  end

  defp canonical_dataset_evidence?(dataset) when is_map(dataset) do
    dataset["file_sha256"] == @dataset_file_sha256 and
      dataset["payload_sha256"] == @dataset_payload_sha256 and
      dataset["train_digest"] == @train_digest and
      dataset["held_out_digest"] == @held_out_digest and dataset["train_rows"] == 80 and
      dataset["held_out_rows"] == 40 and
      get_in(dataset, ["source", "dataset"]) == "PolyAI/banking77" and
      get_in(dataset, ["source", "revision"]) == @banking77_revision and
      get_in(dataset, ["selection", "train_held_out_overlap"]) == [] and
      get_in(dataset, ["selection", "train_per_label"]) == 20 and
      get_in(dataset, ["selection", "held_out_per_label"]) == 10
  end

  defp canonical_dataset_evidence?(_dataset), do: false

  defp canonical_model_evidence?(model) when is_map(model) do
    model["repository"] == @model and model["revision"] == @revision and
      get_in(model, ["tree", "schema_version"]) == 1 and
      get_in(model, ["tree", "sha256"]) == @model_tree_sha256 and
      get_in(model, ["tree", "files"]) == @model_tree_files and
      valid_tree_inventory?(model["tree"])
  end

  defp canonical_model_evidence?(_model), do: false

  defp pinned_runtime?(runtime) when is_map(runtime) do
    runtime["mlx_lm_version"] == @mlx_lm_version and
      get_in(runtime, ["launcher", "argv_prefix"]) == ["--from", "mlx-lm==#{@mlx_lm_version}"] and
      sha256?(get_in(runtime, ["launcher", "sha256"]))
  end

  defp pinned_runtime?(_runtime), do: false

  defp valid_training_evidence?(training) when is_map(training) do
    job = training["job"] || %{}
    manifest = training["manifest"] || %{}
    artifacts = manifest["artifacts"] || %{}
    adapter = artifacts["adapters.safetensors"] || %{}
    config = artifacts["adapter_config.json"] || %{}

    training["fresh"] == true and job["provider"] == "mlx_lm" and
      job["status"] == "succeeded" and job["training_data"] == [72, 8] and
      job["model"] == "#{@model}@#{@revision}" and is_binary(job["result_model"]) and
      manifest["artifact_type"] in ["imp_mlx_lm_sft_run", "dsex_mlx_lm_sft_run"] and
      manifest["schema_version"] in [1, 2] and manifest["status"] == "succeeded" and
      get_in(manifest, ["spec", "mlx_lm_version"]) == @mlx_lm_version and
      get_in(manifest, ["spec", "model"]) == @model and
      get_in(manifest, ["spec", "model_revision"]) == @revision and
      get_in(manifest, ["dataset", "train_count"]) == 72 and
      get_in(manifest, ["dataset", "valid_count"]) == 8 and
      successful_training_command?(manifest) and
      positive_file?(adapter) and positive_file?(config) and
      digest_matches_job?(job, "adapters.safetensors", adapter["sha256"]) and
      digest_matches_job?(job, "adapter_config.json", config["sha256"]) and
      sha256?(training["job_checkpoint_sha256"]) and sha256?(training["manifest_sha256"])
  end

  defp valid_training_evidence?(_training), do: false

  defp valid_fusion_evidence?(fusion, model) when is_map(fusion) and is_map(model) do
    argv = get_in(fusion, ["command", "argv"]) || []
    tree = fusion["tree"] || %{}

    get_in(fusion, ["result", "exit_status"]) == 0 and
      Enum.take(argv, 3) == ["--from", "mlx-lm==#{@mlx_lm_version}", "mlx_lm.fuse"] and
      "--adapter-path" in argv and "--save-path" in argv and
      valid_tree_inventory?(tree) and tree["sha256"] != get_in(model, ["tree", "sha256"]) and
      Enum.any?(tree["files"], &(&1["path"] == "model.safetensors" and &1["bytes"] > 0))
  end

  defp valid_fusion_evidence?(_fusion, _model), do: false

  defp valid_evaluation_contract?(contract, dataset) when is_map(contract) do
    ids = contract["held_out_ids"]

    contract["sha256"] == @evaluation_contract_sha256[contract["adapter"]] and
      contract["cache"] == false and contract["temperature"] == 0 and
      contract["max_tokens"] == 32 and contract["server_max_tokens"] == 64 and
      contract["timeout_ms"] == 120_000 and is_list(ids) and length(ids) == 40 and
      Enum.uniq(ids) == ids and dataset["held_out_rows"] == length(ids) and
      canonical_sha256(Map.delete(contract, "sha256")) == contract["sha256"]
  end

  defp valid_evaluation_contract?(_contract, _dataset), do: false

  defp valid_server_evidence?(artifact) do
    baseline = get_in(artifact, ["baseline", "server"]) || %{}
    fused = get_in(artifact, ["fused", "server"]) || %{}
    reloaded = get_in(artifact, ["reloaded", "server"]) || %{}

    adapter = get_in(artifact, ["adapter_inference", "server"]) || %{}
    adapter_status = get_in(artifact, ["adapter_inference", "status"])

    current =
      baseline["cleanup"] == "synchronous_process_group_absence_verified" and
        fused["cleanup"] == "synchronous_process_group_absence_verified" and
        reloaded == fused and
        baseline["model_id"] == baseline["advertised_model_path"] and
        fused["model_id"] == fused["advertised_model_path"] and
        baseline["resolved_model_path"] == baseline["advertised_model_path"] and
        fused["resolved_model_path"] == fused["advertised_model_path"] and
        baseline["adapter_path"] == nil and fused["adapter_path"] == nil and
        adapter_status == "observed_not_admitted" and
        adapter["cleanup"] == "synchronous_process_group_absence_verified" and
        adapter["model_id"] == adapter["advertised_model_path"] and
        adapter["resolved_model_path"] == adapter["advertised_model_path"] and
        adapter["adapter_path"] == expected_adapter_path(artifact)

    legacy =
      baseline["cleanup"] == "synchronous_process_group_absence_verified" and
        fused["cleanup"] == "synchronous_process_group_absence_verified" and
        reloaded == fused and baseline["model_id"] == "default_model" and
        fused["model_id"] == "default_model" and
        baseline["explicit_model_path"] == baseline["advertised_model_path"] and
        fused["explicit_model_path"] == fused["advertised_model_path"] and
        adapter_status == "not_admitted"

    current or legacy
  end

  defp valid_tree_inventory?(%{"files" => files, "sha256" => digest}) when is_list(files) do
    files != [] and sha256?(digest) and
      Enum.all?(files, fn file ->
        is_binary(file["path"]) and is_integer(file["bytes"]) and file["bytes"] >= 0 and
          sha256?(file["sha256"])
      end)
  end

  defp valid_tree_inventory?(_tree), do: false

  defp positive_file?(%{"bytes" => bytes, "sha256" => digest}),
    do: is_integer(bytes) and bytes > 0 and sha256?(digest)

  defp positive_file?(_file), do: false

  defp successful_training_command?(%{"schema_version" => 2} = manifest),
    do: get_in(manifest, ["training_command", "exit_status"]) == 0

  defp successful_training_command?(%{"schema_version" => 1} = manifest),
    do: get_in(manifest, ["command", "exit_status"]) == 0

  defp successful_training_command?(_manifest), do: false

  defp expected_adapter_path(artifact) do
    job = get_in(artifact, ["training", "job"]) || %{}

    case get_in(job, ["metadata", "adapter_path"]) do
      path when is_binary(path) -> Path.expand(path, job["result_model"])
      _legacy -> job["result_model"]
    end
  end

  defp digest_matches_job?(job, filename, digest) do
    job_digest =
      get_in(job, ["metadata", "adapter_sha256", filename]) ||
        get_in(job, ["metadata", "artifact_sha256", filename])

    is_binary(job_digest) and String.replace(job_digest, ":", "") == digest
  end

  defp sha256?(digest), do: is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp dataset_evidence(path, dataset) do
    %{
      "path" => path,
      "file_sha256" => file_sha256(path),
      "payload_sha256" => dataset["payload_sha256"],
      "train_digest" => dataset["digests"]["train"],
      "held_out_digest" => dataset["digests"]["held_out"],
      "train_rows" => length(dataset["train"]),
      "held_out_rows" => length(dataset["held_out"]),
      "source" => dataset["source"],
      "selection" => dataset["selection"]
    }
  end

  defp runtime_evidence(executable, prefix) do
    %{
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "architecture" => :erlang.system_info(:system_architecture) |> List.to_string(),
      "os" => :os.type() |> inspect(),
      "mlx_lm_version" => @mlx_lm_version,
      "launcher" => %{
        "path" => resolve_executable!(executable),
        "sha256" => file_sha256(resolve_executable!(executable)),
        "argv_prefix" => prefix
      }
    }
  end

  defp load_dataset!(path) do
    dataset = path |> File.read!() |> Jason.decode!()
    unless ProviderTrainingCampaign.valid_dataset?(dataset), do: raise("invalid pinned dataset")
    dataset
  end

  defp require_canonical_inputs!(dataset_path, dataset, model_tree) do
    unless file_sha256(dataset_path) == @dataset_file_sha256 and
             dataset["payload_sha256"] == @dataset_payload_sha256,
           do: raise("dataset does not match the canonical Banking77 campaign payload")

    unless model_tree["sha256"] == @model_tree_sha256 and
             model_tree["files"] == @model_tree_files,
           do: raise("model snapshot does not match the canonical pinned inventory")
  end

  defp assert_port_available!(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, socket} -> :gen_tcp.close(socket)
      {:error, reason} -> raise "MLX campaign port #{port} is unavailable: #{inspect(reason)}"
    end
  end

  defp ensure_fresh_root!(root) do
    if File.exists?(root), do: raise("fresh local MLX campaign root already exists: #{root}")
    File.mkdir_p!(root)
  end

  defp validate_port!(port) when is_integer(port) and port in 1..65_535, do: :ok
  defp validate_port!(_port), do: raise(ArgumentError, "port must be between 1 and 65535")

  defp resolve_executable!(executable) do
    path =
      if Path.type(executable) == :absolute,
        do: executable,
        else: System.find_executable(executable)

    if is_binary(path), do: path, else: raise("executable not found: #{executable}")
  end

  defp default_model_path do
    Path.join([
      System.user_home!(),
      ".cache/huggingface/hub/models--mlx-community--Qwen2.5-0.5B-Instruct-4bit/snapshots",
      @revision
    ])
  end

  defp resolved_path!(path) do
    case System.cmd("realpath", [Path.expand(path)], stderr_to_stdout: true) do
      {resolved, 0} ->
        String.trim(resolved)

      {output, status} ->
        raise "could not resolve model path (status #{status}): #{String.trim(output)}"
    end
  end

  defp absolute(cwd, path),
    do: if(Path.type(path) == :absolute, do: path, else: Path.join(cwd, path))

  defp file_sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp canonical_sha256(value),
    do:
      value
      |> Imp.Training.ChatDataset.canonical_json()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp json_safe(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp json_equal?(left, right), do: json_safe(left) == json_safe(right)
  defp maybe_add_adapter_request(opts, nil), do: opts

  defp maybe_add_adapter_request(opts, adapter_path) do
    Keyword.put(opts, :req_http_options,
      finch_request: fn req, finch_request, finch_name, finch_options ->
        body =
          finch_request.body
          |> Jason.decode!()
          |> Map.put("adapters", adapter_path)
          |> Jason.encode!()

        case Finch.request(%{finch_request | body: body}, finch_name, finch_options) do
          {:ok, response} ->
            {req, Req.Response.new(response)}

          {:error, reason} ->
            raise "MLX request transport failed: #{inspect(reason)}"
        end
      end
    )
  end

  defp maybe_append(list, nil, _suffix), do: list
  defp maybe_append(list, _value, suffix), do: list ++ suffix
end

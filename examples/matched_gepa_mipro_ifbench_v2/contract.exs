defmodule MatchedGepaMiproIFBench.Contract do
  @moduledoc false

  @seeds [2_026_072_705, 2_026_072_706, 2_026_072_707]
  @arms ~w(baseline gepa mipro_v2)
  @ceilings %{
    "baseline" => %{
      "task_logical" => 192,
      "optimizer_logical" => 0,
      "transports" => 192,
      "total_logical" => 192
    },
    "gepa" => %{
      "task_logical" => 432,
      "optimizer_logical" => 12,
      "transports" => 444,
      "total_logical" => 444
    },
    "mipro_v2" => %{
      "task_logical" => 864,
      "optimizer_logical" => 11,
      "transports" => 875,
      "total_logical" => 875
    }
  }

  def load!(path), do: load(path, true)
  def load_optimization!(path), do: load(path, false)

  def plan!(path) do
    manifest = load!(path)
    task_calls = 8_928
    optimizer_calls = 138
    request = manifest["execution"]["request"]

    %{
      "schema_version" => 3,
      "kind" => "matched_gepa_mipro_ifbench_plan",
      "campaign_id" => manifest["campaign_id"],
      "manifest_sha256" => manifest["manifest_sha256"],
      "network_calls" => 0,
      "models_started" => 0,
      "downloads" => 0,
      "runtimes" => ~w(imp upstream),
      "seeds" => @seeds,
      "arms" => @arms,
      "split_counts" => %{"train" => 16, "selection" => 32, "held_out" => 64},
      "per_seed_per_runtime" => @ceilings,
      "gepa_stopping" => %{
        "semantic_max_metric_calls" => 80,
        "legal_iteration_metric_call_cap" => 120,
        "legal_reflection_transport_cap" => 12,
        "maximum_started_iterations" => 6,
        "rule" =>
          "check semantic max between iterations; every legally started iteration completes"
      },
      "worst_case" => %{
        "task_calls" => task_calls,
        "optimizer_calls" => optimizer_calls,
        "total_calls" => task_calls + optimizer_calls,
        "input_tokens" =>
          task_calls * request["task"]["max_input_tokens"] +
            optimizer_calls * request["optimizer"]["max_input_tokens"],
        "output_tokens" =>
          task_calls * request["task"]["max_tokens"] +
            optimizer_calls * request["optimizer"]["max_tokens"],
        "usd" => worst_case_usd(manifest)
      },
      "claim_boundary" => manifest["claim_boundary"]
    }
  end

  def worst_case_usd(manifest) do
    task = manifest["models"]["task"]
    optimizer = manifest["models"]["optimizer"]
    request = manifest["execution"]["request"]

    task_call =
      request["task"]["reservation_input_tokens"] *
        String.to_float(task["catalog_prompt_per_token"]) +
        request["task"]["max_tokens"] * String.to_float(task["catalog_completion_per_token"])

    optimizer_call =
      request["optimizer"]["reservation_input_tokens"] *
        String.to_float(optimizer["catalog_cache_write_per_token"]) +
        request["optimizer"]["max_tokens"] *
          String.to_float(optimizer["catalog_completion_per_token"])

    8_928 * task_call + 138 * optimizer_call
  end

  defp load(path, include_held_out?) do
    expanded = Path.expand(path)
    manifest = expanded |> File.read!() |> Jason.decode!()
    base = Path.dirname(expanded)

    require!(manifest["schema_version"] == 3, "schema version drift")

    require!(
      manifest["campaign_id"] == "matched-gepa-mipro-ifbench-stock-dspy-adapted-v2",
      "campaign id drift"
    )

    require!(
      manifest["launch_status"] in [
        "blocked_live_preflight",
        "sealed",
        "draft_unsealed_pending_compatibility_review",
        "stopped_incomplete_upstream_gepa_output_alignment"
      ],
      "launch status drift"
    )

    require!(
      manifest["intent"] == "sealed_source_disjoint_matched_system_comparison",
      "intent drift"
    )

    require!(manifest["seeds"] == @seeds, "seed contract drift")
    require!(manifest["arms"] == @arms, "arm contract drift")
    require!(manifest["execution"]["call_ceilings"] == @ceilings, "call ceilings drift")
    validate_optimizer!(manifest["optimizer"])
    validate_execution!(manifest["execution"])
    validate_models!(manifest["models"])
    validate_translation!(manifest["compatibility_translation"])
    validate_dependencies!(manifest["runtime_dependencies"], base)
    dataset = validate_dataset!(manifest["dataset"], base, include_held_out?)

    require!(abs(worst_case_usd(manifest) - 74.552832) < 1.0e-9, "sealed spend maximum drift")

    manifest
    |> Map.put("dataset", dataset)
    |> Map.put("manifest_path", expanded)
    |> Map.put("manifest_sha256", sha256_file(expanded))
  end

  defp validate_dataset!(dataset, base, include_held_out?) do
    require!(dataset["program"] == "IFBenchCoT2StageModule", "stock DSPy runtime class drift")

    require!(
      dataset["task_graph"] == "pinned IFBenchCoT2StageProgram two-stage predictor graph",
      "task graph drift"
    )

    require!(
      dataset["runtime_classes"] == %{
        "artifact_modified_dspy" => "IFBenchCoT2StageProgram",
        "stock_dspy_3_2_1" => "IFBenchCoT2StageModule",
        "imp" => "Imp.BenchmarkTruth.IFBenchTwoStage"
      },
      "runtime class mapping drift"
    )

    receipt_path =
      verified_path!(dataset["receipt_path"], dataset["receipt_sha256"], base, "receipt")

    receipt = receipt_path |> File.read!() |> Jason.decode!()

    require!(
      receipt["counts"] == %{"train" => 16, "selection" => 32, "held_out" => 64},
      "split counts drift"
    )

    ids = receipt["split_ids"]
    all = ids["train"] ++ ids["selection"] ++ ids["held_out"]

    require!(
      Enum.map(["train", "selection", "held_out"], &length(ids[&1])) == [16, 32, 64],
      "split ids drift"
    )

    require!(length(Enum.uniq(all)) == 112, "split overlap")

    dataset =
      Enum.reduce(~w(train selection), dataset, fn split, acc ->
        Map.put(
          acc,
          "#{split}_path",
          verified_path!(dataset["#{split}_path"], dataset["#{split}_sha256"], base, split)
        )
      end)

    held_path = Path.expand(dataset["held_out_path"], base)

    if include_held_out?,
      do: require!(sha256_file(held_path) == dataset["held_out_sha256"], "held_out digest drift")

    dataset
    |> Map.put("receipt_path", receipt_path)
    |> Map.put("held_out_path", held_path)
    |> Map.put("split_ids", ids)
  end

  defp validate_translation!(translation) do
    require!(
      translation["id"] == "stock-dspy-adapted-ifbench-cot-2stage-v1",
      "translation id drift"
    )

    require!(
      translation["retained"] ==
        "two ChainOfThought predictors, names/order, signatures, fields, instructions, demos, config, output, messages, dataflow, traces, deepcopy and targeted mutation semantics",
      "translation whitelist drift"
    )
  end

  defp validate_models!(models) do
    require!(models["task"]["logical"] == "openai/gpt-5.4-mini", "task route drift")
    require!(models["task"]["endpoint_provider"] == "OpenAI", "task provider drift")

    require!(
      models["optimizer"]["logical"] == "anthropic/claude-sonnet-4.6",
      "optimizer route drift"
    )

    require!(models["optimizer"]["endpoint_provider"] == "Anthropic", "optimizer provider drift")
  end

  defp validate_optimizer!(optimizer) do
    require!(
      optimizer["gepa"] == %{
        "iterations" => 1,
        "minibatch_size" => 8,
        "semantic_max_metric_calls" => 80,
        "legal_metric_call_cap" => 120,
        "legal_reflection_call_cap" => 12,
        "candidate_selection" => "pareto",
        "module_selection" => "round_robin",
        "acceptance" => "strict_improvement",
        "selection" => "all_improvements",
        "use_merge" => false
      },
      "GEPA contract drift"
    )

    require!(
      optimizer["mipro_v2"] == %{
        "num_candidates" => 4,
        "trials" => 8,
        "minibatch" => false,
        "max_bootstrapped_demos" => 0,
        "max_labeled_demos" => 0,
        "startup_trials" => 10,
        "proposer_fidelity" => "dspy_3_2_1",
        "search_fidelity" => "dspy_3_2_1_optuna_4_9_0_startup",
        "program_aware_proposer" => false,
        "data_aware_proposer" => true,
        "tip_aware_proposer" => true,
        "fewshot_aware_proposer" => false,
        "view_data_batch_size" => 10
      },
      "MIPROv2 contract drift"
    )
  end

  defp validate_execution!(execution) do
    require!(execution["concurrency"] == 1, "concurrency drift")

    require!(
      execution["cache"] == false and execution["retry"] == false and
        execution["max_retries"] == 0,
      "retry/cache drift"
    )

    require!(
      execution["fallbacks"] == false and execution["data_collection"] == "deny",
      "privacy/fallback drift"
    )

    require!(
      execution["openrouter"]["allow_fallbacks"] == false and
        execution["openrouter"]["require_parameters"] == true,
      "routing guard drift"
    )

    require!(
      execution["request"]["task"] == %{
        "temperature" => nil,
        "seed" => "experiment_seed",
        "max_tokens" => 768,
        "max_input_tokens" => 4096,
        "reservation_input_tokens" => 4864
      },
      "task envelope drift"
    )

    require!(
      execution["request"]["optimizer"] == %{
        "temperature" => 1,
        "max_tokens" => 1024,
        "max_input_tokens" => 16384,
        "reservation_input_tokens" => 17408
      },
      "optimizer envelope drift"
    )
  end

  defp validate_dependencies!(dependencies, base) do
    imp = dependencies["imp"]
    upstream = dependencies["upstream"]
    ifbench = dependencies["ifbench"]

    require!(
      sha256_file(Path.expand(imp["mix_lock_path"], base)) == imp["mix_lock_sha256"],
      "root Mix lock drift"
    )

    require!(
      sha256_file(Path.expand(imp["consumer_mix_lock_path"], base)) ==
        imp["consumer_mix_lock_sha256"],
      "consumer Mix lock drift"
    )

    require!(
      sha256_file(Path.expand(upstream["lock_path"], base)) == upstream["lock_sha256"],
      "upstream lock drift"
    )

    require!(
      sha256_file(Path.expand(ifbench["requirements_path"], base)) ==
        ifbench["requirements_sha256"],
      "IFBench requirements drift"
    )

    require!(
      File.dir?(Path.expand(ifbench["site_packages_path"], base)),
      "IFBench site-packages missing"
    )

    nltk_data = Path.expand(ifbench["nltk_data_path"], base)
    require!(File.dir?(nltk_data), "IFBench NLTK data missing")
    require!(tree_sha256(nltk_data) == ifbench["nltk_data_sha256"], "IFBench NLTK data drift")
  end

  defp verified_path!(relative, expected, base, label) do
    path = Path.expand(relative, base)
    require!(File.regular?(path), "#{label} missing")
    require!(sha256_file(path) == expected, "#{label} digest drift")
    path
  end

  defp sha256_file(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp tree_sha256(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, hash ->
      relative = Path.relative_to(path, root)
      digest = :crypto.hash(:sha256, File.read!(path))
      :crypto.hash_update(hash, [relative, <<0>>, digest, "\n"])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end

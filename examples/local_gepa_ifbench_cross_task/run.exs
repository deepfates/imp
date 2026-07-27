defmodule LocalGEPAIFBenchCrossTask.Runner do
  @root __DIR__
  @contract Path.join(@root, "contract.json")
  @result Path.join(@root, "exercised-result.json")

  def run do
    contract = @contract |> File.read!() |> Jason.decode!()
    require_sealed!(contract)
    require_clean_source!(contract)
    verify_dataset!(contract)
    verify_local_model!(contract)

    gepa_root = System.fetch_env!("IMP_GEPA_ROOT") |> Path.expand()
    python = System.fetch_env!("IMP_GEPA_PYTHON") |> Path.expand()
    require!(File.dir?(gepa_root), "IMP_GEPA_ROOT is not an existing directory")
    require!(File.regular?(python), "IMP_GEPA_PYTHON is not an existing interpreter")

    model = contract["model"]

    model_spec = %{
      provider: :openai,
      id: model["runtime_identifier"],
      model: model["runtime_identifier"],
      base_url: model["base_url"]
    }

    common = [
      api_key: "lm-studio-local",
      cache: false,
      max_retries: 0,
      req_http_options: [retry: false, max_retries: 0]
    ]

    task_lm =
      Imp.req_llm(
        model_spec,
        common ++
          [
            temperature: model["task_temperature"],
            max_tokens: model["task_max_tokens"]
          ]
      )

    reflection_lm =
      Imp.req_llm(
        model_spec,
        common ++
          [
            temperature: model["reflection_temperature"],
            max_tokens: model["reflection_max_tokens"]
          ]
      )

    dataset_root = Path.join(@root, contract["dataset"]["root"])
    treatment = contract["treatment_id"]
    raw_out = Path.join("tmp", treatment)
    checkpoint_dir = Path.join(raw_out, "checkpoints")
    File.mkdir_p!(raw_out)

    budgets = %{
      "aggregate" => %{
        "requests" => 2_000,
        "input_tokens" => 20_000_000,
        "output_tokens" => 5_000_000,
        "usd" => 0.0
      },
      "per_shard" => %{
        "IFBench" => %{
          "requests" => 2_000,
          "input_tokens" => 20_000_000,
          "output_tokens" => 5_000_000,
          "usd" => 0.0
        }
      },
      "reservation_pricing" => %{
        "input_per_million" => 0.0,
        "output_per_million" => 0.0
      }
    }

    result =
      Imp.BenchmarkTruth.GepaCampaign.run(
        dataset_root: dataset_root,
        campaign_id: treatment,
        model: "lmstudio:" <> model["runtime_identifier"],
        reflection_model: "lmstudio:" <> model["runtime_identifier"],
        out_dir: raw_out,
        checkpoint_dir: checkpoint_dir,
        families: ["IFBench"],
        seeds: contract["optimizer"]["seeds"],
        generations: :metric_budget,
        max_concurrency: model["parallel"],
        pricing_source: "LM Studio local usage telemetry; zero provider spend",
        budgets: budgets,
        source_commits: %{
          "dspy" => "stanfordnlp/dspy@" <> contract["authority"]["dspy_commit"],
          "imp" => "deepfates/imp@" <> contract["authority"]["imp_predecessor_commit"],
          "gepa_artifact" =>
            "gepa-ai/gepa-artifact@" <> contract["authority"]["gepa_artifact_commit"]
        },
        execution: %{
          "lm" => %{
            "provider" => "lmstudio_openai_compatible",
            "runtime_identifier" => model["runtime_identifier"],
            "task_temperature" => model["task_temperature"],
            "reflection_temperature" => model["reflection_temperature"],
            "task_max_tokens" => model["task_max_tokens"],
            "reflection_max_tokens" => model["reflection_max_tokens"],
            "optimizer_timeout_ms" => 600_000,
            "max_retries" => 0,
            "json_fallback" => false,
            "cache" => false
          },
          "retrieval" => %{"gepa_root" => gepa_root, "python" => python},
          "ifbench" => %{"upstream_descriptions" => true},
          "semantic_progress" => %{"max_consecutive_proposal_errors" => 5},
          "gepa" => %{
            "minibatch_size" => contract["optimizer"]["reflection_minibatch_size"],
            "candidate_selection_strategy" => contract["optimizer"]["candidate_selection"],
            "module_selector" => contract["optimizer"]["component_selection"],
            "acceptance_policy" => contract["optimizer"]["acceptance"]
          }
        },
        lm: task_lm,
        reflection_lm: reflection_lm,
        judge_lm: task_lm,
        judge_model: "lmstudio:" <> model["runtime_identifier"]
      )

    compact = compact_result!(result, contract, checkpoint_dir)
    atomic_write!(@result, compact)
    IO.puts(Jason.encode!(compact, pretty: true))
  rescue
    error ->
      atomic_write!(@result, %{
        schema_version: 1,
        treatment_id: treatment_id(),
        status: "stopped",
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp compact_result!(result, contract, checkpoint_dir) do
    [row] = result.report["rows"]
    [checkpoint] = Path.wildcard(Path.join(checkpoint_dir, "*.json"))
    completed = checkpoint |> File.read!() |> Jason.decode!() |> Map.fetch!("completed")

    per_seed =
      Enum.map(completed, fn entry ->
        seed_result = entry["result"]
        baseline = seed_result["baseline_test"]
        selected = seed_result["test"]

        %{
          "seed" => entry["seed"],
          "baseline_test" => baseline,
          "selected_test" => selected,
          "paired_delta" => selected - baseline,
          "selection_score" => seed_result["dev"],
          "baseline_selection_score" => seed_result["baseline_dev"],
          "candidate_count" => seed_result["candidate_count"],
          "optimizer_metric_calls" => seed_result["optimizer_metric_calls"],
          "stop_reason" => seed_result["optimizer_stop_reason"]
        }
      end)

    deltas = Enum.map(per_seed, & &1["paired_delta"])
    mean = Enum.sum(deltas) / length(deltas)
    go = mean > 0 and Enum.all?(deltas, &(&1 > 0))

    %{
      "schema_version" => 1,
      "treatment_id" => contract["treatment_id"],
      "status" => "complete",
      "claim_boundary" => contract["outcome"]["interpretation"],
      "model" => contract["model"],
      "dataset" => %{
        "counts" => contract["dataset"]["counts"],
        "source_manifest_sha256" =>
          sha256_file(Path.join(@root, contract["dataset"]["source_manifest"]))
      },
      "per_seed" => per_seed,
      "paired_test" => %{
        "mean_delta" => mean,
        "exact_seed_range" => [Enum.min(deltas), Enum.max(deltas)],
        "all_seeds_positive" => Enum.all?(deltas, &(&1 > 0)),
        "go_rule_passed" => go
      },
      "selected_seed" => get_in(row, ["seed_selection", "imp_gepa", "selected_seed"]),
      "token_cost" => row["token_cost"],
      "budget" => row["budget"],
      "test_boundary" => %{
        "decoded_after_selected_program" => true,
        "regression_commit" => "712034d"
      },
      "source_commits" => row["source_commits"]
    }
  end

  defp verify_dataset!(contract) do
    manifest_path = Path.join(@root, contract["dataset"]["source_manifest"])
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    Enum.each(manifest["split_checksums"], fn {split, expected} ->
      actual = "sha256:" <> sha256_file(Path.join([@root, "data", "IFBench", split <> ".jsonl"]))
      require!(actual == expected, "#{split} split digest drift")
    end)
  end

  defp verify_local_model!(contract) do
    {output, 0} = System.cmd("lms", ["ps", "--json"], stderr_to_stdout: true)
    loaded = Jason.decode!(output)
    identifier = contract["model"]["runtime_identifier"]
    matching = Enum.filter(loaded, &(&1["identifier"] == identifier))
    require!(length(matching) == 1, "exact frozen LM Studio identifier is not loaded once")
  end

  defp require_sealed!(%{"status" => "sealed"}), do: :ok
  defp require_sealed!(_contract), do: raise("cross-task treatment is not sealed")

  defp require_clean_source!(contract) do
    {status, 0} = System.cmd("git", ["status", "--porcelain", "--untracked-files=all"])
    require!(String.trim(status) == "", "Imp worktree must be clean")

    predecessor = contract["authority"]["imp_predecessor_commit"]
    {_, code} = System.cmd("git", ["merge-base", "--is-ancestor", predecessor, "HEAD"])
    require!(code == 0, "sealed Imp predecessor is not an ancestor of launch HEAD")
  end

  defp treatment_id do
    @contract |> File.read!() |> Jason.decode!() |> Map.get("treatment_id", "unknown")
  rescue
    _ -> "unknown"
  end

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(message)

  defp atomic_write!(path, value) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp sha256_file(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end

LocalGEPAIFBenchCrossTask.Runner.run()

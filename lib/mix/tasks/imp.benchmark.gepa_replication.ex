defmodule Mix.Tasks.Imp.Benchmark.GepaReplication do
  @moduledoc """
  Validate and emit GEPA paper-replication evidence artifacts.

      mix imp.benchmark.gepa_replication --smoke --out tmp/gepa-replication
      mix imp.benchmark.gepa_replication --input path/to/rows.json --out tmp/gepa-replication
      mix imp.benchmark.gepa_replication --from-gepa-artifact path/to/experiment_runs_data \\
        --upstream-evidence path/to/upstream-evidence.json \\
        --imp-input path/to/imp-gepa-rows.json --campaign-id gepa-full-YYYYMMDD

  The task does not fabricate benchmark results. It packages fresh GEPA
  replication rows produced by a campaign runner into the dashboard contract and
  fails unless every row includes the optimizer, budget, cost, seed, and split
  metadata needed for paper-level GEPA claims. `--smoke` runs a deterministic
  local Imp campaign over tiny task-shaped rows so the source-checkout gate
  exercises real code without paid provider calls.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.{ArtifactFile, GepaReplicationContract}
  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}

  @shortdoc "Validate GEPA paper-replication rows"

  @default_out_dir "benchmarks/runs/gepa-replication"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          input: :string,
          from_gepa_artifact: :string,
          upstream_evidence: :string,
          imp_input: :string,
          campaign_id: :string,
          artifact_model: :string,
          out: :string,
          smoke: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input = Keyword.get(opts, :input)
    artifact_dir = Keyword.get(opts, :from_gepa_artifact)
    out_dir = Keyword.get(opts, :out, @default_out_dir)
    File.mkdir_p!(out_dir)

    rows = load_rows!(opts, input, artifact_dir)

    smoke? = Keyword.get(opts, :smoke, false)

    validation =
      GepaReplicationContract.validate_rows(rows,
        mode: if(smoke?, do: :smoke, else: :research)
      )

    passing = validation.passing
    full_research = passing and not smoke?

    artifact = %{
      "schema_version" => 1,
      "runner" => "imp-gepa-replication",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "source" => artifact_source(opts, input, artifact_dir),
      "summary" => %{
        "total" => length(rows),
        "passing" => if(passing, do: length(rows), else: 0),
        "all_passing" => passing,
        "full_gepa_replication" => full_research,
        "missing_families" => validation.missing_families,
        "duplicate_families" => validation.duplicate_families,
        "unknown_families" => validation.unknown_families,
        "missing_fields" => validation.missing_fields,
        "evidence_level" => if(full_research, do: "research_campaign", else: "smoke")
      },
      "rows" => rows
    }

    out_path = Path.join(out_dir, "gepa-replication-#{timestamp_slug()}.json")
    out_path = ArtifactFile.write_json!(out_path, artifact)
    Mix.shell().info("GEPA replication artifact: #{out_path}")

    unless passing do
      Mix.raise("GEPA replication artifact is incomplete; inspect #{out_path}")
    end
  end

  defp load_rows!(opts, input, artifact_dir) do
    cond do
      Keyword.get(opts, :smoke, false) and is_nil(input) ->
        smoke_rows()

      is_binary(input) ->
        input |> File.read!() |> Jason.decode!() |> normalize_rows!()

      is_binary(artifact_dir) ->
        gepa_artifact_rows!(artifact_dir, opts)

      true ->
        Mix.raise("--input, --from-gepa-artifact, or --smoke is required")
    end
  end

  defp artifact_source(opts, input, artifact_dir) do
    evidence = Keyword.get(opts, :upstream_evidence)

    %{
      "input" => input || artifact_dir,
      "input_sha256" => if(input, do: file_sha256(input)),
      "upstream_evidence" => evidence,
      "upstream_evidence_sha256" => if(evidence, do: file_sha256(evidence)),
      "mode" => if(Keyword.get(opts, :smoke, false), do: "smoke", else: "input"),
      "families_required" => GepaReplicationContract.required_families()
    }
  end

  defp normalize_rows!(%{"rows" => rows}) when is_list(rows), do: rows
  defp normalize_rows!(rows) when is_list(rows), do: rows

  defp normalize_rows!(other) do
    Mix.raise(
      "GEPA replication input must be a list of rows or a map with \"rows\", got: #{inspect(other)}"
    )
  end

  defp gepa_artifact_rows!(artifact_dir, opts) do
    imp_input =
      Keyword.get(opts, :imp_input) ||
        Mix.raise("--from-gepa-artifact requires --imp-input with Imp GEPA rows")

    campaign_id =
      Keyword.get(opts, :campaign_id) ||
        Mix.raise("--from-gepa-artifact requires --campaign-id")

    upstream_evidence =
      Keyword.get(opts, :upstream_evidence) ||
        Mix.raise(
          "--from-gepa-artifact requires --upstream-evidence; evaluation_result.txt does not prove metric calls, budget enforcement, seed selection, or test provenance"
        )

    imp_rows =
      imp_input
      |> File.read!()
      |> Jason.decode!()
      |> normalize_rows!()
      |> unique_map!(& &1["family"], "Imp GEPA family rows")

    results = artifact_dir |> experiment_runs_dir!() |> read_upstream_results()
    {model, selected_results} = select_upstream_model(results, Keyword.get(opts, :artifact_model))
    evidence = read_upstream_evidence!(upstream_evidence, model)

    rows_from_upstream!({model, selected_results}, evidence, imp_rows, campaign_id)
  end

  defp experiment_runs_dir!(artifact_dir) do
    cond do
      File.dir?(Path.join(artifact_dir, "experiment_runs")) ->
        Path.join(artifact_dir, "experiment_runs")

      File.dir?(Path.join(artifact_dir, "experiment_runs_data/experiment_runs")) ->
        Path.join(artifact_dir, "experiment_runs_data/experiment_runs")

      true ->
        Mix.raise(
          "--from-gepa-artifact must point at a GEPA artifact repo, experiment_runs_data, or experiment_runs dir; got #{artifact_dir}"
        )
    end
  end

  defp read_upstream_results(runs_dir) do
    runs_dir
    |> Path.join("seed_*/*/evaluation_results/evaluation_result.txt")
    |> Path.wildcard()
    |> Enum.map(&read_upstream_result!/1)
  end

  defp read_upstream_result!(path) do
    run_name =
      path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.basename()

    [family, program, optimizer, model] = String.split(run_name, "_", parts: 4)

    seed =
      path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.basename()
      |> parse_seed!()

    %{
      family: family,
      program: program,
      optimizer: optimizer,
      model: model,
      seed: seed,
      path: path,
      result: parse_evaluation_result!(path)
    }
  end

  defp parse_seed!("seed_" <> seed) do
    case Integer.parse(seed) do
      {value, ""} -> value
      _ -> Mix.raise("invalid upstream seed directory: seed_#{seed}")
    end
  end

  defp parse_seed!(directory), do: Mix.raise("invalid upstream seed directory: #{directory}")

  defp parse_evaluation_result!(path) do
    [header, values | _rest] = path |> File.read!() |> String.split("\n", trim: true)
    keys = header |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    vals = values |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    keys
    |> Enum.zip(vals)
    |> Map.new(fn {key, value} -> {key, parse_number(value)} end)
  end

  defp parse_number(value) do
    cond do
      String.match?(value, ~r/^-?\d+$/) -> String.to_integer(value)
      String.match?(value, ~r/^-?\d+\.\d+$/) -> String.to_float(value)
      true -> value
    end
  end

  defp select_upstream_model(results, nil) do
    case results |> Enum.map(& &1.model) |> Enum.uniq() do
      [model] ->
        {model, results}

      [] ->
        Mix.raise("no GEPA artifact evaluation_result.txt files found")

      models ->
        Mix.raise(
          "--artifact-model is required when GEPA artifact results contain multiple models: #{Enum.join(models, ", ")}"
        )
    end
  end

  defp select_upstream_model(results, model) do
    selected = Enum.filter(results, &(&1.model == model))

    if selected == [],
      do: Mix.raise("no GEPA artifact results found for --artifact-model #{model}")

    {model, selected}
  end

  defp rows_from_upstream!({model, results}, evidence, imp_rows, campaign_id) do
    grouped =
      unique_map!(
        results,
        &{&1.family, &1.program, &1.optimizer, &1.seed},
        "upstream GEPA result rows"
      )

    Enum.map(required_family_programs(), fn {family, program, _budget} ->
      imp = Map.get(imp_rows, family) || Mix.raise("missing Imp GEPA row for #{family}")

      ensure_imp_identity!(imp, family, program, model, campaign_id)

      comparator_rows =
        Enum.map(comparator_optimizers(), fn {upstream_name, field} ->
          run_evidence = fetch_evidence!(evidence, family, program, upstream_name)
          upstream = fetch_upstream!(grouped, family, program, upstream_name, run_evidence.seed)
          validate_evidence_against_result!(run_evidence, upstream)
          {field, upstream_name, upstream, run_evidence}
        end)

      merge_comparator_evidence!(imp, comparator_rows, campaign_id)
    end)
  end

  defp read_upstream_evidence!(path, model) do
    evidence = path |> File.read!() |> Jason.decode!()
    source = evidence["source"]

    unless evidence["schema_version"] == 1 and evidence["kind"] == "gepa_upstream_evidence" and
             is_list(evidence["runs"]) and is_map(source) and
             sha256?(source["archive_sha256"]) and
             concrete_evidence_source?(source["upstream_commit"]) do
      Mix.raise("invalid upstream evidence sidecar schema in #{path}")
    end

    runs = Enum.map(evidence["runs"], &validate_evidence_run!(&1, model, path))
    keyed = unique_map!(runs, &{&1.family, &1.program, &1.optimizer}, "upstream evidence rows")

    expected_keys =
      for {family, program, _budget} <- required_family_programs(),
          {optimizer, _field} <- comparator_optimizers(),
          do: {family, program, optimizer}

    unless MapSet.new(Map.keys(keyed)) == MapSet.new(expected_keys) do
      Mix.raise("upstream evidence sidecar must contain exactly the required comparator runs")
    end

    keyed
  end

  defp validate_evidence_run!(run, model, path) when is_map(run) do
    metric = run["metric_call_evidence"]
    selection = run["seed_selection"]
    evaluation = run["evaluation"]
    seed = run["seed"]

    unless valid_evidence_identity?(run, model) do
      Mix.raise("invalid upstream evidence identity in #{path}: #{inspect(run)}")
    end

    unless supported_metric_evidence?(metric) do
      Mix.raise(
        "upstream evidence must contain observed, enforced, within-budget metric calls for #{run["family"]}/#{run["optimizer"]}; configured budgets alone are not evidence"
      )
    end

    unless supported_seed_selection?(selection, seed) do
      Mix.raise(
        "upstream evidence must prove non-test seed selection for #{run["family"]}/#{run["optimizer"]}"
      )
    end

    unless valid_evaluation_evidence?(evaluation) do
      Mix.raise("invalid test-score provenance for #{run["family"]}/#{run["optimizer"]}")
    end

    %{
      family: run["family"],
      program: run["program"],
      optimizer: run["optimizer"],
      seed: seed,
      metric: metric,
      selection: selection,
      evaluation: evaluation
    }
  end

  defp validate_evidence_run!(run, _model, path) do
    Mix.raise("invalid upstream evidence row in #{path}: #{inspect(run)}")
  end

  defp valid_evidence_identity?(run, model) do
    is_binary(run["family"]) and is_binary(run["program"]) and
      run["optimizer"] in Enum.map(comparator_optimizers(), &elem(&1, 0)) and
      run["model"] == model and is_integer(run["seed"])
  end

  defp valid_evaluation_evidence?(evaluation) when is_map(evaluation) do
    evaluation["split"] == "test" and evaluation["test_scores_used_for_selection"] == false and
      is_number(evaluation["score"]) and sha256?(evaluation["result_sha256"]) and
      concrete_evidence_source?(evaluation["source"])
  end

  defp valid_evaluation_evidence?(_evaluation), do: false

  defp supported_metric_evidence?(metric) when is_map(metric) do
    observed = metric["observed"]
    limit = metric["configured_limit"]

    metric["basis"] == "observed_metric_callback_count" and positive_integer?(observed) and
      positive_integer?(limit) and metric["enforced"] == true and observed <= limit and
      concrete_evidence_source?(metric["source"])
  end

  defp supported_metric_evidence?(_metric), do: false

  defp supported_seed_selection?(selection, seed) when is_map(selection) do
    seeds = selection["seeds"]

    valid_seed_list?(seeds, seed, selection["selected_seed"]) and
      selection["test_scores_used"] == false and
      concrete_evidence_source?(selection["source"]) and valid_selection_method?(selection)
  end

  defp supported_seed_selection?(_selection, _seed), do: false

  defp valid_seed_list?(seeds, seed, selected_seed) do
    is_list(seeds) and seeds != [] and Enum.all?(seeds, &is_integer/1) and
      length(seeds) == length(Enum.uniq(seeds)) and seed == selected_seed and seed in seeds
  end

  defp valid_selection_method?(%{"method" => "predeclared", "selection_split" => split}),
    do: is_nil(split)

  defp valid_selection_method?(%{"method" => "best_dev", "selection_split" => "dev"}),
    do: true

  defp valid_selection_method?(_selection), do: false

  defp validate_evidence_against_result!(evidence, upstream) do
    evaluation = evidence.evaluation

    unless numbers_equal?(evaluation["score"], upstream.result["score"]) and
             evaluation["result_sha256"] == file_sha256(upstream.path) do
      Mix.raise(
        "upstream evidence does not match evaluation_result.txt for #{evidence.family}/#{evidence.optimizer}/seed_#{evidence.seed}"
      )
    end
  end

  defp ensure_imp_identity!(imp, family, program, model, campaign_id) do
    expected = %{
      "family" => family,
      "program" => program,
      "model" => model,
      "campaign_id" => campaign_id
    }

    Enum.each(expected, fn {field, value} ->
      unless imp[field] in [nil, value] do
        Mix.raise(
          "Imp row #{family} has #{field}=#{inspect(imp[field])}, expected #{inspect(value)}; converter will not overwrite Imp evidence"
        )
      end
    end)

    unless is_map(get_in(imp, ["results", "imp_gepa"])) and
             is_map(get_in(imp, ["metric_call_evidence", "observed"])) and
             positive_integer?(get_in(imp, ["optimizer_budgets", "imp_gepa"])) and
             is_map(get_in(imp, ["seed_selection", "imp_gepa"])) do
      Mix.raise("Imp row #{family} is missing Imp-owned research evidence")
    end
  end

  defp merge_comparator_evidence!(imp, comparator_rows, campaign_id) do
    imp =
      update_in(imp, ["metric_call_evidence"], fn evidence ->
        Map.put_new(evidence, "upstream_sources", %{})
      end)

    Enum.reduce(comparator_rows, Map.put_new(imp, "campaign_id", campaign_id), fn
      {field, upstream_name, upstream, evidence}, row ->
        row
        |> put_nested_new_or_equal!(
          [
            "optimizer_budgets",
            field
          ],
          evidence.metric["configured_limit"]
        )
        |> put_nested_new_or_equal!(
          [
            "metric_call_evidence",
            "observed",
            field
          ],
          evidence.metric["observed"]
        )
        |> put_nested_new_or_equal!(["metric_call_evidence", "enforced_limits", field], true)
        |> put_nested_new_or_equal!(
          [
            "metric_call_evidence",
            "upstream_sources",
            field
          ],
          evidence.metric["source"]
        )
        |> put_nested_new_or_equal!(["seed_selection", field], evidence.selection)
        |> put_nested_new_or_equal!(
          [
            "results",
            field
          ],
          upstream_result(upstream_name, upstream, evidence.evaluation)
        )
    end)
  end

  defp put_nested_new_or_equal!(row, path, value) do
    case get_in(row, path) do
      nil ->
        put_in(row, path, value)

      ^value ->
        row

      existing ->
        Mix.raise(
          "refusing to overwrite Imp evidence at #{Enum.join(path, ".")}: #{inspect(existing)}"
        )
    end
  end

  defp unique_map!(values, key_fun, label) do
    duplicates =
      values
      |> Enum.group_by(key_fun)
      |> Enum.filter(fn {_key, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [], do: Mix.raise("duplicate #{label}: #{inspect(duplicates)}")
    Map.new(values, &{key_fun.(&1), &1})
  end

  defp fetch_upstream!(grouped, family, program, optimizer, seed) do
    Map.get(grouped, {family, program, optimizer, seed}) ||
      Mix.raise("missing GEPA artifact result for #{family}/#{program}/#{optimizer}/seed_#{seed}")
  end

  defp fetch_evidence!(evidence, family, program, optimizer) do
    Map.get(evidence, {family, program, optimizer}) ||
      Mix.raise("missing upstream evidence for #{family}/#{program}/#{optimizer}")
  end

  defp upstream_result(optimizer, upstream, evaluation) do
    %{
      "score" => upstream.result["score"],
      "source" => "gepa-artifact #{optimizer} evaluation_result #{upstream.path}",
      "evaluation_split" => "test",
      "evaluation_result_sha256" => evaluation["result_sha256"],
      "cost" => upstream.result["cost"],
      "input_tokens" => upstream.result["input_tokens"],
      "output_tokens" => upstream.result["output_tokens"]
    }
  end

  defp comparator_optimizers do
    [
      {"Baseline", "baseline"},
      {"GEPA", "dspy_gepa"},
      {"MIPROv2-Heavy", "mipro_v2"}
    ]
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp numbers_equal?(left, right) when is_number(left) and is_number(right), do: left == right
  defp numbers_equal?(_left, _right), do: false

  defp sha256?(value),
    do: is_binary(value) and String.match?(value, ~r/^[0-9a-f]{64}$/)

  defp concrete_evidence_source?(value),
    do: is_binary(value) and String.trim(value) != ""

  defp required_family_programs do
    [
      {"AIMEBench", "CoT", 1839},
      {"HotpotQABench", "HotpotMultiHop", 6871},
      {"hoverBench", "HoverMultiHop", 7051},
      {"IFBench", "IFBenchCoT2StageProgram", 3593},
      {"LiveBenchMathBench", "CoT", 1839},
      {"Papillon", "PAPILLON", 2426}
    ]
  end

  defp smoke_rows do
    [
      {"AIMEBench", "CoT", 1839, ["structured_solution", "integer_answer"]},
      {"HotpotQABench", "HotpotMultiHop", 6871, ["bridge_entity", "final_answer"]},
      {"hoverBench", "HoverMultiHop", 7051, ["claim_verdict", "support_titles"]},
      {"IFBench", "IFBenchCoT2StageProgram", 3593, ["format_rule", "correction_rule"]},
      {"LiveBenchMathBench", "CoT", 1839, ["dated_math", "final_answer"]},
      {"Papillon", "PAPILLON", 2426, ["privacy_redaction", "useful_answer"]}
    ]
    |> Enum.map(fn {family, program, metric_calls, requirements} ->
      smoke_row(family, program, metric_calls, requirements)
    end)
  end

  defp smoke_row(family, program, metric_calls, requirements) do
    examples = requirements
    baseline_text = "Solve the task."

    imp_report =
      Anything.run(
        baseline_text,
        smoke_evaluator(),
        dataset: examples,
        valset: examples,
        config:
          Config.new(
            engine: [max_candidate_proposals: length(requirements), parallel: false],
            reflection: [
              custom_candidate_proposer: fn candidate, component, _records, iteration ->
                requirement = Enum.fetch!(requirements, iteration - 1)
                Map.fetch!(candidate, component) <> "\n" <> requirement
              end
            ]
          )
      )

    baseline_score = hd(imp_report.validation_scores)

    imp_score =
      imp_report |> Result.best_index() |> then(&Enum.at(imp_report.validation_scores, &1))

    %{
      "family" => family,
      "program" => program,
      "model" => "deterministic/local-gepa-smoke",
      "reflection_model" => "deterministic/mutation-fn",
      "metric_calls" => metric_calls,
      "actual_metric_calls" => imp_report.total_metric_calls,
      "token_cost" => %{
        "usd" => 0.0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "pricing_source" => "provider-free deterministic smoke"
      },
      "wall_clock_ms" => 0,
      "seed_variance" => %{"seeds" => [0], "mean" => imp_score, "stddev" => 0.0},
      "train_dev_test_gap" => %{
        "train" => imp_score,
        "dev" => imp_score,
        "test" => imp_score,
        "note" => "smoke rows use the same tiny deterministic requirements for all splits"
      },
      "results" => %{
        "baseline" => %{"score" => baseline_score, "source" => "Imp smoke baseline"},
        "dspy_gepa" => %{
          "score" => imp_score,
          "source" => "provider-free smoke placeholder; real DSPy GEPA rows required by de-b10z"
        },
        "imp_gepa" => %{
          "score" => imp_score,
          "source" => "Imp.Optimize.Anything.run/3",
          "candidate_count" => length(imp_report.candidates),
          "frontier_size" => map_size(imp_report.instance_frontier)
        },
        "mipro_v2" => %{
          "score" => baseline_score,
          "source" => "not run in smoke; real MIPROv2 rows required by de-b10z"
        },
        "simba" => %{
          "score" => baseline_score,
          "source" => "optional extra comparator; not required by GEPA artifact"
        }
      }
    }
  end

  defp smoke_evaluator,
    do: fn candidate, requirement ->
      if String.contains?(candidate, requirement),
        do: 1.0,
        else:
          {0.0,
           %{feedback: requirement, diagnostics: ["deterministic GEPA replication smoke row"]}}
    end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace("Z", "Z")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

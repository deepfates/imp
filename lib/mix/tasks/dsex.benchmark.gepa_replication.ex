defmodule Mix.Tasks.Dsex.Benchmark.GepaReplication do
  @moduledoc """
  Validate and emit GEPA paper-replication evidence artifacts.

      mix dsex.benchmark.gepa_replication --smoke --out tmp/gepa-replication
      mix dsex.benchmark.gepa_replication --input path/to/rows.json --out tmp/gepa-replication
      mix dsex.benchmark.gepa_replication --from-gepa-artifact path/to/experiment_runs_data \\
        --dsex-input path/to/dsex-gepa-rows.json --campaign-id gepa-full-YYYYMMDD

  The task does not fabricate benchmark results. It packages fresh GEPA
  replication rows produced by a campaign runner into the dashboard contract and
  fails unless every row includes the optimizer, budget, cost, seed, and split
  metadata needed for paper-level GEPA claims. `--smoke` runs a deterministic
  local DSEx campaign over tiny task-shaped rows so the source-checkout gate
  exercises real code without paid provider calls.
  """

  use Mix.Task

  @shortdoc "Validate GEPA paper-replication rows"

  @default_out_dir "benchmarks/results"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          input: :string,
          from_gepa_artifact: :string,
          dsex_input: :string,
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

    rows =
      cond do
        Keyword.get(opts, :smoke, false) and is_nil(input) ->
          smoke_rows()

        is_binary(input) ->
          input
          |> File.read!()
          |> Jason.decode!()
          |> normalize_rows!()

        is_binary(artifact_dir) ->
          gepa_artifact_rows!(artifact_dir, opts)

        true ->
          Mix.raise("--input, --from-gepa-artifact, or --smoke is required")
      end

    smoke? = Keyword.get(opts, :smoke, false)

    validation =
      DSEx.BenchmarkTruth.GepaReplicationContract.validate_rows(rows,
        mode: if(smoke?, do: :smoke, else: :research)
      )

    passing = validation.passing
    full_research = passing and not smoke?

    artifact = %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-replication",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "source" => %{
        "input" => input || artifact_dir,
        "input_sha256" => if(input, do: file_sha256(input)),
        "mode" => if(Keyword.get(opts, :smoke, false), do: "smoke", else: "input"),
        "families_required" => DSEx.BenchmarkTruth.GepaReplicationContract.required_families()
      },
      "summary" => %{
        "total" => length(rows),
        "passing" => if(passing, do: length(rows), else: 0),
        "all_passing" => passing,
        "full_gepa_replication" => full_research,
        "missing_families" => validation.missing_families,
        "missing_fields" => validation.missing_fields,
        "evidence_level" => if(full_research, do: "research_campaign", else: "smoke")
      },
      "rows" => rows
    }

    out_path = Path.join(out_dir, "gepa-replication-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(artifact, pretty: true) <> "\n")
    Mix.shell().info("GEPA replication artifact: #{out_path}")

    unless passing do
      Mix.raise("GEPA replication artifact is incomplete; inspect #{out_path}")
    end
  end

  defp normalize_rows!(%{"rows" => rows}) when is_list(rows), do: rows
  defp normalize_rows!(rows) when is_list(rows), do: rows

  defp normalize_rows!(other) do
    Mix.raise(
      "GEPA replication input must be a list of rows or a map with \"rows\", got: #{inspect(other)}"
    )
  end

  defp gepa_artifact_rows!(artifact_dir, opts) do
    dsex_input =
      Keyword.get(opts, :dsex_input) ||
        Mix.raise("--from-gepa-artifact requires --dsex-input with DSEx GEPA rows")

    campaign_id =
      Keyword.get(opts, :campaign_id) ||
        Mix.raise("--from-gepa-artifact requires --campaign-id")

    dsex_rows =
      dsex_input
      |> File.read!()
      |> Jason.decode!()
      |> normalize_rows!()
      |> Map.new(&{&1["family"], &1})

    artifact_dir
    |> experiment_runs_dir!()
    |> read_upstream_results()
    |> select_upstream_model(Keyword.get(opts, :artifact_model))
    |> rows_from_upstream!(dsex_rows, campaign_id)
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

    %{
      family: family,
      program: program,
      optimizer: optimizer,
      model: model,
      path: path,
      result: parse_evaluation_result!(path)
    }
  end

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

  defp rows_from_upstream!({model, results}, dsex_rows, campaign_id) do
    grouped =
      Map.new(results, fn result ->
        {{result.family, result.program, result.optimizer}, result}
      end)

    Enum.map(required_family_programs(), fn {family, program, budget} ->
      baseline = fetch_upstream!(grouped, family, program, "Baseline")
      dspy_gepa = fetch_upstream!(grouped, family, program, "GEPA")
      mipro = fetch_upstream!(grouped, family, program, "MIPROv2-Heavy")
      dsex = Map.get(dsex_rows, family) || Mix.raise("missing DSEx GEPA row for #{family}")

      dsex
      |> Map.merge(%{
        "family" => family,
        "program" => program,
        "campaign_id" => campaign_id,
        "model" => model,
        "evidence_level" => "research_campaign",
        "metric_calls" => budget,
        "optimizer_budgets" => %{
          "baseline" => 1,
          "dspy_gepa" => budget,
          "dsex_gepa" => get_in(dsex, ["optimizer_budgets", "dsex_gepa"]) || budget,
          "mipro_v2" => budget
        },
        "results" => %{
          "baseline" => upstream_result("Baseline", baseline),
          "dspy_gepa" => upstream_result("GEPA", dspy_gepa),
          "dsex_gepa" => get_in(dsex, ["results", "dsex_gepa"]),
          "mipro_v2" => upstream_result("MIPROv2-Heavy", mipro)
        }
      })
    end)
  end

  defp fetch_upstream!(grouped, family, program, optimizer) do
    Map.get(grouped, {family, program, optimizer}) ||
      Mix.raise("missing GEPA artifact result for #{family}/#{program}/#{optimizer}")
  end

  defp upstream_result(optimizer, upstream) do
    %{
      "score" => upstream.result["score"],
      "source" => "gepa-artifact #{optimizer} evaluation_result #{upstream.path}",
      "cost" => upstream.result["cost"],
      "input_tokens" => upstream.result["input_tokens"],
      "output_tokens" => upstream.result["output_tokens"]
    }
  end

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

    dsex_report =
      DSEx.Optimize.GEPA.optimize(
        DSEx.Optimize.Anything.new_artifact(:instruction, baseline_text),
        smoke_evaluator(),
        examples: examples,
        dev_examples: examples,
        generations: length(requirements),
        mutation_fn: fn _artifact, asi, _generation -> Enum.join(asi, "\n") end
      )

    baseline_score = dsex_report.baseline.aggregate_score
    dsex_score = dsex_report.best.metadata.dev_score || dsex_report.best.aggregate_score

    %{
      "family" => family,
      "program" => program,
      "model" => "deterministic/local-gepa-smoke",
      "reflection_model" => "deterministic/mutation-fn",
      "metric_calls" => metric_calls,
      "actual_metric_calls" => length(dsex_report.candidates) * length(examples),
      "token_cost" => %{
        "usd" => 0.0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "pricing_source" => "provider-free deterministic smoke"
      },
      "wall_clock_ms" => 0,
      "seed_variance" => %{"seeds" => [0], "mean" => dsex_score, "stddev" => 0.0},
      "train_dev_test_gap" => %{
        "train" => dsex_score,
        "dev" => dsex_score,
        "test" => dsex_score,
        "note" => "smoke rows use the same tiny deterministic requirements for all splits"
      },
      "results" => %{
        "baseline" => %{"score" => baseline_score, "source" => "DSEx smoke baseline"},
        "dspy_gepa" => %{
          "score" => dsex_score,
          "source" => "provider-free smoke placeholder; real DSPy GEPA rows required by de-b10z"
        },
        "dsex_gepa" => %{
          "score" => dsex_score,
          "source" => "DSEx.Optimize.GEPA",
          "candidate_count" => length(dsex_report.candidates),
          "frontier_size" => length(dsex_report.frontier)
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

  defp smoke_evaluator do
    fn artifact, examples ->
      scores =
        Enum.map(examples, fn requirement ->
          if String.contains?(artifact.text, requirement), do: 1.0, else: 0.0
        end)

      %{
        per_example_scores: scores,
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1)),
        diagnostics: ["deterministic GEPA replication smoke row"]
      }
    end
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

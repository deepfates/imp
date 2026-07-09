defmodule Mix.Tasks.Dsex.Benchmark.GepaReplication do
  @moduledoc """
  Validate and emit GEPA paper-replication evidence artifacts.

      mix dsex.benchmark.gepa_replication --smoke --out tmp/gepa-replication
      mix dsex.benchmark.gepa_replication --input path/to/rows.json --out tmp/gepa-replication

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

  @required_families [
    "AIMEBench",
    "HotpotQABench",
    "hoverBench",
    "IFBench",
    "LiveBenchMathBench",
    "Papillon"
  ]

  @optimizer_fields ["baseline", "dspy_gepa", "dsex_gepa", "mipro_v2"]
  @required_fields [
    "metric_calls",
    "token_cost",
    "wall_clock_ms",
    "seed_variance",
    "train_dev_test_gap"
  ]

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          input: :string,
          out: :string,
          smoke: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input = Keyword.get(opts, :input)
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

        true ->
          Mix.raise("--input or --smoke is required")
      end

    validation = validate_rows(rows)
    passing = validation.missing_families == [] and validation.missing_fields == []
    full_research = passing and not Keyword.get(opts, :smoke, false)

    artifact = %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-replication",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "source" => %{
        "input" => input,
        "input_sha256" => if(input, do: file_sha256(input)),
        "mode" => if(Keyword.get(opts, :smoke, false), do: "smoke", else: "input"),
        "families_required" => @required_families
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

  defp validate_rows(rows) do
    present_families = rows |> Enum.map(& &1["family"]) |> Enum.uniq()

    %{
      missing_families: @required_families -- present_families,
      missing_fields:
        rows
        |> Enum.flat_map(fn row ->
          (@optimizer_fields ++ @required_fields)
          |> Enum.reject(&present_field?(row, &1))
          |> Enum.map(&%{"family" => row["family"], "field" => &1})
        end)
    }
  end

  defp present_field?(row, field) when field in @optimizer_fields do
    row
    |> Map.get("results", %{})
    |> Map.get(field)
    |> is_map()
  end

  defp present_field?(row, field), do: Map.has_key?(row, field)

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

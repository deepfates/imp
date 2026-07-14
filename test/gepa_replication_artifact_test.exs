defmodule GepaReplicationArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DSEx.BenchmarkTruth.GepaReplicationContract
  alias Mix.Tasks.Dsex.Benchmark.GepaReplication, as: GepaReplicationTask

  test "GEPA replication task validates required paper-family fields and writes artifact" do
    out_dir = tmp_dir("gepa-replication")
    input_path = write_rows!("complete-gepa", full_rows())

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_replication")

      GepaReplicationTask.run([
        "--input",
        input_path,
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["full_gepa_replication"]
    assert artifact["summary"]["missing_families"] == []
    assert artifact["summary"]["missing_fields"] == []

    assert Enum.map(artifact["rows"], & &1["family"]) == [
             "AIMEBench",
             "HotpotQABench",
             "hoverBench",
             "IFBench",
             "LiveBenchMathBench",
             "Papillon"
           ]

    assert Enum.all?(artifact["rows"], fn row ->
             is_map(row["results"]["baseline"]) and
               is_map(row["results"]["dspy_gepa"]) and
               is_map(row["results"]["dsex_gepa"]) and
               is_map(row["results"]["mipro_v2"]) and
               is_map(row["token_cost"]) and
               is_map(row["seed_variance"]) and
               is_map(row["train_dev_test_gap"]) and
               is_integer(row["metric_calls"]) and
               is_integer(row["wall_clock_ms"]) and
               is_map(row["dataset"]) and
               is_map(row["optimizer_budgets"]) and
               is_map(row["source_commits"])
           end)
  end

  test "GEPA replication task rejects forged full rows with placeholder comparator evidence" do
    out_dir = tmp_dir("gepa-replication-forged")
    [row | rest] = full_rows()

    forged =
      [
        put_in(row, ["results", "dspy_gepa", "source"], "placeholder DSPy GEPA row")
      ] ++ rest

    input_path = write_rows!("forged-gepa", forged)

    assert_raise Mix.Error, ~r/GEPA replication artifact is incomplete/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("dsex.benchmark.gepa_replication")

        GepaReplicationTask.run([
          "--input",
          input_path,
          "--out",
          out_dir
        ])
      end)
    end

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    refute artifact["summary"]["all_passing"]
    refute artifact["summary"]["full_gepa_replication"]

    assert %{"family" => "AIMEBench", "field" => "dspy_gepa"} in artifact["summary"][
             "missing_fields"
           ]
  end

  test "GEPA replication contract rejects unknown or noncanonical source identities" do
    [row | rest] = full_rows()

    unknown = put_in(row, ["source_commits", "dspy"], "unknown")
    extra = put_in(row, ["source_commits", "untracked"], "example/repo@abcdef4")

    for invalid <- [unknown, extra] do
      validation = GepaReplicationContract.validate_rows([invalid | rest])

      refute validation.passing
      assert %{"family" => "AIMEBench", "field" => "source_commits"} in validation.missing_fields
    end
  end

  test "GEPA replication contract rejects duplicate and unknown family rows" do
    rows = full_rows()
    duplicate = rows ++ [hd(rows)]
    unknown = rows ++ [Map.put(hd(rows), "family", "UnknownBench")]

    duplicate_validation =
      GepaReplicationContract.validate_rows(duplicate)

    refute duplicate_validation.passing
    assert duplicate_validation.duplicate_families == ["AIMEBench"]
    assert duplicate_validation.unknown_families == []

    unknown_validation = GepaReplicationContract.validate_rows(unknown)
    refute unknown_validation.passing
    assert unknown_validation.unknown_families == ["UnknownBench"]
  end

  test "GEPA research evidence rejects configured budgets presented as metric-call counts" do
    rows =
      Enum.map(full_rows(), fn row ->
        row
        |> Map.delete("metric_call_evidence")
        |> Map.put("metric_calls", get_in(row, ["optimizer_budgets", "dsex_gepa"]))
      end)

    validation = GepaReplicationContract.validate_rows(rows)

    refute validation.passing

    assert %{"family" => "AIMEBench", "field" => "metric_call_evidence"} in validation.missing_fields

    refute GepaReplicationContract.full_artifact?(full_artifact(rows))
  end

  test "GEPA research evidence rejects non-observed call bases and unenforced counts" do
    [configured_row, unenforced_row | rest] = full_rows()

    configured =
      put_in(configured_row, ["metric_call_evidence", "basis"], "configured_budget")

    unenforced =
      unenforced_row
      |> put_in(["metric_call_evidence", "enforced_limits", "dsex_gepa"], false)

    rows = [configured, unenforced | rest]
    validation = GepaReplicationContract.validate_rows(rows)

    refute validation.passing

    assert %{"family" => "AIMEBench", "field" => "metric_call_evidence"} in validation.missing_fields

    assert %{"family" => "HotpotQABench", "field" => "metric_call_evidence"} in validation.missing_fields
  end

  test "GEPA research evidence rejects best-test seed selection" do
    rows =
      Enum.map(full_rows(), fn row ->
        row
        |> put_in(["seed_selection", "dsex_gepa", "method"], "best_test")
        |> put_in(["seed_selection", "dsex_gepa", "selection_split"], "test")
        |> put_in(["seed_selection", "dsex_gepa", "test_scores_used"], true)
      end)

    validation = GepaReplicationContract.validate_rows(rows)

    refute validation.passing
    assert %{"family" => "AIMEBench", "field" => "seed_selection"} in validation.missing_fields
    refute GepaReplicationContract.full_artifact?(full_artifact(rows))
  end

  test "GEPA research evidence requires exact retrieval for both executed retrieval families" do
    for family <- ["HotpotQABench", "hoverBench"] do
      rows =
        Enum.map(full_rows(), fn
          %{"family" => ^family} = row -> put_in(row, ["dataset", "retrieval"], nil)
          row -> row
        end)

      validation = GepaReplicationContract.validate_rows(rows)
      refute validation.passing
      assert %{"family" => family, "field" => "dataset"} in validation.missing_fields
    end
  end

  test "GEPA replication task rejects Papillon research rows without judge metadata" do
    out_dir = tmp_dir("gepa-replication-papillon-judge")

    forged =
      full_rows()
      |> Enum.map(fn
        %{"family" => "Papillon"} = row -> Map.delete(row, "metric_judge")
        row -> row
      end)

    input_path = write_rows!("forged-papillon-judge", forged)

    assert_raise Mix.Error, ~r/GEPA replication artifact is incomplete/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("dsex.benchmark.gepa_replication")

        GepaReplicationTask.run([
          "--input",
          input_path,
          "--out",
          out_dir
        ])
      end)
    end

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert %{"family" => "Papillon", "field" => "metric_judge"} in artifact["summary"][
             "missing_fields"
           ]
  end

  test "GEPA replication task rejects capped dataset rows for full research claims" do
    out_dir = tmp_dir("gepa-replication-capped-dataset")

    capped =
      Enum.map(full_rows(), fn row ->
        row
        |> put_in(["dataset", "scope"], "capped")
        |> put_in(["dataset", "max_per_split"], 1)
        |> put_in(["dataset", "split_counts"], %{"train" => 1, "dev" => 1, "test" => 1})
      end)

    input_path = write_rows!("capped-gepa", capped)

    assert_raise Mix.Error, ~r/GEPA replication artifact is incomplete/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("dsex.benchmark.gepa_replication")

        GepaReplicationTask.run([
          "--input",
          input_path,
          "--out",
          out_dir
        ])
      end)
    end

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    refute artifact["summary"]["full_gepa_replication"]

    assert %{"family" => "AIMEBench", "field" => "dataset"} in artifact["summary"][
             "missing_fields"
           ]
  end

  test "GEPA replication task converts upstream GEPA artifact outputs plus DSEx rows" do
    artifact_dir = tmp_dir("gepa-artifact-output")
    out_dir = tmp_dir("gepa-artifact-converted")
    write_upstream_gepa_results!(artifact_dir, "gpt-41-mini")
    dsex_rows = converter_dsex_rows("gpt-41-mini", "gepa-conversion-test")
    dsex_input = write_rows!("dsex-gepa-rows", dsex_rows)
    evidence_path = write_upstream_evidence!(artifact_dir, "gpt-41-mini")

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_replication")

      GepaReplicationTask.run([
        "--from-gepa-artifact",
        artifact_dir,
        "--dsex-input",
        dsex_input,
        "--upstream-evidence",
        evidence_path,
        "--campaign-id",
        "gepa-conversion-test",
        "--artifact-model",
        "gpt-41-mini",
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["full_gepa_replication"]
    assert artifact["source"]["input"] == artifact_dir

    assert Enum.zip(artifact["rows"], dsex_rows)
           |> Enum.all?(fn {row, dsex} ->
             get_in(row, ["results", "baseline", "source"]) =~ "gepa-artifact Baseline" and
               get_in(row, ["results", "dspy_gepa", "source"]) =~ "gepa-artifact GEPA" and
               get_in(row, ["results", "mipro_v2", "source"]) =~
                 "gepa-artifact MIPROv2-Heavy" and
               row["metric_calls"] == dsex["metric_calls"] and
               get_in(row, ["results", "dsex_gepa"]) ==
                 get_in(dsex, ["results", "dsex_gepa"]) and
               get_in(row, ["metric_call_evidence", "observed", "dsex_gepa"]) ==
                 get_in(dsex, ["metric_call_evidence", "observed", "dsex_gepa"]) and
               get_in(row, ["seed_selection", "dsex_gepa"]) ==
                 get_in(dsex, ["seed_selection", "dsex_gepa"])
           end)
  end

  test "upstream conversion requires explicit machine-readable evidence" do
    artifact_dir = tmp_dir("gepa-artifact-no-evidence")
    write_upstream_gepa_results!(artifact_dir, "gpt-41-mini")

    assert_raise Mix.Error, ~r/requires --upstream-evidence/, fn ->
      run_upstream_conversion!(artifact_dir, nil)
    end
  end

  test "upstream conversion rejects configured-only metric-call evidence" do
    artifact_dir = tmp_dir("gepa-artifact-configured-only")
    write_upstream_gepa_results!(artifact_dir, "gpt-41-mini")

    evidence_path =
      write_upstream_evidence!(artifact_dir, "gpt-41-mini", fn evidence ->
        update_in(evidence, ["runs", Access.at(0), "metric_call_evidence"], fn metric ->
          metric
          |> Map.put("basis", "configured_budget")
          |> Map.delete("observed")
        end)
      end)

    assert_raise Mix.Error, ~r/configured budgets alone are not evidence/, fn ->
      run_upstream_conversion!(artifact_dir, evidence_path)
    end
  end

  test "upstream conversion rejects test-selected comparator evidence" do
    artifact_dir = tmp_dir("gepa-artifact-test-selected")
    write_upstream_gepa_results!(artifact_dir, "gpt-41-mini")

    evidence_path =
      write_upstream_evidence!(artifact_dir, "gpt-41-mini", fn evidence ->
        update_in(evidence, ["runs", Access.at(0), "seed_selection"], fn selection ->
          selection
          |> Map.put("method", "best_test")
          |> Map.put("selection_split", "test")
          |> Map.put("test_scores_used", true)
        end)
      end)

    assert_raise Mix.Error, ~r/non-test seed selection/, fn ->
      run_upstream_conversion!(artifact_dir, evidence_path)
    end
  end

  test "upstream conversion rejects observed calls above the enforced budget" do
    artifact_dir = tmp_dir("gepa-artifact-over-budget")
    write_upstream_gepa_results!(artifact_dir, "gpt-41-mini")

    evidence_path =
      write_upstream_evidence!(artifact_dir, "gpt-41-mini", fn evidence ->
        update_in(evidence, ["runs", Access.at(0), "metric_call_evidence"], fn metric ->
          Map.put(metric, "observed", metric["configured_limit"] + 1)
        end)
      end)

    assert_raise Mix.Error, ~r/within-budget metric calls/, fn ->
      run_upstream_conversion!(artifact_dir, evidence_path)
    end
  end

  test "GEPA replication smoke runner exercises DSEx GEPA without authorizing research claims" do
    out_dir = tmp_dir("gepa-replication-smoke")

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_replication")

      GepaReplicationTask.run([
        "--smoke",
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    refute artifact["summary"]["full_gepa_replication"]
    assert artifact["summary"]["evidence_level"] == "smoke"

    assert Enum.all?(
             artifact["rows"],
             &(get_in(&1, ["results", "dsex_gepa", "source"]) == "DSEx.Optimize.Anything.run/3")
           )
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp write_rows!(name, rows) do
    path = Path.join(tmp_dir(name), "rows.json")
    File.write!(path, Jason.encode!(%{"rows" => rows}, pretty: true))
    path
  end

  defp full_rows do
    [
      {"AIMEBench", "CoT", 1839},
      {"HotpotQABench", "HotpotMultiHop", 6871},
      {"hoverBench", "HoverMultiHop", 7051},
      {"IFBench", "IFBenchCoT2StageProgram", 3593},
      {"LiveBenchMathBench", "CoT", 1839},
      {"Papillon", "PAPILLON", 2426}
    ]
    |> Enum.map(fn {family, program, budget} ->
      full_row(family, program, budget)
    end)
  end

  defp full_artifact(rows) do
    %{
      "runner" => "dsex-gepa-replication",
      "source" => %{"mode" => "input"},
      "summary" => %{
        "all_passing" => true,
        "full_gepa_replication" => true,
        "evidence_level" => "research_campaign"
      },
      "rows" => rows
    }
  end

  defp write_upstream_gepa_results!(artifact_dir, model) do
    Enum.each(full_rows(), fn row ->
      family = row["family"]
      program = row["program"]

      [
        {"Baseline", 0.5},
        {"GEPA", 0.6},
        {"MIPROv2-Heavy", 0.55}
      ]
      |> Enum.each(fn {optimizer, score} ->
        run_dir =
          Path.join([
            artifact_dir,
            "experiment_runs",
            "seed_0",
            "#{family}_#{program}_#{optimizer}_#{model}",
            "evaluation_results"
          ])

        File.mkdir_p!(run_dir)

        File.write!(
          Path.join(run_dir, "evaluation_result.txt"),
          """
          score,cost,input_tokens,output_tokens
          #{score},0.25,1000,200
          """
        )
      end)
    end)
  end

  defp converter_dsex_rows(model, campaign_id) do
    Enum.map(full_rows(), fn row ->
      row
      |> Map.put("model", model)
      |> Map.put("campaign_id", campaign_id)
      |> update_in(["optimizer_budgets"], &Map.take(&1, ["dsex_gepa"]))
      |> update_in(["metric_call_evidence", "observed"], &Map.take(&1, ["dsex_gepa"]))
      |> update_in(
        ["metric_call_evidence", "enforced_limits"],
        &Map.take(&1, ["dsex_gepa"])
      )
      |> update_in(["seed_selection"], &Map.take(&1, ["dsex_gepa"]))
      |> update_in(["results"], &Map.take(&1, ["dsex_gepa", "simba"]))
    end)
  end

  defp write_upstream_evidence!(artifact_dir, model, transform \\ &Function.identity/1) do
    runs =
      Enum.flat_map(full_rows(), fn row ->
        family = row["family"]
        program = row["program"]
        limit = row["metric_calls"]

        [
          {"Baseline", 0.5},
          {"GEPA", 0.6},
          {"MIPROv2-Heavy", 0.55}
        ]
        |> Enum.map(fn {optimizer, score} ->
          result_path =
            Path.join([
              artifact_dir,
              "experiment_runs",
              "seed_0",
              "#{family}_#{program}_#{optimizer}_#{model}",
              "evaluation_results",
              "evaluation_result.txt"
            ])

          %{
            "family" => family,
            "program" => program,
            "optimizer" => optimizer,
            "model" => model,
            "seed" => 0,
            "metric_call_evidence" => %{
              "basis" => "observed_metric_callback_count",
              "observed" => limit - 1,
              "configured_limit" => limit,
              "enforced" => true,
              "source" => "fixture runtime metric callback log and enforced limit record"
            },
            "seed_selection" => seed_selection("predeclared", nil, 0),
            "evaluation" => %{
              "split" => "test",
              "score" => score,
              "result_sha256" => sha256(result_path),
              "test_scores_used_for_selection" => false,
              "source" => "fixture final evaluator test-set manifest"
            }
          }
        end)
      end)

    evidence =
      transform.(%{
        "schema_version" => 1,
        "kind" => "gepa_upstream_evidence",
        "source" => %{
          "archive_sha256" => String.duplicate("a", 64),
          "upstream_commit" => "gepa-ai/gepa-artifact@abcdef1"
        },
        "runs" => runs
      })

    path = Path.join(tmp_dir("upstream-evidence"), "evidence.json")
    File.write!(path, Jason.encode!(evidence, pretty: true))
    path
  end

  defp run_upstream_conversion!(artifact_dir, evidence_path) do
    args = [
      "--from-gepa-artifact",
      artifact_dir,
      "--dsex-input",
      write_rows!(
        "dsex-gepa-adversarial",
        converter_dsex_rows("gpt-41-mini", "gepa-adversarial-test")
      ),
      "--campaign-id",
      "gepa-adversarial-test",
      "--artifact-model",
      "gpt-41-mini",
      "--out",
      tmp_dir("gepa-adversarial-output")
    ]

    args = if evidence_path, do: args ++ ["--upstream-evidence", evidence_path], else: args

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_replication")
      GepaReplicationTask.run(args)
    end)
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp full_row(family, program, budget) do
    row = %{
      "family" => family,
      "program" => program,
      "campaign_id" => "gepa-replication-test-campaign",
      "model" => "openai/gpt-4.1-mini-2025-04-14",
      "reflection_model" => "openai/gpt-5-2026-01-01",
      "evidence_level" => "research_campaign",
      "metric_calls" => budget,
      "optimizer_budgets" => %{
        "baseline" => 1,
        "dspy_gepa" => budget,
        "dsex_gepa" => budget,
        "mipro_v2" => budget
      },
      "metric_call_evidence" => %{
        "basis" => "observed_and_enforced",
        "source" => "runtime metric callback counters and optimizer limit checks",
        "observed" => %{
          "baseline" => 1,
          "dspy_gepa" => budget - 3,
          "dsex_gepa" => budget - 2,
          "mipro_v2" => budget - 1
        },
        "enforced_limits" => %{
          "baseline" => true,
          "dspy_gepa" => true,
          "dsex_gepa" => true,
          "mipro_v2" => true
        }
      },
      "dataset" => %{
        "source" => "github.com/gepa-ai/gepa-artifact@abcdef1",
        "split" => "train_dev_test",
        "scope" => "full",
        "max_per_split" => nil,
        "split_counts" => %{
          "train" => 100,
          "dev" => 50,
          "test" => 50
        },
        "checksums" => %{
          "train" => "sha256:#{family}:train",
          "dev" => "sha256:#{family}:dev",
          "test" => "sha256:#{family}:test"
        }
      },
      "source_commits" => %{
        "dspy" => "stanfordnlp/dspy@abcdef1",
        "dsex" => "deepfates/dsex@abcdef2",
        "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
      },
      "token_cost" => %{
        "usd" => 1.25,
        "input_tokens" => 10_000,
        "output_tokens" => 2_000,
        "pricing_source" => "openai pricing table 2026-07-09"
      },
      "wall_clock_ms" => 12_345,
      "seed_variance" => %{"seeds" => [0, 1, 2], "stddev" => 0.01},
      "seed_selection" => %{
        "baseline" => seed_selection("predeclared", nil, 0),
        "dspy_gepa" => seed_selection("best_dev", "dev", 1),
        "dsex_gepa" => seed_selection("best_dev", "dev", 1),
        "mipro_v2" => seed_selection("best_dev", "dev", 1)
      },
      "train_dev_test_gap" => %{
        "train" => 0.8,
        "dev" => 0.75,
        "test" => 0.73,
        "split_digests" => %{
          "train" => "sha256:#{family}:train",
          "dev" => "sha256:#{family}:dev",
          "test" => "sha256:#{family}:test"
        }
      },
      "results" => %{
        "baseline" => %{"score" => 0.5, "source" => "DSEx baseline runner artifact"},
        "dspy_gepa" => %{"score" => 0.6, "source" => "DSPy GEPA runner artifact"},
        "dsex_gepa" => %{"score" => 0.61, "source" => "DSEx GEPA runner artifact"},
        "mipro_v2" => %{"score" => 0.55, "source" => "DSPy MIPROv2 runner artifact"},
        "simba" => %{"score" => 0.56, "source" => "optional SIMBA comparator artifact"}
      }
    }

    row =
      if family in ["HotpotQABench", "hoverBench"] do
        put_in(row, ["dataset", "retrieval"], %{
          "verified" => true,
          "implementation" => "upstream_python_bm25s",
          "corpus_checksum" => "sha256:" <> String.duplicate("1", 64),
          "index_checksum" => "sha256:" <> String.duplicate("2", 64)
        })
      else
        row
      end

    if family == "Papillon" do
      Map.put(row, "metric_judge", %{
        "kind" => "papillon_quality_leakage",
        "model" => "openai/gpt-4.1-mini-2025-04-14",
        "quality_judge" =>
          "DSEx ChainOfThought JudgeQuality source-faithful pairwise order check",
        "leakage_judge" =>
          "DSEx ChainOfThought JudgeLeakage source-faithful pii leaked-count check",
        "score_formula" => "(quality + (1 - leakage)) / 2.0"
      })
    else
      row
    end
  end

  defp seed_selection(method, split, selected_seed) do
    %{
      "method" => method,
      "selection_split" => split,
      "selected_seed" => selected_seed,
      "seeds" => [0, 1, 2],
      "test_scores_used" => false,
      "source" => "campaign seed manifest and dev-only selection trace"
    }
  end
end

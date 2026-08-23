defmodule OptimizeAnythingArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Imp.BenchmarkTruth.OptimizeAnything.Artifact
  alias Mix.Tasks.Imp.Benchmark.OptimizeAnything, as: OptimizeAnythingTask

  test "complete live rows authorize Optimize Anything effectiveness evidence" do
    validation = Artifact.validate_rows(full_rows())

    assert validation.passing
    assert validation.authorizes_effectiveness
    assert Artifact.full_artifact?(Artifact.build(full_rows(), mode: :full))
  end

  test "the immutable pre-v2 campaign remains T2 evidence but cannot authorize effectiveness" do
    path =
      "benchmarks/evidence/archive/optimize_anything/58ff84ac7a0d95bec2238a367ea998347a036565f8284fd71be39a6bd7d4f631.json"

    artifact = path |> File.read!() |> Jason.decode!()

    refute Artifact.full_artifact?(artifact)
    assert Artifact.validate_legacy_rows(artifact["rows"], mode: :full).passing

    refute Artifact.validate_legacy_rows(artifact["rows"], mode: :full).authorizes_effectiveness

    assert :ok =
             Imp.BenchmarkTruth.ReproductionArtifactValidator.validate!(
               "optimize_anything",
               artifact
             )
  end

  test "missing classes and required fields are rejected" do
    [row | _] = full_rows()
    validation = Artifact.validate_rows([Map.delete(row, "provider")])

    refute validation.passing
    refute validation.authorizes_effectiveness
    assert "agent_config" in validation.missing_classes
    assert "scheduling_heuristic" in validation.missing_classes

    assert %{"index" => 0, "field" => "provider", "reason" => "is required"} in validation.invalid_rows
  end

  test "forged smoke and full evidence are rejected" do
    smoke_claim =
      full_rows()
      |> Enum.map(&Map.merge(&1, %{"status" => "smoke", "effectiveness_authorized" => true}))

    refute Artifact.validate_rows(smoke_claim, mode: :smoke).passing

    forged = update_in(full_rows(), [Access.at(0), "provenance", "run_id"], &"forged-#{&1}")
    refute Artifact.validate_rows(forged).passing
  end

  test "non-finite shapes, invalid counters, and inconsistent lifts are rejected" do
    [first, second, third] = full_rows()

    rows = [
      put_in(first, ["baseline", "score"], "NaN"),
      Map.put(second, "metric_calls", -1),
      Map.put(third, "relative_lift", 99.0)
    ]

    validation = Artifact.validate_rows(rows)

    refute validation.passing
    assert Enum.any?(validation.invalid_rows, &(&1["field"] == "baseline"))
    assert Enum.any?(validation.invalid_rows, &(&1["field"] == "metric_calls"))
    assert Enum.any?(validation.invalid_rows, &(&1["field"] == "lift"))
  end

  test "full evidence rejects aggregate regressions and non-improving repeated runs" do
    [first, second, third] = full_rows()

    regression =
      first
      |> put_in(["optimized", "score"], 0.4)
      |> Map.put("absolute_lift", -0.1)
      |> Map.put("relative_lift", -0.2)

    non_improving_run =
      second
      |> update_in(
        ["reproducibility", "runs", Access.at(1)],
        &Map.merge(&1, %{"test_score" => 0.25, "test_lift" => -0.25})
      )
      |> update_in(
        ["reproducibility", "runs", Access.at(2)],
        &Map.merge(&1, %{"test_score" => 0.25, "test_lift" => -0.25})
      )

    duplicate_seed =
      update_in(third, ["reproducibility", "runs", Access.at(1)], fn run ->
        Map.put(run, "seed", third["reproducibility"]["runs"] |> hd() |> Map.fetch!("seed"))
      end)

    validation = Artifact.validate_rows([regression, non_improving_run, duplicate_seed])

    refute validation.passing
    assert Enum.any?(validation.invalid_rows, &(&1["field"] == "effectiveness_lift"))
    assert Enum.count(validation.invalid_rows, &(&1["field"] == "reproducibility")) == 2
  end

  test "full evidence rejects provider rows without positive token and cost observations" do
    [first, second, third] = full_rows()

    rows = [
      Map.put(first, "input_tokens", 0),
      Map.put(second, "output_tokens", 0),
      Map.put(third, "cost_usd", 0.0)
    ]

    validation = Artifact.validate_rows(rows)

    refute validation.passing
    assert Enum.any?(validation.invalid_rows, &(&1["field"] == "input_tokens"))
    assert Enum.any?(validation.invalid_rows, &(&1["field"] == "output_tokens"))
    assert Enum.any?(validation.invalid_rows, &(&1["field"] == "cost_usd"))
  end

  test "smoke CLI writes atomic non-authorizing evidence for every class" do
    out_dir = tmp_dir("optimize-anything-smoke")

    output =
      capture_io(fn ->
        Mix.Task.reenable("imp.benchmark.optimize_anything")
        OptimizeAnythingTask.run(["--smoke", "--out", out_dir])
      end)

    assert output =~ "Optimize Anything replication artifact:"
    [path] = Path.wildcard(Path.join(out_dir, "optimize-anything-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    refute artifact["summary"]["effectiveness_authorized"]
    refute Artifact.full_artifact?(artifact)

    assert Enum.sort(Enum.map(artifact["rows"], & &1["artifact_class"])) ==
             Enum.sort(Artifact.artifact_classes())

    refute File.exists?(path <> ".tmp")
  end

  test "input CLI validates full rows and writes timestamped evidence" do
    out_dir = tmp_dir("optimize-anything-full")
    input = Path.join(tmp_dir("optimize-anything-input"), "rows.json")
    File.write!(input, Jason.encode!(full_rows()))

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.optimize_anything")
      OptimizeAnythingTask.run(["--input", input, "--out", out_dir])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "optimize-anything-replication-*.json"))
    assert path |> File.read!() |> Jason.decode!() |> Artifact.full_artifact?()
  end

  defp full_rows do
    Artifact.artifact_classes()
    |> Enum.with_index(11)
    |> Enum.map(fn {artifact_class, seed} -> full_row(artifact_class, seed) end)
  end

  defp full_row(artifact_class, seed) do
    %{
      "artifact_class" => artifact_class,
      "evaluator_id" => "oa/#{artifact_class}/v1",
      "baseline" => %{"artifact" => "baseline #{artifact_class}", "score" => 0.5},
      "optimized" => %{"artifact" => "optimized #{artifact_class}", "score" => 0.75},
      "comparator" => %{"artifact" => "reference #{artifact_class}", "score" => 0.7},
      "selection" => %{
        "baseline_score" => 0.4,
        "optimized_score" => 0.8,
        "comparator_score" => 0.7
      },
      "absolute_lift" => 0.25,
      "relative_lift" => 0.5,
      "metric_calls" => 24,
      "input_tokens" => 1_200,
      "output_tokens" => 300,
      "provider" => "openai",
      "model" => "gpt-production-model",
      "cost_usd" => 0.42,
      "wall_time_ms" => 12_500,
      "seed" => seed,
      "train_count" => 32,
      "val_count" => 16,
      "test_count" => 16,
      "train_digest" => digest("#{artifact_class}:train"),
      "val_digest" => digest("#{artifact_class}:val"),
      "test_digest" => digest("#{artifact_class}:test"),
      "provenance" => %{
        "run_id" => "campaign-20260713-#{artifact_class}",
        "checkpoint" => "checkpoints/#{artifact_class}/iteration-4.json",
        "git_sha" => String.duplicate("a", 40)
      },
      "status" => "live",
      "effectiveness_authorized" => true,
      "reproducibility" => %{
        "command" => "mix oa.campaign --class #{artifact_class} --seed #{seed}",
        "evaluator_version" => "v1.0.0",
        "dataset_source" => "fixtures/optimize_anything/#{artifact_class}.jsonl",
        "environment" => "Elixir 1.19 / OTP 28",
        "source_commits" => %{
          "imp" => String.duplicate("a", 40),
          "gepa" => String.duplicate("b", 40)
        },
        "runs" => [
          reproducible_run(artifact_class, seed),
          reproducible_run(artifact_class, seed + 100),
          reproducible_run(artifact_class, seed + 200)
        ]
      }
    }
  end

  defp reproducible_run(artifact_class, seed) do
    %{
      "seed" => seed,
      "baseline_selection_score" => 0.4,
      "selection_score" => 0.8,
      "selection_lift" => 0.4,
      "baseline_test_score" => 0.5,
      "test_score" => 0.75,
      "test_lift" => 0.25,
      "artifact_digest" => digest("#{artifact_class}:optimized:#{seed}"),
      "run_id" => "campaign-20260713-#{artifact_class}-#{seed}",
      "checkpoint" => "checkpoints/#{artifact_class}/seed-#{seed}.json"
    }
  end

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

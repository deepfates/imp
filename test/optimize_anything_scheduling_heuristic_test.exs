defmodule DSEx.OptimizeAnythingSchedulingHeuristicTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.OptimizeAnything.SchedulingHeuristic, as: Benchmark

  test "publishes the generalization benchmark contract and a measurable baseline" do
    assert Benchmark.id() == "optimize_anything_scheduling_heuristic_v1"
    assert Benchmark.artifact_class() == "scheduling_heuristic"
    assert length(Benchmark.trainset()) == 3
    assert length(Benchmark.valset()) == 2

    {score, side_info} = Benchmark.evaluate(Benchmark.baseline(), hd(Benchmark.trainset()))

    assert score > 0.0 and score <= 1.0
    assert side_info["status"] == "ok"
    assert side_info["score"] == score
    assert map_size(side_info["objective_subscores"]) == 4
    assert length(side_info["schedule"]) == 5
    assert side_info["dispatch_order"] == Enum.map(side_info["schedule"], & &1["job_id"])
  end

  test "capability-aware comparator lifts both train and held-out validation aggregates" do
    assert average_score(Benchmark.comparator(), Benchmark.trainset()) >
             average_score(Benchmark.baseline(), Benchmark.trainset())

    assert average_score(Benchmark.comparator(), Benchmark.valset()) >
             average_score(Benchmark.baseline(), Benchmark.valset())
  end

  test "malformed and pathological candidate artifacts fail closed" do
    example = hd(Benchmark.trainset())

    for candidate <- [
          "not json",
          Jason.encode!(%{"version" => 1}),
          Jason.encode!(%{
            "version" => 1,
            "priority" => %{
              "processing" => -1,
              "due_date" => 0,
              "importance" => 0
            },
            "assignment" => "least_loaded"
          }),
          Jason.encode!(%{
            "version" => 1,
            "priority" => %{
              "processing" => 0,
              "due_date" => 0,
              "importance" => 0
            },
            "assignment" => "run_elixir",
            "code" => "System.cmd(\"sh\", [\"-c\", \"exit 1\"] )"
          }),
          String.duplicate("x", 4_097)
        ] do
      assert {score, %{"status" => "invalid", "error" => error}} =
               Benchmark.evaluate(candidate, example)

      assert score == 0.0
      assert is_binary(error)
    end
  end

  test "evaluation is deterministic down to diagnostics and assignments" do
    example = Enum.at(Benchmark.trainset(), 1)
    first = Benchmark.evaluate(Benchmark.comparator(), example)

    assert first == Benchmark.evaluate(Benchmark.comparator(), example)
    assert first == Benchmark.evaluate(Benchmark.comparator(), example)
  end

  test "held-out capability bottleneck reserves the specialist for constrained jobs" do
    example = Enum.find(Benchmark.valset(), &(&1["id"] == "val-capability-bottleneck"))
    {baseline_score, _baseline_info} = Benchmark.evaluate(Benchmark.baseline(), example)
    {score, side_info} = Benchmark.evaluate(Benchmark.comparator(), example)

    assert score > baseline_score
    assert side_info["instance_id"] == "val-capability-bottleneck"

    general_long = Enum.find(side_info["schedule"], &(&1["job_id"] == "general-long"))
    special_hot = Enum.find(side_info["schedule"], &(&1["job_id"] == "special-hot"))

    refute general_long["resource_id"] == "specialist"
    assert special_hot["resource_id"] == "specialist"
  end

  defp average_score(candidate, examples) do
    examples
    |> Enum.map(fn example -> candidate |> Benchmark.evaluate(example) |> elem(0) end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end
end

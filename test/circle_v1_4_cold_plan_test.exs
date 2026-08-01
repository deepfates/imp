defmodule Imp.BenchmarkTruth.OptimizeAnything.CircleV14ColdPlanTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.OptimizeAnything.CircleV14ColdPlan

  test "separates exercised refiner/cache behavior from the still-open full planner" do
    plan = CircleV14ColdPlan.design()

    assert plan.released_config.semantic_max_metric_calls == 150
    assert plan.released_config.timeout_seconds == 600
    assert plan.released_config.parallel
    assert plan.exercised_probe.semantic_max_metric_calls == 1
    assert plan.exercised_probe.timeout_seconds == 30
    refute plan.exercised_probe.parallel
    assert plan.exercised_probe.status == :readiness_only

    assert plan.exercised_opportunity.imp == %{
             logical_metric_calls: 1,
             exact_evaluator_executions: 2,
             refiner_lm_calls: 1
           }

    assert plan.exercised_opportunity.upstream == %{
             logical_metric_calls: 1,
             exact_evaluator_executions: 1,
             refiner_lm_calls: 1
           }

    assert plan.state =~ "cold"
    assert plan.accounting_note =~ "no five-seed ceiling"
  end

  @tag :evidence_infrastructure
  test "exact cold Imp and upstream entries execute refiner ordering without providers" do
    without_provider_keys(fn ->
      imp = CircleV14ColdPlan.imp_probe!()
      upstream = CircleV14ColdPlan.upstream_probe!()

      assert imp.evaluator_calls == 2
      assert imp.result.total_metric_calls == 1
      assert imp.result.validation_scores == [0.9797642169962063]
      assert length(imp.evaluator_trace) == 2

      assert Enum.map(imp.evaluator_trace, & &1.input_sha256) == [
               sha256("null"),
               hd(imp.evaluator_trace).output_sha256
             ]

      assert Imp.Optimizer.Artifact.value(imp.artifact)["code"] |> sha256() ==
               CircleV14ColdPlan.design().seed_code_sha256

      assert upstream["evaluator_calls"] == 1
      assert upstream["lm_calls"] == 1
      assert upstream["total_metric_calls"] == 1
      assert upstream["current_best_input_sha256s"] == [sha256("null")]
      assert upstream["best_score"] == 0.9797642169962063
      assert upstream["best_code_sha256"] == CircleV14ColdPlan.design().seed_code_sha256
      assert upstream["best_has_refiner_prompt"]
    end)
  end

  @tag :evidence_infrastructure
  test "schema-3 value artifact executes the pinned evaluator in a fresh trusted OS" do
    without_provider_keys(fn ->
      root = temporary_path("fresh")
      artifact_path = Path.join(root, "circle.json")
      receipt_path = Path.join(root, "receipt.json")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      probe = CircleV14ColdPlan.imp_probe!()
      :ok = Imp.Optimizer.Artifact.write!(probe.artifact, artifact_path)

      code = """
      artifact = Imp.Optimizer.Artifact.read!(#{inspect(artifact_path)})
      candidate = Imp.Optimizer.Artifact.value(artifact)
      result = Imp.BenchmarkTruth.OptimizeAnything.CircleV14ColdPlan.exact_evaluate!(candidate)
      File.write!(#{inspect(receipt_path)}, Jason.encode!(Map.take(result, ["success", "score", "code_sha256"])))
      """

      assert {"", 0} =
               System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
                 env: [
                   {"MIX_ENV", "test"},
                   {"OPENAI_API_KEY", ""},
                   {"OPENROUTER_API_KEY", ""},
                   {"ANTHROPIC_API_KEY", ""}
                 ],
                 stderr_to_stdout: true
               )

      receipt = receipt_path |> File.read!() |> Jason.decode!()

      assert receipt == %{
               "success" => true,
               "score" => 0.9797642169962063,
               "code_sha256" => CircleV14ColdPlan.design().seed_code_sha256
             }
    end)
  end

  defp without_provider_keys(fun) do
    names = ~w(OPENAI_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY)
    prior = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(prior, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp temporary_path(name) do
    Path.join(System.tmp_dir!(), "imp-circle-v14-#{System.unique_integer([:positive])}-#{name}")
  end
end

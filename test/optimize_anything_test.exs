defmodule OptimizeAnythingTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}

  test "runs the canonical Config and Result surface" do
    result =
      Anything.run("baseline", fn _candidate -> 1.0 end,
        config: Config.new(engine: [max_candidate_proposals: 0]),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          Map.fetch!(candidate, component)
        end
      )

    assert %Result{} = result
    assert Result.best_candidate(result) == "baseline"
    assert Anything.best_candidate(result) == "baseline"
  end

  test "does not export the removed Artifact and Report compatibility functions" do
    refute function_exported?(Anything, :new_artifact, 2)
    refute function_exported?(Anything, :new_artifact, 3)
    refute function_exported?(Anything, :optimize, 2)
    refute function_exported?(Anything, :optimize, 3)
    refute function_exported?(Anything, :save_report!, 2)
    refute function_exported?(Anything, :load_report!, 1)
    refute Code.ensure_loaded?(Imp.Optimize.Anything.Report)
    refute Code.ensure_loaded?(Imp.Optimize.Anything.Candidate)
  end

  test "exports the validation-selected OA value for fresh-process execution" do
    root = Path.join(System.tmp_dir!(), "imp-oa-artifact-#{System.unique_integer([:positive])}")
    artifact_path = Path.join(root, "selected.json")
    receipt_path = Path.join(root, "receipt.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    seed = %{"enabled" => false, "max_attempts" => 1}
    target = %{"enabled" => true, "max_attempts" => 3}
    evaluator = fn candidate, _row -> if candidate == target, do: 1.0, else: 0.0 end

    result =
      Anything.run(seed, evaluator,
        dataset: [%{"id" => "train"}],
        valset: [%{"id" => "selection"}],
        config:
          Config.new(
            engine: [max_candidate_proposals: 1, seed: 17],
            reflection: [module_selector: :all]
          ),
        fallback_proposer: fn _candidate, component, _records, _iteration ->
          Map.fetch!(target, component)
        end
      )

    artifact = Anything.to_artifact(result, provenance: %{"task" => "retry-policy"})
    assert Imp.Optimizer.Artifact.value(artifact) == target

    assert %{
             schema_version: 3,
             champion_id: "candidate-0001",
             provenance: %{"task" => "retry-policy"},
             candidates: [
               %{"id" => "candidate-0000", "kind" => "value", "score" => baseline_score},
               %{
                 "id" => "candidate-0001",
                 "kind" => "value",
                 "score" => selected_score,
                 "report" => selected_report,
                 "metadata" => %{"candidate_index" => 1}
               }
             ]
           } = Imp.Optimizer.Artifact.inspect(artifact)

    assert baseline_score == 0.0
    assert selected_score == 1.0
    assert is_map(selected_report)

    :ok = Imp.Optimizer.Artifact.write!(artifact, artifact_path)

    code = """
    value = #{inspect(artifact_path)} |> Imp.Optimizer.Artifact.read!() |> Imp.Optimizer.Artifact.value()
    outcome = if value["enabled"] and value["max_attempts"] >= 3, do: "retry", else: "drop"
    File.write!(#{inspect(receipt_path)}, Jason.encode!(%{value: value, outcome: outcome}))
    """

    assert {"", 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
               cd: File.cwd!(),
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert %{"outcome" => "retry", "value" => ^target} =
             receipt_path |> File.read!() |> Jason.decode!()
  end
end

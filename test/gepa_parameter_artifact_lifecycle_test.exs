defmodule Imp.GEPAParameterArtifactLifecycleTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{Artifact, GEPA}
  alias Imp.TestSupport.TwoStageOptimizerProgram

  setup do
    root =
      Path.join(System.tmp_dir!(), "imp-gepa-artifact-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "ordinary multi-predictor GEPA result persists and executes in a fresh OS process", %{
    root: root
  } do
    selected_classifier = "Use the selected classifier instruction."
    selected_analyzer = "Extract the decisive payment evidence."
    program = TwoStageOptimizerProgram.new(runtime_lm("parent-runtime", selected_classifier))
    example = example()

    metric = fn received, prediction ->
      if Imp.get(received, :route) == Imp.get(prediction, :route), do: 1.0, else: 0.0
    end

    proposer = fn _candidate, _reflective_dataset, components ->
      instructions = %{
        analyze_intent: selected_analyzer,
        classify_route: selected_classifier
      }

      %{new_texts: Map.take(instructions, components)}
    end

    {selected, report, artifact} =
      GEPA.new(metric,
        generations: 1,
        module_selector: :all,
        reflection_strategy: proposer
      )
      |> GEPA.compile_with_artifact(program, [example], [example],
        artifact_id: "banking77-router-v1",
        provenance: %{dataset: "synthetic-lifecycle"}
      )

    assert report.best_score == 1.0

    assert GEPA.Candidate.from_program(selected) == %{
             analyze_intent: selected_analyzer,
             classify_route: selected_classifier
           }

    assert {:ok, prediction} = Imp.call(selected, %{utterance: Imp.get(example, :utterance)})
    assert Imp.get(prediction, :route) == "R42"

    assert %{
             champion_id: "banking77-router-v1",
             candidates: [%{"score" => 1.0}],
             provenance: provenance
           } = Artifact.inspect(artifact)

    assert provenance["dataset"] == "synthetic-lifecycle"
    assert provenance["optimizer"] == "gepa"

    artifact_path = Path.join(root, "selected-parameters.json")
    receipt_path = Path.join(root, "fresh-receipt.json")
    :ok = Artifact.write!(artifact, artifact_path)

    encoded = File.read!(artifact_path)
    refute encoded =~ "parent-runtime"
    refute encoded =~ inspect(TwoStageOptimizerProgram)

    code = """
    alias Imp.Optimizer.Artifact
    alias Imp.TestSupport.TwoStageOptimizerProgram

    selected_classifier = #{inspect(selected_classifier)}
    lm = Imp.LM.Static.new(
      runtime_marker: "fresh-child-runtime",
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\\n", & &1.content)
        if String.contains?(rendered, "`route`"),
          do: %{route: if(String.contains?(rendered, selected_classifier), do: "R42", else: "R17")},
          else: %{evidence: "card payment was not recognized"}
      end
    )

    fresh = TwoStageOptimizerProgram.new(lm)
    applied = #{inspect(artifact_path)} |> Artifact.read!() |> Artifact.apply(fresh)
    {:ok, prediction} = Imp.call(applied, %{utterance: "I do not recognize this card payment"})

    payload = %{
      route: Imp.get(prediction, :route),
      instructions: Enum.map(Imp.ProgramParameters.predictors(applied), & &1.predictor.signature.instructions),
      runtime_preserved: Enum.all?(Imp.ProgramParameters.predictors(applied), &(&1.predictor.lm === lm))
    }

    File.write!(#{inspect(receipt_path)}, Jason.encode!(payload))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output == ""

    assert %{
             "instructions" => [^selected_analyzer, ^selected_classifier],
             "route" => "R42",
             "runtime_preserved" => true
           } = Jason.decode!(File.read!(receipt_path))
  end

  test "artifact options reject unsupported or empty identities before evaluation" do
    owner = self()

    metric = fn _example, _prediction ->
      send(owner, :metric_called)
      1.0
    end

    optimizer = GEPA.new(metric, generations: 0)
    program = TwoStageOptimizerProgram.new(runtime_lm("runtime", "unused"))

    assert_raise ArgumentError, ~r/artifact_id.*non-empty string/, fn ->
      GEPA.compile_with_artifact(optimizer, program, [example()], [example()], artifact_id: "")
    end

    assert_raise ArgumentError, ~r/unknown options.*unknown/, fn ->
      GEPA.compile_with_artifact(optimizer, program, [example()], [example()], unknown: true)
    end

    refute_received :metric_called
  end

  defp example do
    Imp.example(
      utterance: "I do not recognize this card payment",
      route: "R42"
    )
    |> Imp.with_inputs(:utterance)
  end

  defp runtime_lm(marker, selected_classifier) do
    Imp.LM.Static.new(
      runtime_marker: marker,
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\n", & &1.content)

        if String.contains?(rendered, "`route`") do
          route = if String.contains?(rendered, selected_classifier), do: "R42", else: "R17"
          %{route: route}
        else
          %{evidence: "card payment was not recognized"}
        end
      end
    )
  end
end

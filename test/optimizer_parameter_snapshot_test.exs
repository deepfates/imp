defmodule Imp.OptimizerParameterSnapshotTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.Artifact
  alias Imp.TestSupport.TwoStageOptimizerProgram

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-optimizer-parameter-snapshot-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "custom program parameters round-trip and retain fresh runtime bindings", %{root: root} do
    original_lm = static_lm("original-runtime")
    selected = selected_program(original_lm)

    artifact =
      "gepa-selected"
      |> Artifact.parameter_candidate(selected, score: 0.75)
      |> Artifact.new([], provenance: %{optimizer: "gepa"})

    path = Path.join(root, "selected.json")
    receipt = Path.join(root, "fresh.json")
    :ok = Artifact.write!(artifact, path)

    encoded = File.read!(path)
    refute encoded =~ "original-runtime"
    refute encoded =~ inspect(TwoStageOptimizerProgram)

    fresh_lm = static_lm("fresh-runtime")
    applied = path |> Artifact.read!() |> Artifact.apply(TwoStageOptimizerProgram.new(fresh_lm))

    assert instructions(applied) == selected_instructions()

    assert Enum.all?(Imp.ProgramParameters.predictors(applied), fn %{predictor: predictor} ->
             predictor.lm === fresh_lm and predictor.adapter == Imp.Adapter.Chat
           end)

    expected_instructions = selected_instructions()

    code = """
    alias Imp.Optimizer.Artifact
    alias Imp.TestSupport.TwoStageOptimizerProgram
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts ->
        call = Process.get(:two_stage_call, 0)
        Process.put(:two_stage_call, call + 1)
        if rem(call, 2) == 1, do: %{route: "R42"}, else: %{evidence: "card payment not recognized"}
      end, runtime_marker: "fresh-child-runtime"]
    }
    live = TwoStageOptimizerProgram.new(lm)
    applied = #{inspect(path)} |> Artifact.read!() |> Artifact.apply(live)
    {:ok, prediction} = Imp.call(applied, %{utterance: "I do not recognize this card payment"})
    payload = %{
      instructions: Enum.map(Imp.ProgramParameters.predictors(applied), & &1.predictor.signature.instructions),
      runtime_preserved: Enum.all?(Imp.ProgramParameters.predictors(applied), &(&1.predictor.lm === lm)),
      route: Imp.Prediction.get(prediction, :route)
    }
    File.write!(#{inspect(receipt)}, Jason.encode!(payload))
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert %{
             "instructions" => ^expected_instructions,
             "route" => "R42",
             "runtime_preserved" => true
           } = Jason.decode!(File.read!(receipt))
  end

  test "snapshot decoder rejects unknown state and entry keys" do
    snapshot =
      TwoStageOptimizerProgram.new(static_lm("runtime"))
      |> Imp.Optimizer.Artifact.ParameterSnapshot.from_program()
      |> Imp.dump()
      |> json_round_trip()

    assert_raise ArgumentError, ~r/unexpected or missing keys/, fn ->
      snapshot |> Map.put("module", "Unsafe.Consumer") |> Imp.load()
    end

    assert_raise ArgumentError, ~r/unexpected or missing keys/, fn ->
      update_in(snapshot["predictors"], fn [first | rest] ->
        [Map.put(first, "consumer_state", %{}) | rest]
      end)
      |> Imp.load()
    end
  end

  defp selected_program(lm) do
    TwoStageOptimizerProgram.new(lm)
    |> Imp.ProgramParameters.put_instruction(:analyze_intent, Enum.at(selected_instructions(), 0))
    |> Imp.ProgramParameters.put_instruction(:classify_route, Enum.at(selected_instructions(), 1))
  end

  defp selected_instructions do
    [
      "Extract evidence about the kind of card-payment event.",
      "Map the evidence to exactly one opaque route code."
    ]
  end

  defp instructions(program) do
    Enum.map(Imp.ProgramParameters.predictors(program), & &1.predictor.signature.instructions)
  end

  defp static_lm(marker) do
    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          call = Process.get(:two_stage_call, 0)
          Process.put(:two_stage_call, call + 1)

          if rem(call, 2) == 1,
            do: %{route: "R42"},
            else: %{evidence: "card payment not recognized"}
        end,
        runtime_marker: marker
      ]
    }
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
end

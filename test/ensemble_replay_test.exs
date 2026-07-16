defmodule EnsembleReplayTest do
  use ExUnit.Case, async: true

  defmodule TaggedProgram do
    @behaviour Imp.Module
    defstruct [:id]

    @impl true
    def call(%__MODULE__{id: id}, _inputs), do: {:ok, Imp.Prediction.new(id: id)}
  end

  test "seeded subset selection replays independently of process-global RNG state" do
    programs = Enum.map(1..8, &%TaggedProgram{id: &1})

    ensemble =
      Imp.Optimizer.Ensemble.new(size: 3, seed: 42)
      |> Imp.Optimizer.Ensemble.compile(programs)

    :rand.seed(:exsss, {1, 2, 3})
    first = selected_ids(ensemble, %{question: "replay me"})

    :rand.seed(:exsss, {900, 901, 902})
    second = selected_ids(ensemble, %{question: "replay me"})

    assert first == second
    assert length(first) == 3

    selections =
      for seed <- 40..45 do
        variant = %{ensemble | ensemble: %{ensemble.ensemble | seed: seed}}
        selected_ids(variant, %{question: "replay me"})
      end

    assert selections |> Enum.uniq() |> length() > 1
  end

  test "seed and replay behavior survive portable artifact round-trip" do
    programs =
      Enum.map(["alpha", "beta", "gamma", "delta"], fn instruction ->
        Imp.predict("question -> answer")
        |> Imp.Optimizer.InstructionSearch.put_instruction(instruction)
      end)

    ensemble =
      Imp.Optimizer.Ensemble.new(size: 2, seed: 77)
      |> Imp.Optimizer.Ensemble.compile(programs)

    dumped = Imp.dump(ensemble)
    assert dumped["seed"] == 77

    loaded = Imp.load(dumped)
    assert loaded.ensemble.seed == 77

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          answer = Enum.find(["alpha", "beta", "gamma", "delta"], &String.contains?(prompt, &1))
          %{answer: answer}
        end
      ]
    }

    original = ensemble |> Imp.with_lm(lm) |> selected_answers(%{question: "persisted replay"})
    restored = loaded |> Imp.with_lm(lm) |> selected_answers(%{question: "persisted replay"})

    assert original == restored
    assert length(original) == 2
  end

  test "legacy ensemble state without a seed loads with the compatible default" do
    state =
      Imp.Optimizer.Ensemble.new(size: 1)
      |> Imp.Optimizer.Ensemble.compile([Imp.predict("question -> answer")])
      |> Imp.dump()
      |> Map.delete("seed")

    assert Imp.load(state).ensemble.seed == 0
  end

  defp selected_ids(ensemble, inputs) do
    {:ok, prediction} = Imp.call(ensemble, inputs)

    assert prediction.metadata.ensemble_selection == %{
             mode: :seeded,
             seed: ensemble.ensemble.seed
           }

    prediction
    |> Imp.get(:outputs)
    |> Enum.map(fn {:ok, child} -> Imp.get(child, :id) end)
  end

  defp selected_answers(ensemble, inputs) do
    {:ok, prediction} = Imp.call(ensemble, inputs)

    prediction
    |> Imp.get(:outputs)
    |> Enum.map(fn {:ok, child} -> Imp.get(child, :answer) end)
  end
end

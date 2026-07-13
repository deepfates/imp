defmodule DSEx.Optimizer.GEPANamedEvaluationTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Adapter, Candidate, Evaluation, Result}
  alias DSEx.Optimizer.Trajectory

  defmodule FakeAdapter do
    defstruct []

    @behaviour Adapter

    def evaluate(_adapter, batch, candidate, opts) do
      outputs = Enum.map(batch, &String.upcase(&1.input))
      scores = Enum.map(batch, &if(&1.expected == String.upcase(&1.input), do: 1.0, else: 0.0))

      trajectories =
        batch
        |> Enum.with_index()
        |> Enum.map(fn {example, index} ->
          %Trajectory{
            index: index,
            example: example,
            prediction: Enum.at(outputs, index),
            score: Enum.at(scores, index),
            feedback: if(Enum.at(scores, index) == 1.0, do: :correct, else: :revise),
            trace: [
              %{
                predictor: :prepare,
                inputs: %{input: example.input},
                outputs: %{text: example.input}
              },
              %{
                predictor: :answer,
                inputs: %{text: example.input},
                outputs: %{text: Enum.at(outputs, index)}
              }
            ]
          }
        end)

      component_trajectories =
        if Keyword.get(opts, :capture_traces, false) do
          Result.by_component(trajectories, Map.keys(candidate))
        else
          %{}
        end

      Result.new(outputs, scores,
        objective_scores:
          Enum.map(scores, &%{accuracy: &1, brevity: if(&1 == 1.0, do: 0.5, else: 0.25)}),
        trajectories: component_trajectories,
        side_information: %{
          answer: Enum.map(batch, &"Check uppercase answer for #{&1.input}")
        },
        metadata: %{adapter: :deterministic_fake}
      )
    end

    def make_reflective_dataset(_adapter, _candidate, result, components_to_update) do
      Map.new(components_to_update, fn component ->
        records =
          result.side_information
          |> Map.get(component, [])
          |> Enum.map(&%{"Feedback" => &1})

        {component, records}
      end)
    end
  end

  defmodule TwoStage do
    defstruct [:prepare, :answer]

    def optimizer_predictors(program),
      do: [prepare: program.prepare, answer: program.answer]

    def update_optimizer_predictor(program, :prepare, update),
      do: %{program | prepare: update.(program.prepare)}

    def update_optimizer_predictor(program, :answer, update),
      do: %{program | answer: update.(program.answer)}
  end

  test "evaluates named components with aligned scores, trajectories, and side information" do
    candidate = %{prepare: "Normalize input.", answer: "Return uppercase text."}

    batch = [
      %{input: "alpha", expected: "ALPHA"},
      %{input: "beta", expected: "wrong"}
    ]

    result = Evaluation.evaluate(%FakeAdapter{}, batch, candidate, capture_traces: true)

    assert result.outputs == ["ALPHA", "BETA"]
    assert result.scores == [1.0, 0.0]
    assert result.aggregate_score == 0.5

    assert result.objective_scores == [
             %{accuracy: 1.0, brevity: 0.5},
             %{accuracy: 0.0, brevity: 0.25}
           ]

    assert Enum.map(result.trajectories.answer, & &1.index) == [0, 1]
    assert Enum.map(result.trajectories.prepare, & &1.index) == [0, 1]

    assert result.side_information.answer == [
             "Check uppercase answer for alpha",
             "Check uppercase answer for beta"
           ]

    assert Adapter.make_reflective_dataset(%FakeAdapter{}, candidate, result, [:answer]) == %{
             answer: [
               %{"Feedback" => "Check uppercase answer for alpha"},
               %{"Feedback" => "Check uppercase answer for beta"}
             ]
           }
  end

  test "bridges complete candidate maps through ProgramParameters" do
    program = %TwoStage{
      prepare: DSEx.predict("input -> normalized"),
      answer: DSEx.predict("normalized -> answer")
    }

    candidate = %{prepare: "Trim whitespace.", answer: "Use uppercase."}
    updated = Candidate.apply_to_program(program, candidate)

    assert Candidate.from_program(updated) == candidate
  end

  test "rejects adapter results that lose batch alignment" do
    result = Result.new([:only_one], [1.0])

    assert_raise ArgumentError, ~r/outputs must contain 2 entries/, fn ->
      Result.validate!(result, 2, %{main: "text"}, false)
    end
  end

  test "requires every named trajectory when capture is requested" do
    trajectory = %Trajectory{index: 0, example: :example, score: 1.0, trace: []}
    result = Result.new([:ok], [1.0], trajectories: %{first: [trajectory]})

    assert_raise ArgumentError, ~r/must cover every candidate component/, fn ->
      Result.validate!(result, 1, %{first: "one", second: "two"}, true)
    end
  end
end

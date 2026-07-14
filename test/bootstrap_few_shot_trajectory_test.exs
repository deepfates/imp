defmodule Imp.Optimizer.BootstrapFewShotTrajectoryTest do
  use ExUnit.Case, async: true

  defmodule TracedProgram do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    def call(_program, %{question: question}) do
      trace = [
        %{predictor: :first, inputs: %{question: question}, outputs: %{hint: "initial"}},
        %{
          predictor: :first,
          inputs: %{question: question <> " refined"},
          outputs: %{hint: "final"}
        },
        %{predictor: :second, inputs: %{hint: "final"}, outputs: %{answer: "generated"}}
      ]

      {:ok, Imp.Prediction.new(%{answer: "generated"}, metadata: %{optimizer_trace: trace})}
    end
  end

  test "uses generated outputs rather than labeled outputs as demos" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "generated"} end]}
    program = Imp.predict("question -> answer", lm: lm)
    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)
    metric = fn _example, prediction -> Imp.get(prediction, :answer) == "generated" end

    compiled =
      metric
      |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])

    assert [%Imp.Example{} = demo] = compiled.demos
    assert Imp.Example.to_map(demo) == %{question: "q", answer: "generated"}
  end

  test "uses the final traced invocation for each named predictor" do
    program = %TracedProgram{
      first: Imp.predict("question -> hint"),
      second: Imp.predict("hint -> answer")
    }

    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)

    metric = fn _example, prediction, trace ->
      Imp.get(prediction, :answer) == "generated" and length(trace) == 3
    end

    compiled =
      metric
      |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])

    assert [first_demo] = compiled.first.demos
    assert Imp.Example.to_map(first_demo) == %{question: "q refined", hint: "final"}

    assert [second_demo] = compiled.second.demos
    assert Imp.Example.to_map(second_demo) == %{hint: "final", answer: "generated"}

    report = Imp.Optimizer.Report.fetch(compiled.first)
    assert report.metadata.predictor_demo_counts == %{first: 1, second: 1}
  end
end

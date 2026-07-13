defmodule DSEx.Optimizer.BootstrapFewShotTrajectoryTest do
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

      {:ok, DSEx.Prediction.new(%{answer: "generated"}, metadata: %{optimizer_trace: trace})}
    end
  end

  test "uses generated outputs rather than labeled outputs as demos" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _, _ -> %{answer: "generated"} end]}
    program = DSEx.predict("question -> answer", lm: lm)
    example = DSEx.example(question: "q", answer: "gold") |> DSEx.with_inputs(:question)
    metric = fn _example, prediction -> DSEx.get(prediction, :answer) == "generated" end

    compiled =
      metric
      |> DSEx.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> DSEx.Optimizer.BootstrapFewShot.compile(program, [example])

    assert [%DSEx.Example{} = demo] = compiled.demos
    assert DSEx.Example.to_map(demo) == %{question: "q", answer: "generated"}
  end

  test "uses the final traced invocation for each named predictor" do
    program = %TracedProgram{
      first: DSEx.predict("question -> hint"),
      second: DSEx.predict("hint -> answer")
    }

    example = DSEx.example(question: "q", answer: "gold") |> DSEx.with_inputs(:question)

    metric = fn _example, prediction, trace ->
      DSEx.get(prediction, :answer) == "generated" and length(trace) == 3
    end

    compiled =
      metric
      |> DSEx.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> DSEx.Optimizer.BootstrapFewShot.compile(program, [example])

    assert [first_demo] = compiled.first.demos
    assert DSEx.Example.to_map(first_demo) == %{question: "q refined", hint: "final"}

    assert [second_demo] = compiled.second.demos
    assert DSEx.Example.to_map(second_demo) == %{hint: "final", answer: "generated"}

    report = DSEx.Optimizer.Report.fetch(compiled.first)
    assert report.metadata.predictor_demo_counts == %{first: 1, second: 1}
  end
end

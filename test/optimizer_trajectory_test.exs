defmodule Imp.Optimizer.TrajectoryTest do
  use ExUnit.Case, async: true

  defmodule TwoStage do
    defstruct [:first, :second, fail_after_first: false]

    def optimizer_predictors(program), do: [hint: program.first, answer: program.second]

    def update_optimizer_predictor(program, :hint, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :answer, update),
      do: %{program | second: update.(program.second)}

    def call(program, inputs) do
      with {:ok, hint} <- Imp.Predict.Predict.call(program.first, inputs) do
        if program.fail_after_first do
          {:error, :forced_second_stage_failure}
        else
          Imp.Predict.Predict.call(program.second, %{
            question: Map.fetch!(inputs, :question),
            hint: Imp.get(hint, :hint)
          })
        end
      end
    end
  end

  defmodule GuardLM do
    defstruct [:error]

    def generate(%__MODULE__{error: error}, _messages, _opts), do: {:error, error}
  end

  test "captures ordered named predictor calls" do
    program = program(false)
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)

    [trajectory] =
      Imp.Optimizer.TrajectoryRunner.run(
        program,
        [example],
        Imp.Metrics.exact_match(:answer)
      )

    assert trajectory.score == 1.0
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint, :answer]
    assert hd(trajectory.trace).outputs == %{hint: "capital clue"}
    assert List.last(trajectory.trace).inputs.hint == "capital clue"
  end

  test "retains partial module traces when a later stage fails" do
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)

    [trajectory] =
      Imp.Optimizer.TrajectoryRunner.run(
        program(true),
        [example],
        Imp.Metrics.exact_match(:answer)
      )

    assert trajectory.error == :forced_second_stage_failure
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint]
  end

  test "does not invoke the metric after a program-call failure" do
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)
    parent = self()

    metric = fn _example, nil, trace ->
      send(parent, {:metric_called_after_failure, trace})

      Imp.Prediction.new(%{
        score: 0.25,
        diagnosis: "recoverable",
        trace_size: length(trace)
      })
    end

    [trajectory] = Imp.Optimizer.TrajectoryRunner.run(program(true), [example], metric)

    assert trajectory.error == :forced_second_stage_failure
    assert trajectory.score == 0.0
    assert trajectory.feedback == nil
    assert trajectory.metric_metadata == %{}
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint]
    refute_received {:metric_called_after_failure, _trace}
  end

  test "distinguishes a metric failure after a successful program call" do
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)
    metric = fn _example, _prediction -> raise "metric exploded" end

    [trajectory] = Imp.Optimizer.TrajectoryRunner.run(program(false), [example], metric)

    assert %Imp.Prediction{} = trajectory.prediction
    assert trajectory.error == {:metric_error, "metric exploded"}
    assert trajectory.score == 0.0
    assert trajectory.feedback == {:metric_error, "metric exploded"}
    assert trajectory.metric_metadata == %{imp_metric_error: "metric exploded"}
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint, :answer]
  end

  test "operational program and metric guards escape trajectory capture" do
    safety =
      Imp.OperationalSafetyError.exception(
        kind: :route,
        reason: :provider_drift,
        message: "trajectory route guard"
      )

    guarded = %TwoStage{program(false) | fail_after_first: false}

    guarded_program =
      %{guarded | second: %{guarded.second | lm: %GuardLM{error: safety}}}

    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)

    assert_raise Imp.OperationalSafetyError, "trajectory route guard", fn ->
      Imp.Optimizer.TrajectoryRunner.run(
        guarded_program,
        [example],
        Imp.Metrics.exact_match(:answer)
      )
    end

    assert_raise Imp.OperationalSafetyError, "trajectory route guard", fn ->
      Imp.Optimizer.TrajectoryRunner.run(program(false), [example], fn _, _ -> raise safety end)
    end
  end

  test "timeout-killed rows warn loudly and are marked killed, not model misses" do
    slow_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Process.sleep(200)
          %{answer: "Paris"}
        end
      )

    program = Imp.predict("question -> answer", lm: slow_lm)
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)
    metric = fn _example, _prediction -> 1.0 end

    {trajectories, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Imp.Optimizer.TrajectoryRunner.run(program, [example], metric, timeout: 20)
      end)

    [trajectory] = trajectories
    assert trajectory.score == 0.0
    assert Imp.Optimizer.Trajectory.killed?(trajectory)
    assert log =~ "killed row 0"
    assert log =~ "not a model miss"
    assert log =~ "1 of 1 rows were killed"
  end

  test "successful rows are not marked killed and emit no kill warning" do
    program = program(false)
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)
    metric = fn _example, _prediction -> 1.0 end

    {trajectories, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Imp.Optimizer.TrajectoryRunner.run(program, [example], metric, timeout: 5_000)
      end)

    [trajectory] = trajectories
    refute Imp.Optimizer.Trajectory.killed?(trajectory)
    refute log =~ "killed"
  end

  defp program(fail_after_first) do
    hint_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{hint: "capital clue"} end]
    }

    answer_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    %TwoStage{
      first: Imp.predict("question -> hint", lm: hint_lm),
      second: Imp.predict("question, hint -> answer", lm: answer_lm),
      fail_after_first: fail_after_first
    }
  end
end

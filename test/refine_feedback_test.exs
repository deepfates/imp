defmodule RefineFeedbackTest do
  use ExUnit.Case

  defmodule HintProgram do
    defstruct []

    def call(%__MODULE__{}, inputs) do
      answer = if Map.get(Map.new(inputs), :hint_), do: "fixed", else: "bad"
      {:ok, DSEx.Prediction.new(%{answer: answer})}
    end
  end

  defmodule ExplodingProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: raise("program should not be called")
  end

  defmodule ErrorProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: {:error, :provider_unavailable}
  end

  defmodule InvalidResultProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: :not_a_module_result
  end

  defmodule SequenceProgram do
    defstruct [:agent]

    def call(%__MODULE__{agent: agent}, _inputs) do
      answer = Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
      {:ok, DSEx.Prediction.new(%{answer: answer})}
    end
  end

  test "Refine injects feedback hints from prior attempts" do
    metric = fn _example, prediction -> DSEx.Prediction.get(prediction, :answer) == "fixed" end
    feedback = fn history -> "repair after #{length(history)} miss" end

    assert {:ok, prediction} =
             DSEx.Predict.Refine.new(%HintProgram{}, metric,
               max_attempts: 2,
               feedback_fn: feedback
             )
             |> DSEx.Predict.Refine.call(%{question: "q"})

    assert DSEx.Prediction.get(prediction, :answer) == "fixed"
    assert [%{attempt: 1}, %{attempt: 2}] = DSEx.Prediction.get(prediction, :refine_history)
  end

  test "Refine with zero attempts does not call the wrapped program" do
    metric = fn _example, _prediction -> true end

    assert {:error, :no_attempts, []} =
             DSEx.Predict.Refine.new(%ExplodingProgram{}, metric, max_attempts: 0)
             |> DSEx.Predict.Refine.call(%{question: "q"})
  end

  test "Refine preserves wrapped program errors with history context" do
    metric = fn _example, _prediction -> true end

    assert {:error, :provider_unavailable, []} =
             DSEx.Predict.Refine.new(%ErrorProgram{}, metric, max_attempts: 1)
             |> DSEx.Predict.Refine.call(%{question: "q"})
  end

  test "Refine converts invalid program returns into contract errors" do
    metric = fn _example, _prediction -> true end

    assert {:error,
            {:invalid_module_result, RefineFeedbackTest.InvalidResultProgram,
             ":not_a_module_result"}, []} =
             DSEx.Predict.Refine.new(%InvalidResultProgram{}, metric, max_attempts: 1)
             |> DSEx.Predict.Refine.call(%{question: "q"})
  end

  test "Refine treats metric callback failures as failed attempts" do
    metric = fn _example, _prediction -> raise "metric exploded" end

    assert {:ok, prediction} =
             DSEx.Predict.Refine.new(%HintProgram{}, metric, max_attempts: 1)
             |> DSEx.Predict.Refine.call(%{question: "q"})

    assert DSEx.Prediction.get(prediction, :answer) == "bad"
  end

  test "Refine converts feedback callback failures into repair hints" do
    metric = fn _example, prediction -> DSEx.Prediction.get(prediction, :answer) == "fixed" end
    feedback = fn _history -> throw(:bad_feedback) end

    assert {:ok, prediction} =
             DSEx.Predict.Refine.new(%HintProgram{}, metric,
               max_attempts: 2,
               feedback_fn: feedback
             )
             |> DSEx.Predict.Refine.call(%{question: "q"})

    assert DSEx.Prediction.get(prediction, :answer) == "fixed"
  end

  test "Refine retains the best-scoring candidate after exhausting attempts" do
    {:ok, agent} = Agent.start_link(fn -> [0.8, 0.2, 0.5] end)
    metric = fn _example, prediction -> DSEx.Prediction.get(prediction, :answer) end

    assert {:ok, prediction} =
             DSEx.Predict.Refine.new(%SequenceProgram{agent: agent}, metric,
               max_attempts: 3,
               threshold: 1.0
             )
             |> DSEx.Predict.Refine.call(%{})

    assert DSEx.Prediction.get(prediction, :answer) == 0.8
    assert length(DSEx.Prediction.get(prediction, :refine_history)) == 3
  end

  test "Refine uses inclusive threshold semantics" do
    {:ok, agent} = Agent.start_link(fn -> [0.5, 0.9] end)
    metric = fn _example, prediction -> DSEx.Prediction.get(prediction, :answer) end

    assert {:ok, prediction} =
             DSEx.Predict.Refine.new(%SequenceProgram{agent: agent}, metric,
               max_attempts: 2,
               threshold: 0.5
             )
             |> DSEx.Predict.Refine.call(%{})

    assert DSEx.Prediction.get(prediction, :answer) == 0.5
    assert [_first] = DSEx.Prediction.get(prediction, :refine_history)
  end

  test "BestOfN attaches comparison feedback to selected prediction" do
    program = %HintProgram{}

    metric = fn _example, prediction ->
      if DSEx.Prediction.get(prediction, :answer) == "bad", do: 0.0, else: 1.0
    end

    feedback = fn predictions -> "compared #{length(predictions)} attempts" end

    assert {:ok, prediction} =
             DSEx.Predict.BestOfN.new(program, metric, n: 2, feedback_fn: feedback)
             |> DSEx.Predict.BestOfN.call(%{})

    assert DSEx.Prediction.get(prediction, :feedback) == "compared 2 attempts"
  end

  test "BestOfN gives each attempt a distinct rollout identity at temperature 1.0" do
    parent = self()

    lm = fn _messages, opts ->
      send(parent, {:attempt_options, opts})
      {:ok, %{answer: Integer.to_string(opts[:rollout_id])}}
    end

    program =
      DSEx.Predict.Predict.new("question -> answer",
        lm: lm,
        config: [rollout_id: 7, temperature: 0.2]
      )

    metric = fn _example, prediction ->
      prediction |> DSEx.Prediction.get(:answer) |> String.to_integer()
    end

    assert {:ok, prediction} =
             DSEx.Predict.BestOfN.new(program, metric, n: 3, threshold: 8)
             |> DSEx.Predict.BestOfN.call(%{question: "q"})

    assert DSEx.Prediction.get(prediction, :answer) == "8"
    assert_receive {:attempt_options, first}
    assert_receive {:attempt_options, second}
    assert first[:rollout_id] == 7
    assert second[:rollout_id] == 8
    assert first[:temperature] == 1.0
    assert second[:temperature] == 1.0
    refute_receive {:attempt_options, _third}
  end

  test "BestOfN treats metric callback failures as zero-score attempts" do
    metric = fn _example, _prediction -> throw(:bad_metric) end

    assert {:ok, prediction} =
             DSEx.Predict.BestOfN.new(%HintProgram{}, metric, n: 1)
             |> DSEx.Predict.BestOfN.call(%{})

    assert DSEx.Prediction.get(prediction, :answer) == "bad"
  end

  test "BestOfN converts feedback callback failures into prediction feedback" do
    metric = fn _example, _prediction -> 1.0 end
    feedback = fn _predictions -> raise "feedback exploded" end

    assert {:ok, prediction} =
             DSEx.Predict.BestOfN.new(%HintProgram{}, metric, n: 1, feedback_fn: feedback)
             |> DSEx.Predict.BestOfN.call(%{})

    assert DSEx.Prediction.get(prediction, :feedback) ==
             {:feedback_error, "feedback exploded"}
  end

  test "BestOfN with zero attempts does not call the wrapped program" do
    metric = fn _example, _prediction -> true end

    assert {:error, :no_successful_predictions} =
             DSEx.Predict.BestOfN.new(%ExplodingProgram{}, metric, n: 0)
             |> DSEx.Predict.BestOfN.call(%{question: "q"})
  end

  test "BestOfN reports wrapped program failures when every attempt fails" do
    metric = fn _example, _prediction -> true end

    assert {:error,
            {:no_successful_predictions,
             [
               %{attempt: 1, error: :provider_unavailable},
               %{attempt: 2, error: :provider_unavailable}
             ]}} =
             DSEx.Predict.BestOfN.new(%ErrorProgram{}, metric, n: 2)
             |> DSEx.Predict.BestOfN.call(%{question: "q"})

    assert {:error,
            {:no_successful_predictions,
             [
               %{
                 attempt: 1,
                 error:
                   {:invalid_module_result, RefineFeedbackTest.InvalidResultProgram,
                    ":not_a_module_result"}
               }
             ]}} =
             DSEx.Predict.BestOfN.new(%InvalidResultProgram{}, metric, n: 1)
             |> DSEx.Predict.BestOfN.call(%{question: "q"})
  end

  test "BestOfN reports invalid constructor inputs clearly" do
    metric = fn _example, _prediction -> true end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.BestOfN\.new\/3: expected keyword options/,
                 fn ->
                   DSEx.Predict.BestOfN.new(%HintProgram{}, metric, :not_options)
                 end

    assert_raise ArgumentError, ~r/BestOfN\.new\/3 expects a metric function with arity 2/, fn ->
      DSEx.Predict.BestOfN.new(%HintProgram{}, :not_a_metric)
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.BestOfN\.new\/3: invalid value for :feedback_fn option: expected nil or a unary function/,
                 fn ->
                   DSEx.Predict.BestOfN.new(%HintProgram{}, metric, feedback_fn: :not_a_function)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.BestOfN\.new\/3: invalid value for :n option: expected non negative integer/,
                 fn ->
                   DSEx.Predict.BestOfN.new(%HintProgram{}, metric, n: -1)
                 end
  end

  test "Refine reports invalid constructor inputs clearly" do
    metric = fn _example, _prediction -> true end

    assert_raise ArgumentError, ~r/DSEx\.Predict\.Refine\.new\/3: expected keyword options/, fn ->
      DSEx.Predict.Refine.new(%HintProgram{}, metric, :not_options)
    end

    assert_raise ArgumentError, ~r/Refine\.new\/3 expects a metric function with arity 2/, fn ->
      DSEx.Predict.Refine.new(%HintProgram{}, :not_a_metric)
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Refine\.new\/3: invalid value for :feedback_fn option: expected nil or a unary function/,
                 fn ->
                   DSEx.Predict.Refine.new(%HintProgram{}, metric, feedback_fn: :not_a_function)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Refine\.new\/3: invalid value for :max_attempts option: expected non negative integer/,
                 fn ->
                   DSEx.Predict.Refine.new(%HintProgram{}, metric, max_attempts: -1)
                 end
  end
end

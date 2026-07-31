defmodule RefineFeedbackTest do
  use ExUnit.Case

  defmodule HintProgram do
    defstruct []

    def call(%__MODULE__{}, inputs) do
      answer = if Map.get(Map.new(inputs), :hint_), do: "fixed", else: "bad"
      {:ok, Imp.Prediction.new(%{answer: answer})}
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

  defmodule CountingErrorProgram do
    defstruct [:agent]

    def call(%__MODULE__{agent: agent}, _inputs) do
      Agent.update(agent, &(&1 + 1))
      {:error, :provider_unavailable}
    end
  end

  defmodule ScriptedProgram do
    defstruct [:agent]

    def call(%__MODULE__{agent: agent}, _inputs) do
      event = Agent.get_and_update(agent, fn [event | rest] -> {event, rest} end)

      case event do
        {:error, reason} -> {:error, reason}
        {:ok, answer} -> {:ok, Imp.Prediction.new(%{answer: answer})}
      end
    end
  end

  defmodule MultiPredictorProgram do
    defstruct [:owner, :first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    def call(%__MODULE__{owner: owner}, inputs) do
      hint = Map.get(Map.new(inputs), :hint_)
      send(owner, {:predictor_hints, hint})

      answer =
        if is_map(hint) and Map.get(hint, "first") == "first advice",
          do: "fixed",
          else: "bad"

      {:ok, Imp.Prediction.new(%{answer: answer})}
    end
  end

  defmodule InvalidResultProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: :not_a_module_result
  end

  defmodule SequenceProgram do
    defstruct [:agent]

    def call(%__MODULE__{agent: agent}, _inputs) do
      answer = Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
      {:ok, Imp.Prediction.new(%{answer: answer})}
    end
  end

  test "Refine injects feedback hints from prior attempts" do
    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) == "fixed" end
    feedback = fn history -> "repair after #{length(history)} miss" end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(%HintProgram{}, metric,
               max_attempts: 2,
               feedback_fn: feedback
             )
             |> Imp.Predict.Refine.call(%{question: "q"})

    assert Imp.Prediction.get(prediction, :answer) == "fixed"
    assert [%{attempt: 1}, %{attempt: 2}] = Imp.Prediction.get(prediction, :refine_history)
  end

  test "Refine asks the wrapped LM for redacted advice and propagates it" do
    parent = self()

    lm = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

      if prompt =~ "program_inputs" do
        send(parent, {:feedback_prompt, prompt})

        {:ok,
         %{discussion: "main produced the wrong answer", advice: %{"main" => "repair the answer"}}}
      else
        if prompt =~ "repair the answer" do
          {:ok, %{answer: "fixed"}}
        else
          {:ok, %{answer: "bad"}}
        end
      end
    end

    program = Imp.Predict.Predict.new("question -> answer", lm: lm)
    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) == "fixed" end

    # :api_key is a deliberate extra input (redaction probe); since de-hzcv
    # gap #2 it correctly draws the extra-input warning, captured here.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, prediction} =
                 Imp.Predict.Refine.new(program, metric, max_attempts: 2)
                 |> Imp.Predict.Refine.call(%{question: "q", api_key: "sk-live-secret"})

        send(parent, {:refine_prediction, prediction})
      end)

    assert log =~ "not in signature"
    assert_received {:refine_prediction, prediction}

    assert Imp.Prediction.get(prediction, :answer) == "fixed"
    assert_receive {:feedback_prompt, prompt}

    for field <- [
          "program_code",
          "modules_defn",
          "module_names",
          "program_inputs",
          "program_trajectory",
          "program_outputs",
          "reward_code",
          "target_threshold",
          "reward_value",
          "metric_contract"
        ] do
      assert prompt =~ field
    end

    assert prompt =~ "[REDACTED]"
    refute prompt =~ "sk-live-secret"
  end

  test "Refine counts failures after a success instead of using the attempt index" do
    {:ok, events} = Agent.start_link(fn -> [{:ok, 0.6}, {:error, :temporary}, {:ok, 0.9}] end)
    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(%ScriptedProgram{agent: events}, metric,
               max_attempts: 3,
               fail_count: 1,
               feedback_fn: fn _history -> nil end
             )
             |> Imp.Predict.Refine.call(%{})

    assert Imp.Prediction.get(prediction, :answer) == 0.9
    assert Enum.map(Imp.Prediction.get(prediction, :refine_history), & &1.attempt) == [1, 3]
  end

  test "Refine allows interleaved failures until the actual failure allowance is exceeded" do
    {:ok, events} =
      Agent.start_link(fn -> [{:error, :first}, {:ok, 0.2}, {:error, :second}, {:ok, 0.9}] end)

    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(%ScriptedProgram{agent: events}, metric,
               max_attempts: 4,
               fail_count: 2,
               feedback_fn: fn _history -> nil end
             )
             |> Imp.Predict.Refine.call(%{})

    assert Imp.Prediction.get(prediction, :answer) == 0.9
    assert Enum.map(Imp.Prediction.get(prediction, :refine_history), & &1.attempt) == [2, 4]
  end

  test "Refine maps automatic advice to predictor names with N/A fallback" do
    parent = self()

    lm = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

      if prompt =~ "program_inputs",
        do:
          {:ok,
           %{
             discussion: "first needs repair; second is not to blame",
             advice: %{"first" => "first advice"}
           }},
        else: {:ok, %{answer: "unused"}}
    end

    program = %MultiPredictorProgram{
      owner: parent,
      first: Imp.predict("question -> first", lm: lm),
      second: Imp.predict("question -> second", lm: lm)
    }

    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) == "fixed" end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(program, metric, max_attempts: 2)
             |> Imp.Predict.Refine.call(%{question: "q"})

    assert Imp.Prediction.get(prediction, :answer) == "fixed"
    assert_receive {:predictor_hints, nil}
    assert_receive {:predictor_hints, %{"first" => "first advice", "second" => "N/A"}}
  end

  test "Refine bounds provider failures with fail_count" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    metric = fn _example, _prediction -> true end

    assert {:error, {:refine_fail_count_exceeded, :provider_unavailable}, []} =
             Imp.Predict.Refine.new(%CountingErrorProgram{agent: calls}, metric,
               max_attempts: 3,
               fail_count: 1
             )
             |> Imp.Predict.Refine.call(%{})

    assert Agent.get(calls, & &1) == 2
  end

  test "Refine with zero attempts does not call the wrapped program" do
    metric = fn _example, _prediction -> true end

    assert {:error, :no_attempts, []} =
             Imp.Predict.Refine.new(%ExplodingProgram{}, metric, max_attempts: 0)
             |> Imp.Predict.Refine.call(%{question: "q"})
  end

  test "Refine preserves wrapped program errors with history context" do
    metric = fn _example, _prediction -> true end

    assert {:error, :provider_unavailable, []} =
             Imp.Predict.Refine.new(%ErrorProgram{}, metric, max_attempts: 1)
             |> Imp.Predict.Refine.call(%{question: "q"})
  end

  test "Refine converts invalid program returns into contract errors" do
    metric = fn _example, _prediction -> true end

    assert {:error,
            {:invalid_module_result, RefineFeedbackTest.InvalidResultProgram,
             ":not_a_module_result"}, []} =
             Imp.Predict.Refine.new(%InvalidResultProgram{}, metric, max_attempts: 1)
             |> Imp.Predict.Refine.call(%{question: "q"})
  end

  test "Refine treats metric callback failures as failed attempts" do
    metric = fn _example, _prediction -> raise "metric exploded" end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(%HintProgram{}, metric, max_attempts: 1)
             |> Imp.Predict.Refine.call(%{question: "q"})

    assert Imp.Prediction.get(prediction, :answer) == "bad"
  end

  test "Refine converts feedback callback failures into repair hints" do
    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) == "fixed" end
    feedback = fn _history -> throw(:bad_feedback) end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(%HintProgram{}, metric,
               max_attempts: 2,
               feedback_fn: feedback
             )
             |> Imp.Predict.Refine.call(%{question: "q"})

    assert Imp.Prediction.get(prediction, :answer) == "fixed"
  end

  test "Refine retains the best-scoring candidate after exhausting attempts" do
    {:ok, agent} = Agent.start_link(fn -> [0.8, 0.2, 0.5] end)
    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(%SequenceProgram{agent: agent}, metric,
               max_attempts: 3,
               threshold: 1.0
             )
             |> Imp.Predict.Refine.call(%{})

    assert Imp.Prediction.get(prediction, :answer) == 0.8
    assert length(Imp.Prediction.get(prediction, :refine_history)) == 3
  end

  test "Refine uses inclusive threshold semantics" do
    {:ok, agent} = Agent.start_link(fn -> [0.5, 0.9] end)
    metric = fn _example, prediction -> Imp.Prediction.get(prediction, :answer) end

    assert {:ok, prediction} =
             Imp.Predict.Refine.new(%SequenceProgram{agent: agent}, metric,
               max_attempts: 2,
               threshold: 0.5
             )
             |> Imp.Predict.Refine.call(%{})

    assert Imp.Prediction.get(prediction, :answer) == 0.5
    assert [_first] = Imp.Prediction.get(prediction, :refine_history)
  end

  test "BestOfN attaches comparison feedback to selected prediction" do
    program = %HintProgram{}

    metric = fn _example, prediction ->
      if Imp.Prediction.get(prediction, :answer) == "bad", do: 0.0, else: 1.0
    end

    feedback = fn predictions -> "compared #{length(predictions)} attempts" end

    assert {:ok, prediction} =
             Imp.Predict.BestOfN.new(program, metric, n: 2, feedback_fn: feedback)
             |> Imp.Predict.BestOfN.call(%{})

    assert Imp.Prediction.get(prediction, :feedback) == "compared 2 attempts"
  end

  test "BestOfN gives each attempt a distinct rollout identity at temperature 1.0" do
    parent = self()

    lm = fn _messages, opts ->
      send(parent, {:attempt_options, opts})
      {:ok, %{answer: Integer.to_string(opts[:rollout_id])}}
    end

    program =
      Imp.Predict.Predict.new("question -> answer",
        lm: lm,
        config: [rollout_id: 7, temperature: 0.2]
      )

    metric = fn _example, prediction ->
      prediction |> Imp.Prediction.get(:answer) |> String.to_integer()
    end

    assert {:ok, prediction} =
             Imp.Predict.BestOfN.new(program, metric, n: 3, threshold: 8)
             |> Imp.Predict.BestOfN.call(%{question: "q"})

    assert Imp.Prediction.get(prediction, :answer) == "8"
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
             Imp.Predict.BestOfN.new(%HintProgram{}, metric, n: 1)
             |> Imp.Predict.BestOfN.call(%{})

    assert Imp.Prediction.get(prediction, :answer) == "bad"
  end

  test "BestOfN converts feedback callback failures into prediction feedback" do
    metric = fn _example, _prediction -> 1.0 end
    feedback = fn _predictions -> raise "feedback exploded" end

    assert {:ok, prediction} =
             Imp.Predict.BestOfN.new(%HintProgram{}, metric, n: 1, feedback_fn: feedback)
             |> Imp.Predict.BestOfN.call(%{})

    assert Imp.Prediction.get(prediction, :feedback) ==
             {:feedback_error, "feedback exploded"}
  end

  test "BestOfN feedback preserves typed operational safety" do
    metric = fn _example, _prediction -> 1.0 end
    safety = Imp.OperationalSafetyError.exception(kind: :cost, reason: :feedback_limit)

    assert_raise Imp.OperationalSafetyError, fn ->
      Imp.Predict.BestOfN.new(%HintProgram{}, metric,
        n: 1,
        feedback_fn: fn _predictions -> raise safety end
      )
      |> Imp.Predict.BestOfN.call(%{})
    end
  end

  test "BestOfN and Refine metrics preserve typed operational safety" do
    safety = Imp.OperationalSafetyError.exception(kind: :budget, reason: :metric_limit)
    metric = fn _example, _prediction -> raise safety end

    assert_raise Imp.OperationalSafetyError, fn ->
      Imp.Predict.BestOfN.new(%HintProgram{}, metric, n: 1)
      |> Imp.Predict.BestOfN.call(%{})
    end

    assert_raise Imp.OperationalSafetyError, fn ->
      Imp.Predict.Refine.new(%HintProgram{}, metric, max_attempts: 1)
      |> Imp.Predict.Refine.call(%{})
    end
  end

  test "Refine feedback preserves typed operational safety" do
    safety = Imp.OperationalSafetyError.exception(kind: :transport, reason: :feedback_offline)
    metric = fn _example, _prediction -> 0.0 end

    assert_raise Imp.OperationalSafetyError, fn ->
      Imp.Predict.Refine.new(%HintProgram{}, metric,
        max_attempts: 2,
        feedback_fn: fn _history -> raise safety end
      )
      |> Imp.Predict.Refine.call(%{})
    end
  end

  test "BestOfN with zero attempts does not call the wrapped program" do
    metric = fn _example, _prediction -> true end

    assert {:error, :no_successful_predictions} =
             Imp.Predict.BestOfN.new(%ExplodingProgram{}, metric, n: 0)
             |> Imp.Predict.BestOfN.call(%{question: "q"})
  end

  test "BestOfN reports wrapped program failures when every attempt fails" do
    metric = fn _example, _prediction -> true end

    assert {:error,
            {:no_successful_predictions,
             [
               %{attempt: 1, error: :provider_unavailable},
               %{attempt: 2, error: :provider_unavailable}
             ]}} =
             Imp.Predict.BestOfN.new(%ErrorProgram{}, metric, n: 2)
             |> Imp.Predict.BestOfN.call(%{question: "q"})

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
             Imp.Predict.BestOfN.new(%InvalidResultProgram{}, metric, n: 1)
             |> Imp.Predict.BestOfN.call(%{question: "q"})
  end

  test "BestOfN reports invalid constructor inputs clearly" do
    metric = fn _example, _prediction -> true end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.BestOfN\.new\/3: expected keyword options/,
                 fn ->
                   Imp.Predict.BestOfN.new(%HintProgram{}, metric, :not_options)
                 end

    assert_raise ArgumentError, ~r/BestOfN\.new\/3 expects a metric function with arity 2/, fn ->
      Imp.Predict.BestOfN.new(%HintProgram{}, :not_a_metric)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.BestOfN\.new\/3: invalid value for :feedback_fn option: expected nil or a unary function/,
                 fn ->
                   Imp.Predict.BestOfN.new(%HintProgram{}, metric, feedback_fn: :not_a_function)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.BestOfN\.new\/3: invalid value for :n option: expected non negative integer/,
                 fn ->
                   Imp.Predict.BestOfN.new(%HintProgram{}, metric, n: -1)
                 end
  end

  test "Refine reports invalid constructor inputs clearly" do
    metric = fn _example, _prediction -> true end

    assert_raise ArgumentError, ~r/Imp\.Predict\.Refine\.new\/3: expected keyword options/, fn ->
      Imp.Predict.Refine.new(%HintProgram{}, metric, :not_options)
    end

    assert_raise ArgumentError, ~r/Refine\.new\/3 expects a metric function with arity 2/, fn ->
      Imp.Predict.Refine.new(%HintProgram{}, :not_a_metric)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Refine\.new\/3: invalid value for :feedback_fn option: expected nil or a unary function/,
                 fn ->
                   Imp.Predict.Refine.new(%HintProgram{}, metric, feedback_fn: :not_a_function)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Refine\.new\/3: invalid value for :max_attempts option: expected non negative integer/,
                 fn ->
                   Imp.Predict.Refine.new(%HintProgram{}, metric, max_attempts: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Refine\.new\/3: expected :fail_count option to match at least one given type/,
                 fn ->
                   Imp.Predict.Refine.new(%HintProgram{}, metric, fail_count: -1)
                 end
  end
end

defmodule DSEx.AssertionsTest do
  use ExUnit.Case

  defmodule HintRepairProgram do
    defstruct []

    def call(%__MODULE__{}, inputs) do
      answer =
        if Map.get(Map.new(inputs), :hint_) do
          "Paris"
        else
          "Paris is the capital of France"
        end

      {:ok, DSEx.Prediction.new(%{answer: answer})}
    end
  end

  defmodule AlwaysBadProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs) do
      {:ok, DSEx.Prediction.new(%{answer: "Paris is the capital of France"})}
    end
  end

  test "assertions inject feedback hints and stop once constraints pass" do
    one_word =
      DSEx.assertion(
        :one_word,
        fn prediction ->
          prediction |> DSEx.Prediction.get(:answer, "") |> String.split() |> length() == 1
        end,
        message: "Answer with one word."
      )

    assert {:ok, prediction} =
             %HintRepairProgram{}
             |> DSEx.assert(one_word, max_attempts: 2)
             |> DSEx.call(%{question: "Capital of France?"})

    assert DSEx.get(prediction, :answer) == "Paris"
    assert DSEx.get(prediction, :assertion_score) == 1.0
    assert DSEx.get(prediction, :assertion_failures) == []

    assert [
             %{attempt: 1, failures: [%{name: :one_word}]} = first_attempt,
             %{attempt: 2, score: 1.0, failures: []}
           ] = DSEx.get(prediction, :assertion_history)

    assert first_attempt.score == 0.0
  end

  test "strict assertions return failures instead of best failed prediction" do
    one_word = {:one_word, fn pred -> DSEx.get(pred, :answer, "") == "Paris" end, "Return Paris."}

    assert {:error, {:assertions_failed, [%{name: :one_word}], history}} =
             %AlwaysBadProgram{}
             |> DSEx.assert(one_word, max_attempts: 2, strict: true)
             |> DSEx.call(%{question: "Capital of France?"})

    assert [%{attempt: 1}, %{attempt: 2}] = history
  end

  test "non-strict assertions return the best attempt with failure metadata" do
    one_word = {:one_word, fn pred -> DSEx.get(pred, :answer, "") == "Paris" end, "Return Paris."}

    assert {:ok, prediction} =
             %AlwaysBadProgram{}
             |> DSEx.assert(one_word, max_attempts: 1)
             |> DSEx.call(%{question: "Capital of France?"})

    assert DSEx.get(prediction, :answer) == "Paris is the capital of France"
    assert DSEx.get(prediction, :assertion_score) == 0.0

    assert [%{name: :one_word, message: "Return Paris."}] =
             DSEx.get(prediction, :assertion_failures)
  end

  test "assertions accept metric result feedback and predicate failures are safe" do
    metric_assertion =
      DSEx.assertion(:semantic, fn _inputs, _prediction ->
        %DSEx.Metrics.Result{score: 0.0, passed?: false, feedback: "Use the exact city."}
      end)

    exploding_assertion = DSEx.assertion(:safe, fn _prediction -> raise "bad predicate" end)

    assert {:ok, prediction} =
             %AlwaysBadProgram{}
             |> DSEx.assert([metric_assertion, exploding_assertion], max_attempts: 1)
             |> DSEx.call(%{question: "Capital of France?"})

    assert [
             %{name: :semantic, message: "Use the exact city."},
             %{name: :safe, message: "Assertion failed. bad predicate"}
           ] = DSEx.get(prediction, :assertion_failures)
  end

  test "streaming collect can see output fields through assertion wrapper" do
    one_word = {:one_word, fn pred -> DSEx.get(pred, :answer, "") == "Paris" end, "Return Paris."}

    program =
      DSEx.predict("question -> answer",
        lm: %{
          module: DSEx.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
        }
      )
      |> DSEx.assert(one_word)

    assert DSEx.Streaming.collect(program, %{question: "Capital of France?"}) == "Paris"
  end

  test "constructor validation is explicit" do
    assert_raise ArgumentError, ~r/expects at least one assertion/, fn ->
      DSEx.assert(%AlwaysBadProgram{}, [])
    end

    assert_raise ArgumentError, ~r/predicate must be a unary or binary function/, fn ->
      DSEx.assertion(:bad, :not_a_function)
    end
  end
end

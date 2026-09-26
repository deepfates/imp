defmodule Imp.AssertionsTest do
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

      {:ok, Imp.Prediction.new(%{answer: answer})}
    end
  end

  defmodule AlwaysBadProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs) do
      {:ok, Imp.Prediction.new(%{answer: "Paris is the capital of France"})}
    end
  end

  defmodule FailingProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: {:error, :provider_unavailable}
  end

  test "an assertion wrapper whose every attempt failed returns the last error as an Imp.Module error" do
    passes = {:passes, fn _prediction -> true end, "Pass."}

    assert {:error, :provider_unavailable} =
             %FailingProgram{}
             |> Imp.assert(passes, max_attempts: 2)
             |> Imp.call(%{question: "q"})

    assert {:error, :no_attempts} =
             %FailingProgram{}
             |> Imp.assert(passes, max_attempts: 0)
             |> Imp.call(%{question: "q"})
  end

  test "assertions inject feedback hints and stop once constraints pass" do
    one_word =
      Imp.assertion(
        :one_word,
        fn prediction ->
          prediction |> Imp.Prediction.get(:answer, "") |> String.split() |> length() == 1
        end,
        message: "Answer with one word."
      )

    assert {:ok, prediction} =
             %HintRepairProgram{}
             |> Imp.assert(one_word, max_attempts: 2)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :assertion_score) == 1.0
    assert Imp.get(prediction, :assertion_failures) == []

    assert [
             %{attempt: 1, failures: [%{name: :one_word}]} = first_attempt,
             %{attempt: 2, score: 1.0, failures: []}
           ] = Imp.get(prediction, :assertion_history)

    assert first_attempt.score == 0.0
  end

  test "strict assertions return failures instead of best failed prediction" do
    one_word = {:one_word, fn pred -> Imp.get(pred, :answer, "") == "Paris" end, "Return Paris."}

    assert {:error, {:assertions_failed, [%{name: :one_word}], history}} =
             %AlwaysBadProgram{}
             |> Imp.assert(one_word, max_attempts: 2, strict: true)
             |> Imp.call(%{question: "Capital of France?"})

    assert [%{attempt: 1}, %{attempt: 2}] = history
  end

  test "non-strict assertions return the best attempt with failure metadata" do
    one_word = {:one_word, fn pred -> Imp.get(pred, :answer, "") == "Paris" end, "Return Paris."}

    assert {:ok, prediction} =
             %AlwaysBadProgram{}
             |> Imp.assert(one_word, max_attempts: 1)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris is the capital of France"
    assert Imp.get(prediction, :assertion_score) == 0.0

    assert [%{name: :one_word, message: "Return Paris."}] =
             Imp.get(prediction, :assertion_failures)
  end

  test "assertions accept metric result feedback and predicate failures are safe" do
    metric_assertion =
      Imp.assertion(:semantic, fn _inputs, _prediction ->
        %Imp.Metrics.Result{score: 0.0, passed?: false, feedback: "Use the exact city."}
      end)

    exploding_assertion = Imp.assertion(:safe, fn _prediction -> raise "bad predicate" end)

    assert {:ok, prediction} =
             %AlwaysBadProgram{}
             |> Imp.assert([metric_assertion, exploding_assertion], max_attempts: 1)
             |> Imp.call(%{question: "Capital of France?"})

    assert [
             %{name: :semantic, message: "Use the exact city."},
             %{name: :safe, message: "Assertion failed. bad predicate"}
           ] = Imp.get(prediction, :assertion_failures)
  end

  test "streaming collect can see output fields through assertion wrapper" do
    one_word = {:one_word, fn pred -> Imp.get(pred, :answer, "") == "Paris" end, "Return Paris."}

    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)
      )
      |> Imp.assert(one_word)

    assert Imp.Streaming.collect(program, %{question: "Capital of France?"}) == "Paris"
  end

  test "constructor validation is explicit" do
    assert_raise ArgumentError, ~r/expects at least one assertion/, fn ->
      Imp.assert(%AlwaysBadProgram{}, [])
    end

    assert_raise ArgumentError, ~r/predicate must be a unary or binary function/, fn ->
      Imp.assertion(:bad, :not_a_function)
    end
  end
end

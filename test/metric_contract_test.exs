defmodule MetricContractTest do
  use ExUnit.Case, async: true

  defmodule Program do
    defstruct [:handler]

    def call(%__MODULE__{handler: handler}, inputs), do: handler.(inputs)
  end

  defp example(question, answer) do
    DSEx.example(question: question, answer: answer) |> DSEx.Example.with_inputs(:question)
  end

  test "Evaluate normalizes numeric and feedback-bearing metric returns" do
    program = %Program{handler: fn _inputs -> {:ok, DSEx.prediction(answer: "Paris")} end}

    metric = fn _example, prediction ->
      if DSEx.Prediction.get(prediction, :answer) == "Paris" do
        %{score: 0.75, feedback: "grounded", metadata: %{judge: :local}}
      else
        false
      end
    end

    result =
      DSEx.Evaluate.new([example("capital?", "Paris")], metric) |> DSEx.Evaluate.run(program)

    assert result.score == 0.75

    assert [
             %{
               score: 0.75,
               passed?: true,
               feedback: "grounded",
               metric_metadata: %{judge: :local}
             }
           ] =
             result.rows
  end

  test "Evaluate passes prediction trace to arity-3 metrics" do
    trace = %{messages: [%{role: :user, content: "q"}]}

    program = %Program{
      handler: fn _inputs ->
        %DSEx.Prediction{} = prediction = DSEx.prediction(answer: "ok")
        {:ok, %{prediction | metadata: %{trace: trace}}}
      end
    }

    metric = fn _example, _prediction, received_trace ->
      %{score: 1.0, feedback: {:trace_seen, received_trace == trace}}
    end

    result = DSEx.Evaluate.new([example("q", "ok")], metric) |> DSEx.Evaluate.run(program)

    assert [%{feedback: {:trace_seen, true}}] = result.rows
  end

  test "Evaluate records failures with configurable failure score and max errors" do
    program = %Program{handler: fn _inputs -> {:error, :boom} end}
    metric = fn _example, _prediction -> true end

    result =
      [example("one", "1"), example("two", "2")]
      |> DSEx.Evaluate.new(metric, failure_score: -1.0, max_errors: 0)
      |> DSEx.Evaluate.run(program)

    assert result.score == -1.0
    assert [%{reason: :boom}] = result.errors
    assert length(result.rows) == 1
  end

  test "BestOfN Refine and few-shot optimizers accept structured metric results" do
    good = DSEx.prediction(answer: "good")
    bad = DSEx.prediction(answer: "bad")

    metric = fn _example, prediction ->
      answer = DSEx.Prediction.get(prediction, :answer)
      %{score: if(answer == "good", do: 1.0, else: 0.0), feedback: answer}
    end

    best_program = %Program{
      handler: fn _inputs ->
        prediction =
          case Process.get(:metric_contract_predictions, []) do
            [next | rest] ->
              Process.put(:metric_contract_predictions, rest)
              next

            [] ->
              good
          end

        {:ok, prediction}
      end
    }

    Process.put(:metric_contract_predictions, [bad, good])

    assert {:ok, selected} =
             best_program
             |> DSEx.Predict.BestOfN.new(metric, n: 2)
             |> DSEx.Predict.BestOfN.call(%{})

    assert DSEx.Prediction.get(selected, :answer) == "good"

    refine_program = %Program{handler: fn _inputs -> {:ok, good} end}

    assert {:ok, refined} =
             refine_program
             |> DSEx.Predict.Refine.new(metric, max_attempts: 1)
             |> DSEx.Predict.Refine.call(%{})

    assert DSEx.Prediction.get(refined, :answer) == "good"
  after
    Process.delete(:metric_contract_predictions)
  end
end

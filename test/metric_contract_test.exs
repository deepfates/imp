defmodule MetricContractTest do
  use ExUnit.Case, async: true

  defmodule Program do
    defstruct [:handler]

    def call(%__MODULE__{handler: handler}, inputs), do: handler.(inputs)
  end

  defp example(question, answer) do
    Imp.example(question: question, answer: answer) |> Imp.Example.with_inputs(:question)
  end

  test "Evaluate normalizes numeric and feedback-bearing metric returns" do
    program = %Program{handler: fn _inputs -> {:ok, Imp.prediction(answer: "Paris")} end}

    metric = fn _example, prediction ->
      if Imp.Prediction.get(prediction, :answer) == "Paris" do
        %{score: 0.75, feedback: "grounded", metadata: %{judge: :local}}
      else
        false
      end
    end

    result =
      Imp.Evaluate.new([example("capital?", "Paris")], metric) |> Imp.Evaluate.run(program)

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
        %Imp.Prediction{} = prediction = Imp.prediction(answer: "ok")
        {:ok, %{prediction | metadata: %{trace: trace}}}
      end
    }

    metric = fn _example, _prediction, received_trace ->
      %{score: 1.0, feedback: {:trace_seen, received_trace == trace}}
    end

    result = Imp.Evaluate.new([example("q", "ok")], metric) |> Imp.Evaluate.run(program)

    assert [%{feedback: {:trace_seen, true}}] = result.rows
  end

  # The contract matches DSPy's parallelizer: reaching max_errors raises rather
  # than returning a partial Result.
  test "Evaluate records failures with configurable failure score and cancels loudly at max errors" do
    program = %Program{handler: fn _inputs -> {:error, :boom} end}
    metric = fn _example, _prediction -> true end
    devset = [example("one", "1"), example("two", "2")]

    result =
      devset
      |> Imp.Evaluate.new(metric, failure_score: -1.0)
      |> Imp.Evaluate.run(program)

    assert result.score == -1.0
    assert [%{reason: :boom}, %{reason: :boom}] = result.errors
    assert length(result.rows) == 2

    ExUnit.CaptureLog.capture_log(fn ->
      error =
        assert_raise Imp.EvaluationCancelledError, fn ->
          devset
          |> Imp.Evaluate.new(metric, failure_score: -1.0, max_errors: 1)
          |> Imp.Evaluate.run(program)
        end

      assert [%{reason: :boom}] = error.errors
      assert length(error.rows) == 1
    end)
  end

  test "Evaluate can run rows concurrently while preserving row order and process context" do
    parent = self()

    program = %Program{
      handler: fn inputs ->
        send(parent, {:worker_context, inputs.question, Imp.Settings.fetch!(:tenant)})
        {:ok, Imp.prediction(answer: inputs.question)}
      end
    }

    metric = fn example, prediction ->
      Imp.Example.get(example, :answer) == Imp.Prediction.get(prediction, :answer)
    end

    devset =
      for value <- ["one", "two", "three"] do
        example(value, value)
      end

    result =
      Imp.context([tenant: :eval_test], fn ->
        devset
        |> Imp.Evaluate.new(metric, num_threads: 2)
        |> Imp.Evaluate.run(program)
      end)

    assert result.score == 1.0
    assert Enum.map(result.rows, & &1.index) == [0, 1, 2]

    assert Enum.map(result.rows, &Imp.Prediction.get(&1.prediction, :answer)) == [
             "one",
             "two",
             "three"
           ]

    assert_received {:worker_context, "one", :eval_test}
    assert_received {:worker_context, "two", :eval_test}
    assert_received {:worker_context, "three", :eval_test}
  end

  test "Evaluate constructor reports invalid metrics and options clearly" do
    devset = [example("one", "1")]
    metric = fn _example, _prediction -> true end

    assert_raise ArgumentError,
                 ~r/Imp\.Evaluate\.new\/3 expects devset to be an enumerable/,
                 fn ->
                   Imp.Evaluate.new(:not_an_enumerable_devset, metric)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Evaluate\.new\/3 expects a metric function with arity 2 or 3/,
                 fn ->
                   Imp.Evaluate.new(devset, :not_a_metric)
                 end

    assert_raise ArgumentError, ~r/Imp\.Evaluate\.new\/3: expected keyword options/, fn ->
      Imp.Evaluate.new(devset, metric, :not_options)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Evaluate\.new\/3.*:display_progress.*expected.*boolean/s,
                 fn ->
                   Imp.Evaluate.new(devset, metric, display_progress: :sometimes)
                 end

    assert_raise ArgumentError, ~r/Imp\.Evaluate\.new\/3.*:failure_score/s, fn ->
      Imp.Evaluate.new(devset, metric, failure_score: :zero)
    end

    assert_raise ArgumentError,
                 ~r/:max_errors.*expected :infinity or a non-negative integer/s,
                 fn ->
                   Imp.Evaluate.new(devset, metric, max_errors: -1)
                 end

    assert_raise ArgumentError,
                 ~r/:max_errors.*expected :infinity or a non-negative integer/s,
                 fn ->
                   Imp.Evaluate.new(devset, metric, max_errors: "forever")
                 end

    assert_raise ArgumentError,
                 ~r/:num_threads.*expected.*positive integer/s,
                 fn ->
                   Imp.Evaluate.new(devset, metric, num_threads: 0)
                 end
  end

  test "Evaluate normalizes plain map and field-pair devset rows" do
    program = %Program{
      handler: fn inputs ->
        assert Map.has_key?(inputs, :question)
        {:ok, Imp.prediction(answer: "Paris")}
      end
    }

    metric = fn example, prediction ->
      assert %Imp.Example{} = example
      Imp.Metrics.exact_match(:answer).(example, prediction)
    end

    result =
      [
        %{question: "Capital?", answer: "Paris"},
        [question: "French capital?", answer: "Paris"]
      ]
      |> Imp.Evaluate.new(metric)
      |> Imp.Evaluate.run(program)

    assert result.score == 1.0
    assert Enum.all?(result.rows, &match?(%Imp.Example{}, &1.example))
  end

  test "Evaluate records malformed devset rows as failed diagnostics" do
    program = %Program{handler: fn _inputs -> {:ok, Imp.prediction(answer: "unused")} end}
    metric = fn _example, _prediction -> true end

    result =
      [:not_an_example, %{question: "Capital?", answer: "Paris"}]
      |> Imp.Evaluate.new(metric, max_errors: :infinity)
      |> Imp.Evaluate.run(program)

    assert [
             %{
               index: 0,
               reason: {:invalid_evaluation_example, ":not_an_example"}
             }
           ] = result.errors

    assert [
             %{index: 0, passed?: false, prediction: nil},
             %{index: 1, passed?: true, prediction: %Imp.Prediction{}}
           ] = result.rows
  end

  test "Evaluate records program crashes and invalid returns as failed rows" do
    metric = fn _example, _prediction -> true end

    raising = %Program{handler: fn _inputs -> raise "program exploded" end}

    raised =
      [example("one", "1")]
      |> Imp.Evaluate.new(metric, failure_score: -1.0)
      |> Imp.Evaluate.run(raising)

    assert raised.score == -1.0

    assert [%{reason: {:module_call_failed, Program, %RuntimeError{message: "program exploded"}}}] =
             raised.errors

    assert [
             %{
               error: {:module_call_failed, Program, %RuntimeError{message: "program exploded"}},
               prediction: nil
             }
           ] =
             raised.rows

    invalid = %Program{handler: fn _inputs -> :not_a_module_result end}

    result =
      [example("one", "1")]
      |> Imp.Evaluate.new(metric)
      |> Imp.Evaluate.run(invalid)

    assert [%{reason: {:invalid_module_result, Program, ":not_a_module_result"}}] =
             result.errors
  end

  test "Evaluate records metric throws as metric feedback and budgeted errors" do
    program = %Program{handler: fn _inputs -> {:ok, Imp.prediction(answer: "Paris")} end}
    metric = fn _example, _prediction -> throw(:bad_metric) end

    result =
      [example("capital?", "Paris")]
      |> Imp.Evaluate.new(metric)
      |> Imp.Evaluate.run(program)

    assert result.score == 0.0

    assert [%{index: 0, stage: :metric, reason: "{:throw, :bad_metric}"}] = result.errors

    assert [
             %{
               error: %{index: 0, stage: :metric, reason: "{:throw, :bad_metric}"},
               feedback: {:metric_error, "{:throw, :bad_metric}"},
               passed?: false,
               metric_metadata: %{imp_metric_error: "{:throw, :bad_metric}"}
             }
           ] = result.rows
  end

  # Corrected toward loudness (dee-f1ct / P14): metric failures count toward
  # max_errors, and reaching the budget cancels loudly instead of quietly
  # returning a partial Result.
  test "Evaluate applies max_errors to metric failures" do
    program = %Program{handler: fn _inputs -> {:ok, Imp.prediction(answer: "Paris")} end}
    metric = fn _example, _prediction -> raise "metric exploded" end

    ExUnit.CaptureLog.capture_log(fn ->
      error =
        assert_raise Imp.EvaluationCancelledError, fn ->
          [example("one", "1"), example("two", "2")]
          |> Imp.Evaluate.new(metric, max_errors: 1)
          |> Imp.Evaluate.run(program)
        end

      assert [%{index: 0, stage: :metric, reason: "metric exploded"}] = error.errors
      assert length(error.rows) == 1
    end)
  end

  test "token F1 counts duplicate overlap like extractive QA metrics" do
    assert Imp.Metrics.f1("alpha alpha beta", "alpha beta beta") == 2 / 3
  end

  test "extractive QA reports exact match F1 answer type and span relation" do
    assert %Imp.Metrics.Result{
             score: 1.0,
             passed?: true,
             metadata: %{
               "task_metric" => "hotpotqa_exact_match",
               "exact_match" => true,
               "f1" => 1.0,
               "answer_type" => "numeric",
               "span_relation" => "exact"
             }
           } = Imp.Metrics.extractive_qa("2000", "2000", metric_name: "hotpotqa_exact_match")

    overlong = Imp.Metrics.extractive_qa("since 2000", "2000")

    refute overlong.passed?
    assert overlong.score == 0.0
    assert overlong.metadata["f1"] == 2 / 3
    assert overlong.metadata["answer_type"] == "numeric"
    assert overlong.metadata["span_relation"] == "overlong_span"

    assert Imp.Metrics.answer_type("yes") == "yes_no"
    assert Imp.Metrics.span_relation("Paris", "Paris France") == "short_span"
  end

  test "classification metrics report per-row accuracy and macro micro weighted F1" do
    assert %Imp.Metrics.Result{
             score: 1.0,
             passed?: true,
             metadata: %{
               "task_metric" => "colors_label_accuracy",
               "predicted_label" => "warm",
               "gold_label" => "warm",
               "correct" => true
             }
           } = Imp.Metrics.classification("Warm!", "warm", metric_name: "colors_label_accuracy")

    report =
      Imp.Metrics.classification_report([
        {"warm", "warm"},
        {"warm", "cool"},
        {"cool", "cool"},
        {"cool", "cool"}
      ])

    assert report["accuracy"] == 0.75
    assert_in_delta report["macro_f1"], 0.7333, 0.0001
    assert report["micro_f1"] == 0.75
    assert_in_delta report["weighted_f1"], 0.7333, 0.0001
    assert report["labels"]["warm"]["support"] == 2
    assert report["labels"]["cool"]["support"] == 2
  end

  test "retrieval recall scores expected evidence ids from prediction metadata" do
    prediction =
      Imp.prediction(answer: "Paris")
      |> Map.put(:metadata, %{
        retrieval: %{
          docs: [
            %{"id" => "city-france", "text" => "Paris is the capital city of France."},
            %{id: :city_germany, text: "Berlin is the capital city of Germany."}
          ]
        }
      })

    assert %Imp.Metrics.Result{
             score: 0.5,
             passed?: false,
             metadata: %{
               "expected_evidence_ids" => ["city-france", "missing-doc"],
               "hit_evidence_ids" => ["city-france"],
               "recall" => 0.5
             }
           } = Imp.Metrics.retrieval_recall(prediction, ["city-france", "missing-doc"])

    assert %Imp.Metrics.Result{score: 1.0, passed?: true} =
             Imp.Metrics.retrieval_recall(prediction, ["city-france"], min_recall: 1.0)
  end

  test "built-in metrics reject malformed options and row shapes clearly" do
    assert_raise ArgumentError, ~r/Imp.Metrics.extractive_qa\/3 expects keyword options/, fn ->
      Imp.Metrics.extractive_qa("Paris", "Paris", %{metric_name: "qa"})
    end

    assert_raise ArgumentError,
                 ~r/Imp.Metrics.classification\/3 expects :metric_name to be a string/,
                 fn ->
                   Imp.Metrics.classification("warm", "warm", metric_name: :colors)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Metrics.classification_report\/2 expects rows to be an enumerable/,
                 fn ->
                   Imp.Metrics.classification_report(:not_rows)
                 end

    assert_raise ArgumentError, ~r/rows must be \{gold, predicted\} tuples or maps/, fn ->
      Imp.Metrics.classification_report([:not_a_row])
    end

    assert_raise ArgumentError,
                 ~r/rows must include gold\/label and predicted\/prediction fields/,
                 fn ->
                   Imp.Metrics.classification_report([%{label: "warm"}])
                 end

    assert_raise ArgumentError, ~r/Imp.Metrics.retrieval_recall\/3 expects :min_recall/, fn ->
      Imp.Metrics.retrieval_recall([], ["doc"], min_recall: 1.5)
    end
  end

  test "BestOfN Refine and few-shot optimizers accept structured metric results" do
    good = Imp.prediction(answer: "good")
    bad = Imp.prediction(answer: "bad")

    metric = fn _example, prediction ->
      answer = Imp.Prediction.get(prediction, :answer)
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
             |> Imp.Predict.BestOfN.new(metric, n: 2)
             |> Imp.Predict.BestOfN.call(%{})

    assert Imp.Prediction.get(selected, :answer) == "good"

    refine_program = %Program{handler: fn _inputs -> {:ok, good} end}

    assert {:ok, refined} =
             refine_program
             |> Imp.Predict.Refine.new(metric, n: 1)
             |> Imp.Predict.Refine.call(%{})

    assert Imp.Prediction.get(refined, :answer) == "good"
  after
    Process.delete(:metric_contract_predictions)
  end
end

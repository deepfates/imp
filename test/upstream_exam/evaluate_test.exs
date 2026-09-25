defmodule UpstreamExam.EvaluateTest do
  @moduledoc """
  DSPy 3.2.1's own evaluate tests (tests/evaluate/), ported to Imp.

  Tranche 3 of the upstream exam. Disposition map: research/differentials/UPSTREAM_EXAM.md.
  Seam applied throughout: Imp.Evaluate scores are fractions (1.0), DSPy's are
  percentages (100.0); the assertions translate the scale and nothing else.
  """

  use ExUnit.Case, async: true

  @moduletag :upstream_exam

  alias Imp.Evaluate.{CompleteAndGrounded, SemanticF1}

  defp static_lm(handler), do: %{module: Imp.LM.Static, opts: [handler: handler]}

  defp new_example(question, answer) do
    Imp.example(question: question, answer: answer) |> Imp.with_inputs(:question)
  end

  # Upstream answer_exact_match (dspy/evaluate/metrics.py): pred.answer counts
  # as correct when it matches example.answer, or ANY member when
  # example.answer is a list.
  defp answer_exact_match(example, prediction) do
    answers = example |> Imp.Example.get(:answer) |> List.wrap()
    predicted = Imp.Prediction.get(prediction, :answer)
    Enum.any?(answers, &(normalize(&1) == normalize(predicted)))
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  # A program that answers per-question from a scripted table, standing in for
  # upstream's dict-form DummyLM.
  defp qa_program(table) do
    Imp.predict("question -> answer",
      lm:
        static_lm(fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &to_string(&1.content))

          {_q, answer} = Enum.find(table, fn {question, _} -> prompt =~ question end)
          %{answer: answer}
        end)
    )
  end

  # ---------------------------------------------------------------------------
  # tests/evaluate/test_metrics.py
  # ---------------------------------------------------------------------------

  # test_answer_exact_match_string
  test "metrics: answer_exact_match with a string answer" do
    example = new_example("What is 1+1?", "2")
    pred = Imp.prediction(answer: "2")
    assert answer_exact_match(example, pred)
  end

  # test_answer_exact_match_list
  test "metrics: answer_exact_match with a list of acceptable answers" do
    example = new_example("What is 1+1?", ["2", "two"])
    pred = Imp.prediction(answer: "2")
    assert answer_exact_match(example, pred)
  end

  # test_answer_exact_match_no_match
  test "metrics: answer_exact_match rejects a wrong answer" do
    example = new_example("What is 1+1?", "2")
    pred = Imp.prediction(answer: "3")
    refute answer_exact_match(example, pred)
  end

  # test_answer_exact_match_string / _list / _no_match against the BUILT-IN
  # metric: Imp.Metrics.exact_match/1 now carries upstream answer_exact_match's
  # str-or-list semantics (any-member match on a list answer), closing gap #4.
  test "metrics: built-in exact_match accepts string and list answers" do
    metric = Imp.Metrics.exact_match(:answer)

    assert metric.(new_example("What is 1+1?", "2"), Imp.prediction(answer: "2"))
    assert metric.(new_example("What is 1+1?", ["2", "two"]), Imp.prediction(answer: "2"))
    assert metric.(new_example("What is 1+1?", ["2", "two"]), Imp.prediction(answer: "Two"))
    refute metric.(new_example("What is 1+1?", "2"), Imp.prediction(answer: "3"))
    refute metric.(new_example("What is 1+1?", ["2", "two"]), Imp.prediction(answer: "3"))
  end

  # ---------------------------------------------------------------------------
  # tests/evaluate/test_evaluate.py
  # ---------------------------------------------------------------------------

  # test_evaluate_initialization
  test "evaluate: initialization stores devset and metric" do
    devset = [new_example("What is 1+1?", "2")]
    metric = &answer_exact_match/2
    evaluator = Imp.Evaluate.new(devset, metric)

    assert evaluator.devset == devset
    assert evaluator.metric == metric
  end

  # test_evaluate_call
  test "evaluate: a correct program scores full marks" do
    program = qa_program([{"What is 1+1?", "2"}, {"What is 2+2?", "4"}])

    assert {:ok, first} = Imp.call(program, %{question: "What is 1+1?"})
    assert Imp.Prediction.get(first, :answer) == "2"

    devset = [new_example("What is 1+1?", "2"), new_example("What is 2+2?", "4")]
    evaluator = Imp.Evaluate.new(devset, &answer_exact_match/2)
    result = Imp.Evaluate.run(evaluator, program)

    # DSPy: 100.0 (percentage). Imp: 1.0 (fraction).
    assert result.score == 1.0
  end

  # test_multithread_evaluate_call
  test "evaluate: multithreaded evaluation scores full marks" do
    program = qa_program([{"What is 1+1?", "2"}, {"What is 2+2?", "4"}])
    devset = [new_example("What is 1+1?", "2"), new_example("What is 2+2?", "4")]

    evaluator = Imp.Evaluate.new(devset, &answer_exact_match/2, max_concurrency: 2)
    result = Imp.Evaluate.run(evaluator, program)
    assert result.score == 1.0
  end

  # test_evaluate_call_wrong_answer
  test "evaluate: an always-wrong program scores zero" do
    program = qa_program([{"What is 1+1?", "0"}, {"What is 2+2?", "0"}])
    devset = [new_example("What is 1+1?", "2"), new_example("What is 2+2?", "4")]

    evaluator = Imp.Evaluate.new(devset, &answer_exact_match/2)
    result = Imp.Evaluate.run(evaluator, program)
    assert result.score == 0.0
  end

  # test_evaluate_save_as_json_with_history
  test "evaluate: save_as_json writes rows with serialized history", %{test: test_name} do
    history1 = Imp.History.new([%{question: "Previous Q1", answer: "Previous A1"}])

    history2 =
      Imp.History.new([
        %{question: "Previous Q2", answer: "Previous A2"},
        %{question: "Previous Q3", answer: "Previous A3"}
      ])

    devset = [
      Imp.example(question: "What is 1+1?", answer: "2", history: history1)
      |> Imp.with_inputs(:question),
      Imp.example(question: "What is 2+2?", answer: "4", history: history2)
      |> Imp.with_inputs(:question)
    ]

    program = qa_program([{"What is 1+1?", "2"}, {"What is 2+2?", "4"}])
    evaluator = Imp.Evaluate.new(devset, &answer_exact_match/2)
    result = Imp.Evaluate.run(evaluator, program)

    # DSPy: 100.0 (percentage). Imp: 1.0 (fraction).
    assert result.score == 1.0

    path =
      Path.join(
        System.tmp_dir!(),
        "upstream_exam_#{:erlang.phash2(test_name)}_save.json"
      )

    on_exit(fn -> File.rm(path) end)

    # Seam: upstream passes save_as_json= to the Evaluate constructor; Imp's
    # file surface lives on the result (rows are plain data).
    assert :ok = Imp.Evaluate.Result.save_as_json(result, path)

    data = path |> File.read!() |> Jason.decode!()
    assert length(data) == 2

    [first, second] = data

    assert %{"messages" => [message]} = first["history"]
    assert message == %{"question" => "Previous Q1", "answer" => "Previous A1"}

    assert %{"messages" => [m1, m2]} = second["history"]
    assert m1 == %{"question" => "Previous Q2", "answer" => "Previous A2"}
    assert m2 == %{"question" => "Previous Q3", "answer" => "Previous A3"}

    # Row semantics (upstream merge_dicts): the prediction only carries
    # :answer, so :question stays a bare column while the shared :answer key
    # splits into example_answer / pred_answer.
    assert first["question"] == "What is 1+1?"
    assert first["example_answer"] == "2"
    assert first["pred_answer"] == "2"
    assert first["score"] == 1.0
  end

  # test_evaluate_save_as_csv_with_history
  test "evaluate: save_as_csv writes a header row and stringified history", %{test: test_name} do
    history = Imp.History.new([%{question: "Previous Q", answer: "Previous A"}])

    devset = [
      Imp.example(question: "What is 1+1?", answer: "2", history: history)
      |> Imp.with_inputs(:question)
    ]

    program = qa_program([{"What is 1+1?", "2"}])
    evaluator = Imp.Evaluate.new(devset, &answer_exact_match/2)
    result = Imp.Evaluate.run(evaluator, program)
    assert result.score == 1.0

    path =
      Path.join(
        System.tmp_dir!(),
        "upstream_exam_#{:erlang.phash2(test_name)}_save.csv"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.Evaluate.Result.save_as_csv(result, path)

    [header_line | row_lines] = path |> File.read!() |> String.trim() |> String.split("\r\n")
    header = String.split(header_line, ",")

    assert length(row_lines) == 1
    assert "history" in header

    # CSV carries the string representation of the history dict (upstream
    # asserts `"messages" in rows[0]["history"]`); the cell is JSON-encoded
    # and therefore quoted, so assert on the raw row.
    assert hd(row_lines) =~ "messages"
    assert hd(row_lines) =~ "Previous Q"
  end

  # ---------------------------------------------------------------------------
  # tests/evaluate/test_auto_evaluation.py
  # ---------------------------------------------------------------------------

  # test_semantic_f1_returns_prediction_without_trace
  test "semantic f1: returns a scored prediction without a trace" do
    lm =
      static_lm(fn _messages, _opts ->
        %{reasoning: "Comparing the responses", precision: 1.0, recall: 1.0}
      end)

    example = Imp.example(question: "What is 1+1?", response: "2")
    pred = Imp.prediction(response: "2")

    assert {:ok, result} =
             SemanticF1.new(lm: lm) |> SemanticF1.call(%{example: example, pred: pred})

    assert %Imp.Prediction{} = result
    assert is_number(result.score) or is_boolean(result.score)
  end

  # test_semantic_f1_returns_prediction_with_trace
  test "semantic f1: with a trace the score is threshold truth" do
    lm =
      static_lm(fn _messages, _opts ->
        %{reasoning: "Comparing the responses", precision: 1.0, recall: 1.0}
      end)

    example = Imp.example(question: "What is 1+1?", response: "2")
    pred = Imp.prediction(response: "2")

    assert {:ok, result} =
             SemanticF1.new(lm: lm, threshold: 0.5)
             |> SemanticF1.call(%{example: example, pred: pred, trace: []})

    assert is_boolean(result.score)
  end

  # test_semantic_f1_score_value
  test "semantic f1: score is the harmonic mean of precision and recall" do
    lm =
      static_lm(fn _messages, _opts ->
        %{reasoning: "Comparing the responses", precision: 0.8, recall: 0.6}
      end)

    example = Imp.example(question: "test", response: "answer")
    pred = Imp.prediction(response: "response")

    assert {:ok, result} =
             SemanticF1.new(lm: lm) |> SemanticF1.call(%{example: example, pred: pred})

    expected_f1 = 2 * (0.8 * 0.6) / (0.8 + 0.6)
    assert_in_delta result.score, expected_f1, 0.001
  end

  # test_semantic_f1_prediction_can_be_compared
  test "semantic f1: scores from different judgments are comparable" do
    {:ok, agent} =
      Agent.start_link(fn ->
        [
          %{reasoning: "Comparing first response", precision: 0.8, recall: 0.6},
          %{reasoning: "Comparing second response", precision: 0.9, recall: 0.7}
        ]
      end)

    lm =
      static_lm(fn _messages, _opts ->
        Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      end)

    metric = SemanticF1.new(lm: lm)

    example1 = Imp.example(question: "test1", response: "answer1")
    pred1 = Imp.prediction(response: "response1")
    assert {:ok, result1} = SemanticF1.call(metric, %{example: example1, pred: pred1})

    example2 = Imp.example(question: "test2", response: "answer2")
    pred2 = Imp.prediction(response: "response2")
    assert {:ok, result2} = SemanticF1.call(metric, %{example: example2, pred: pred2})

    assert result2.score > result1.score
  end

  # test_complete_and_grounded_returns_prediction_without_trace
  test "complete and grounded: returns a scored prediction without a trace" do
    {:ok, agent} =
      Agent.start_link(fn ->
        [
          %{
            reasoning: "Analyzing completeness",
            ground_truth_key_ideas: "the answer is 2",
            system_response_key_ideas: "the answer is 2",
            discussion: "both match",
            completeness: 1.0
          },
          %{
            reasoning: "Analyzing groundedness",
            system_response_claims: "1+1=2",
            discussion: "supported by context",
            groundedness: 1.0
          }
        ]
      end)

    lm =
      static_lm(fn _messages, _opts ->
        Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      end)

    example = Imp.example(question: "What is 1+1?", response: "2")
    pred = Imp.prediction(response: "2", context: "context")

    assert {:ok, result} =
             CompleteAndGrounded.new(lm: lm)
             |> CompleteAndGrounded.call(%{example: example, pred: pred})

    assert %Imp.Prediction{} = result
    assert is_number(result.score) or is_boolean(result.score)
  end

  # test_complete_and_grounded_returns_prediction_with_trace
  test "complete and grounded: with a trace the score is threshold truth" do
    {:ok, agent} =
      Agent.start_link(fn ->
        [
          %{
            reasoning: "Analyzing completeness",
            ground_truth_key_ideas: "the answer is 2",
            system_response_key_ideas: "the answer is 2",
            discussion: "both match",
            completeness: 0.9
          },
          %{
            reasoning: "Analyzing groundedness",
            system_response_claims: "1+1=2",
            discussion: "supported by context",
            groundedness: 0.8
          }
        ]
      end)

    lm =
      static_lm(fn _messages, _opts ->
        Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      end)

    example = Imp.example(question: "What is 1+1?", response: "2")
    pred = Imp.prediction(response: "2", context: "context")

    assert {:ok, result} =
             CompleteAndGrounded.new(lm: lm, threshold: 0.7)
             |> CompleteAndGrounded.call(%{example: example, pred: pred, trace: []})

    assert is_boolean(result.score)
  end
end

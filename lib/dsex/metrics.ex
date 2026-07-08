defmodule DSEx.Metrics do
  @moduledoc """
  Metrics for evaluation, selection, and optimization.

  In DSEx, a metric is just an Elixir function that scores a program output
  against an example. Evaluation and optimizers accept a few convenient return
  shapes: booleans, numbers, maps with `:score` and `:feedback`, predictions
  that carry score fields, or `%DSEx.Metrics.Result{}` values. DSEx normalizes
  those shapes before it computes averages, chooses best-of-N candidates, or
  feeds optimizer reports.

  Use the small built-ins for deterministic local tasks and write ordinary
  functions when the task needs domain judgment.

  ## Example

      iex> metric = DSEx.Metrics.exact_match(:answer)
      iex> example = DSEx.example(question: "Capital?", answer: "Paris")
      iex> prediction = DSEx.prediction(answer: "paris")
      iex> metric.(example, prediction)
      true

      iex> result = DSEx.Metrics.normalize_result(%{score: 0.75, feedback: "partial"})
      iex> {result.score, result.passed?, result.feedback}
      {0.75, true, "partial"}
  """

  defmodule Result do
    @moduledoc """
    Normalized metric result with numeric score, pass/fail flag, feedback, and metadata.

    Evaluators and optimizers use this struct internally so metric functions can
    stay ergonomic at call sites.
    """

    defstruct score: 0.0, passed?: false, feedback: nil, metadata: %{}
  end

  @doc """
  Converts a metric return value into `%DSEx.Metrics.Result{}`.

  Accepted values include `%Result{}`, `%DSEx.Prediction{}`, maps, booleans,
  and numbers. Unknown values become a failed result with diagnostic feedback.
  """
  def normalize_result(%Result{} = result), do: result

  def normalize_result(%DSEx.Prediction{} = prediction) do
    score = DSEx.Prediction.get(prediction, :score, prediction.score || 0.0)

    %Result{
      score: numeric_score(score),
      passed?: passed?(score),
      feedback: DSEx.Prediction.get(prediction, :feedback),
      metadata: prediction.metadata
    }
  end

  def normalize_result(%{} = result) do
    score = Map.get(result, :score, Map.get(result, "score", 0.0))

    %Result{
      score: numeric_score(score),
      passed?: Map.get(result, :passed?, Map.get(result, "passed", passed?(score))),
      feedback: Map.get(result, :feedback, Map.get(result, "feedback")),
      metadata: Map.get(result, :metadata, Map.get(result, "metadata", %{}))
    }
  end

  def normalize_result(value) when is_boolean(value),
    do: %Result{score: numeric_score(value), passed?: value}

  def normalize_result(value) when is_number(value),
    do: %Result{score: value * 1.0, passed?: value > 0}

  def normalize_result(value),
    do: %Result{score: 0.0, passed?: false, feedback: {:invalid_metric_result, value}}

  @doc "Returns the normalized numeric score for a metric return value."
  def score(value), do: normalize_result(value).score

  @doc "Returns whether a metric return value passes after normalization."
  def pass?(value), do: normalize_result(value).passed?

  @doc "Returns feedback attached to a normalized metric return value."
  def feedback(value), do: normalize_result(value).feedback

  defp numeric_score(true), do: 1.0
  defp numeric_score(false), do: 0.0
  defp numeric_score(value) when is_number(value), do: value * 1.0
  defp numeric_score(_value), do: 0.0

  defp passed?(value) when is_boolean(value), do: value
  defp passed?(value) when is_number(value), do: value > 0
  defp passed?(_value), do: false

  @doc """
  Normalizes answer text for extractive exact match and F1.

  The normalizer lowercases text, removes punctuation, splits Unicode words, and
  drops English articles. It is intentionally small and deterministic so local
  tests can use it as an oracle.
  """
  def normalize_text(value) do
    text = value |> to_string() |> String.downcase()

    text
    |> normalized_tokens()
    |> Enum.reject(&(&1 in ["a", "an", "the"]))
    |> Enum.join(" ")
  end

  defp normalized_tokens(text) do
    if ascii_word_space?(text) do
      String.split(text)
    else
      text
      |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
      |> String.split()
    end
  end

  defp ascii_word_space?(<<>>), do: true

  defp ascii_word_space?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?0..?9 or char in [?\s, ?\t, ?\n, ?\r],
       do: ascii_word_space?(rest)

  defp ascii_word_space?(_text), do: false

  @doc """
  Returns exact-match truth after `normalize_text/1`.

  When given multiple acceptable answers, any match passes.
  """
  def em(prediction, answers) when is_list(answers),
    do: Enum.any?(answers, &(normalize_text(prediction) == normalize_text(&1)))

  def em(prediction, answer), do: normalize_text(prediction) == normalize_text(answer)

  @doc """
  Computes token F1 after `normalize_text/1`.

  Duplicate token overlap is counted, matching extractive QA metric behavior.
  When given multiple acceptable answers, the best F1 is returned.
  """
  def f1(prediction, answers) when is_list(answers),
    do: answers |> Enum.map(&f1(prediction, &1)) |> Enum.max(fn -> 0.0 end)

  def f1(prediction, answer) do
    pred_tokens = normalize_text(prediction) |> String.split()
    gold_tokens = normalize_text(answer) |> String.split()

    common =
      pred_tokens
      |> Enum.frequencies()
      |> Enum.reduce(0, fn {token, count}, acc ->
        acc + min(count, Enum.count(gold_tokens, &(&1 == token)))
      end)

    cond do
      pred_tokens == [] or gold_tokens == [] ->
        0.0

      common == 0 ->
        0.0

      true ->
        precision = common / length(pred_tokens)
        recall = common / length(gold_tokens)
        2 * precision * recall / (precision + recall)
    end
  end

  @doc """
  Returns a structured extractive-QA metric result.

  The result uses exact match as the pass/fail score and includes F1, answer
  type, and span-relation metadata for dashboards and parity reports.
  """
  def extractive_qa(prediction, answer, opts \\ []) do
    exact_match? = em(prediction, answer)
    f1_score = f1(prediction, answer)
    metric_name = Keyword.get(opts, :metric_name, "extractive_qa_exact_match")

    %Result{
      score: if(exact_match?, do: 1.0, else: 0.0),
      passed?: exact_match?,
      metadata: %{
        "task_metric" => metric_name,
        "exact_match" => exact_match?,
        "f1" => f1_score,
        "answer_type" => answer_type(answer),
        "span_relation" => span_relation(prediction, answer)
      }
    }
  end

  @doc """
  Returns a structured single-row classification result.

  The comparison uses `normalize_text/1` so label capitalization and light
  punctuation differences do not matter. Aggregate classification metrics can
  be computed with `classification_report/2`.
  """
  def classification(prediction, label, opts \\ []) do
    metric_name = Keyword.get(opts, :metric_name, "classification_accuracy")
    predicted = normalize_text(prediction)
    gold = normalize_text(label)
    correct? = predicted == gold and gold != ""

    %Result{
      score: if(correct?, do: 1.0, else: 0.0),
      passed?: correct?,
      metadata: %{
        "task_metric" => metric_name,
        "predicted_label" => predicted,
        "gold_label" => gold,
        "correct" => correct?
      }
    }
  end

  @doc """
  Computes accuracy and macro/micro/weighted F1 for classification rows.

  Rows can be `{gold, predicted}` tuples or maps with `:gold`/`:predicted`
  (or string-keyed equivalents).
  """
  def classification_report(rows, opts \\ []) do
    pairs = Enum.map(rows, &classification_pair/1)

    labels =
      pairs |> Enum.flat_map(fn {gold, pred} -> [gold, pred] end) |> Enum.uniq() |> Enum.sort()

    total = length(pairs)
    correct = Enum.count(pairs, fn {gold, pred} -> gold == pred and gold != "" end)
    by_label = Map.new(labels, &{&1, label_stats(&1, pairs)})
    supports = Map.new(by_label, fn {label, stats} -> {label, stats["support"]} end)

    %{
      "task_metric" => Keyword.get(opts, :metric_name, "classification_report"),
      "examples" => total,
      "accuracy" => if(total == 0, do: 0.0, else: correct / total),
      "macro_f1" => mean_metric(by_label, "f1"),
      "micro_f1" => micro_f1(by_label),
      "weighted_f1" => weighted_metric(by_label, supports, "f1"),
      "labels" => by_label
    }
  end

  @doc """
  Computes recall of expected evidence ids in retrieved documents.

  `prediction` may be a `%DSEx.Prediction{}` with RAG retrieval metadata or a
  list of retrieved document maps. Expected ids can be strings or atoms.
  """
  def retrieval_recall(prediction, expected_ids, opts \\ []) do
    metric_name = Keyword.get(opts, :metric_name, "retrieval_recall")
    expected = expected_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
    retrieved = prediction |> retrieved_ids() |> MapSet.new()
    hits = MapSet.intersection(expected, retrieved)

    recall =
      if MapSet.size(expected) == 0, do: 0.0, else: MapSet.size(hits) / MapSet.size(expected)

    %Result{
      score: recall,
      passed?: recall >= Keyword.get(opts, :min_recall, 1.0),
      metadata: %{
        "task_metric" => metric_name,
        "expected_evidence_ids" => Enum.sort(MapSet.to_list(expected)),
        "retrieved_evidence_ids" => Enum.sort(MapSet.to_list(retrieved)),
        "hit_evidence_ids" => Enum.sort(MapSet.to_list(hits)),
        "recall" => recall
      }
    }
  end

  @doc """
  Classifies a normalized answer as `"yes_no"`, `"numeric"`, `"short_span"`, or `"long_span"`.
  """
  def answer_type(answer) do
    norm = normalize_text(answer)

    cond do
      norm in ["yes", "no"] -> "yes_no"
      String.match?(norm, ~r/^\d+(?:\s+\d+)*$/) -> "numeric"
      String.length(norm) <= 20 -> "short_span"
      true -> "long_span"
    end
  end

  @doc """
  Describes how a predicted span relates to the expected answer span.
  """
  def span_relation(prediction, answer) do
    pred_norm = normalize_text(prediction)
    gold_norm = normalize_text(answer)

    cond do
      pred_norm == "" or gold_norm == "" -> "missing"
      pred_norm == gold_norm -> "exact"
      contains_token_sequence?(pred_norm, gold_norm) -> "overlong_span"
      contains_token_sequence?(gold_norm, pred_norm) -> "short_span"
      true -> "different_or_ambiguous"
    end
  end

  defp classification_pair({gold, predicted}),
    do: {normalize_text(gold), normalize_text(predicted)}

  defp classification_pair(%{} = row) do
    gold = Map.get(row, :gold, Map.get(row, "gold", Map.get(row, :label, Map.get(row, "label"))))

    predicted =
      Map.get(
        row,
        :predicted,
        Map.get(row, "predicted", Map.get(row, :prediction, Map.get(row, "prediction")))
      )

    {normalize_text(gold), normalize_text(predicted)}
  end

  defp retrieved_ids(%DSEx.Prediction{metadata: metadata}) do
    metadata
    |> Map.get(:retrieval, %{})
    |> Map.get(:docs, [])
    |> retrieved_ids()
  end

  defp retrieved_ids(docs) when is_list(docs), do: Enum.map(docs, &doc_id/1)
  defp retrieved_ids(_prediction), do: []

  defp doc_id(%{} = doc), do: doc |> Map.get(:id, Map.get(doc, "id", "")) |> to_string()
  defp doc_id(_doc), do: ""

  defp label_stats(label, pairs) do
    true_positive = Enum.count(pairs, fn {gold, pred} -> gold == label and pred == label end)
    false_positive = Enum.count(pairs, fn {gold, pred} -> gold != label and pred == label end)
    false_negative = Enum.count(pairs, fn {gold, pred} -> gold == label and pred != label end)
    support = Enum.count(pairs, fn {gold, _pred} -> gold == label end)
    precision = ratio(true_positive, true_positive + false_positive)
    recall = ratio(true_positive, true_positive + false_negative)

    %{
      "precision" => precision,
      "recall" => recall,
      "f1" => f1_from_precision_recall(precision, recall),
      "support" => support
    }
  end

  defp mean_metric(by_label, _metric) when map_size(by_label) == 0, do: 0.0

  defp mean_metric(by_label, metric) do
    by_label
    |> Map.values()
    |> Enum.map(&Map.fetch!(&1, metric))
    |> Enum.sum()
    |> Kernel./(map_size(by_label))
  end

  defp weighted_metric(_by_label, supports, _metric) when map_size(supports) == 0, do: 0.0

  defp weighted_metric(by_label, supports, metric) do
    total = supports |> Map.values() |> Enum.sum()

    if total == 0 do
      0.0
    else
      Enum.reduce(by_label, 0.0, fn {label, stats}, acc ->
        acc + Map.fetch!(stats, metric) * Map.fetch!(supports, label) / total
      end)
    end
  end

  defp micro_f1(by_label) do
    true_positive =
      by_label |> Map.values() |> Enum.map(&(&1["support"] * &1["recall"])) |> Enum.sum()

    predicted_positive = by_label |> Map.values() |> Enum.map(&predicted_positive/1) |> Enum.sum()
    actual_positive = by_label |> Map.values() |> Enum.map(& &1["support"]) |> Enum.sum()
    precision = ratio(true_positive, predicted_positive)
    recall = ratio(true_positive, actual_positive)
    f1_from_precision_recall(precision, recall)
  end

  defp predicted_positive(%{"precision" => precision}) when precision == 0.0, do: 0.0

  defp predicted_positive(%{"precision" => precision, "recall" => recall, "support" => support}),
    do: support * recall / precision

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp f1_from_precision_recall(precision, _recall) when precision == 0.0, do: 0.0
  defp f1_from_precision_recall(_precision, recall) when recall == 0.0, do: 0.0

  defp f1_from_precision_recall(precision, recall),
    do: 2 * precision * recall / (precision + recall)

  @doc """
  Builds an evaluator metric that compares one prediction field to an example field.

  This is the normal first metric for classification, short-span QA, and
  beginner optimizer examples.
  """
  def exact_match(field \\ :answer) do
    fn example, prediction ->
      normalize_text(DSEx.Example.get(example, field)) ==
        normalize_text(DSEx.Prediction.get(prediction, field))
    end
  end

  @doc """
  Builds a metric that passes when an answer appears in a predicted context field.

  This is useful for retrieval tests where the program should surface supporting
  context before a final answer is judged.
  """
  def answer_passage_match(answer_field \\ :answer, context_field \\ :context) do
    fn example, prediction ->
      answer = normalize_text(DSEx.Example.get(example, answer_field))
      context = normalize_text(DSEx.Prediction.get(prediction, context_field, ""))
      answer != "" and String.contains?(context, answer)
    end
  end

  defp contains_token_sequence?(_left, ""), do: false
  defp contains_token_sequence?("", _right), do: false

  defp contains_token_sequence?(left, right) do
    left_tokens = String.split(left)
    right_tokens = String.split(right)
    right_tokens != [] and subsequence?(left_tokens, right_tokens)
  end

  defp subsequence?(tokens, sequence) when length(sequence) > length(tokens), do: false

  defp subsequence?(tokens, sequence) do
    0..(length(tokens) - length(sequence))
    |> Enum.any?(fn index -> Enum.slice(tokens, index, length(sequence)) == sequence end)
  end
end

defmodule Imp.Metrics do
  @moduledoc """
  Metrics for evaluation, selection, and optimization.

  In Imp, a metric is just an Elixir function that scores a program output
  against an example. Evaluation and optimizers accept a few convenient return
  shapes: booleans, numbers, maps with `:score` and `:feedback`, predictions
  that carry score fields, or `%Imp.Metrics.Result{}` values. Imp normalizes
  those shapes before it computes averages, chooses best-of-N candidates, or
  feeds optimizer reports.

  Use the small built-ins for deterministic local tasks and write ordinary
  functions when the task needs domain judgment.

  ## Example

      iex> metric = Imp.Metrics.exact_match(:answer)
      iex> example = Imp.example(question: "Capital?", answer: "Paris")
      iex> prediction = Imp.prediction(answer: "paris")
      iex> metric.(example, prediction)
      true

      iex> result = Imp.Metrics.normalize_result(%{score: 0.75, feedback: "partial"})
      iex> {result.score, result.passed?, result.feedback}
      {0.75, true, "partial"}
  """

  require Logger

  defmodule Result do
    @moduledoc """
    Normalized metric result with numeric score, pass/fail flag, feedback, and metadata.

    Evaluators and optimizers use this struct internally so metric functions can
    stay ergonomic at call sites.
    """

    defstruct score: 0.0, passed?: false, feedback: nil, metadata: %{}
  end

  @doc """
  Converts a metric return value into `%Imp.Metrics.Result{}`.

  Accepted values include `%Result{}`, `%Imp.Prediction{}`, maps, booleans,
  and numbers. Unknown values become a failed result with diagnostic feedback.
  """
  def normalize_result(%Result{} = result), do: result

  def normalize_result(%Imp.Prediction{} = prediction) do
    score = Imp.Prediction.get(prediction, :score, prediction.score || 0.0)

    metadata =
      prediction
      |> Imp.Prediction.to_map()
      |> Map.drop([:score, "score"])
      |> Map.merge(prediction.metadata)

    %Result{
      score: numeric_score(score),
      passed?: passed?(score),
      feedback: Imp.Prediction.get(prediction, :feedback),
      metadata: metadata
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

  # Word-boundary English article removal, exactly DSPy's
  # `re.sub(r"\b(a|an|the)\b", " ", text)`. PCRE2's `\b` under UCP (10.43+)
  # counts combining marks as word characters, but Python's `re` does not —
  # so after NFD an article followed by a bare combining mark keeps its
  # boundary in Python (see the pinned `article_then_combining_mark` and
  # `ring_and_diaeresis` fixture cases). Emulate Python's boundary with
  # explicit lookarounds over Python's word set (letters, digits,
  # underscore). Residual known divergence: exotic Other_Alphabetic
  # combining marks (e.g. Hebrew niqqud) count as word chars in Python but
  # not here; none can follow an ASCII English article in real QA data.
  @english_articles ~r/(?<![\p{L}\p{N}_])(a|an|the)(?![\p{L}\p{N}_])/u

  # Python `str.split()` whitespace: \t\n\v\f\r space, \x1c-\x1f, \x85, and
  # Unicode Z* (Zs/Zl/Zp). Elixir's `String.split/1` misses \x1c-\x1f, so the
  # set is spelled out to match Python byte-for-byte.
  @python_whitespace ~r/[\x09-\x0D\x1C-\x1F\x20\x{85}\p{Z}]+/u

  # DPR SimpleTokenizer pattern (tmp/dspy-3.2.1/dspy/dsp/utils/dpr.py):
  # runs of letters/digits/marks are word tokens; any other visible
  # (non-separator, non-control) character is a single-character token.
  @dpr_token_regex ~r/[\p{L}\p{N}\p{M}]+|[^\p{Z}\p{C}]/u

  # Official HotPotQA special labels (hotpot_evaluate_v1.py, mirrored by
  # DSPy's hotpot_f1_score): a yes/no/noanswer mismatch scores 0.
  @hotpot_special_labels ["yes", "no", "noanswer"]

  @doc """
  Normalizes answer text exactly like DSPy's `dspy.evaluate.metrics.normalize_text`.

  The SQuAD-style pipeline, in DSPy's order: Unicode NFD normalization,
  lowercasing, deletion (not substitution) of Python's `string.punctuation`
  characters (ASCII only — Unicode punctuation is kept), word-boundary English
  article removal, and whitespace collapse. Differential parity with real
  DSPy 3.2.1 is pinned in `test/metrics_dspy_parity_test.exs`.
  """
  def normalize_text(value) do
    value
    |> to_string()
    |> nfd!()
    |> String.downcase()
    |> delete_python_punctuation()
    |> then(&Regex.replace(@english_articles, &1, " "))
    |> collapse_python_whitespace()
  end

  defp nfd!(text) do
    case :unicode.characters_to_nfd_binary(text) do
      normalized when is_binary(normalized) ->
        normalized

      error ->
        raise ArgumentError,
              "normalize_text requires valid UTF-8 input, got #{inspect(text)} (#{inspect(error)})"
    end
  end

  # Deletes exactly Python's `string.punctuation` (the 32 ASCII characters
  # !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~), mirroring DSPy's `remove_punc`.
  defp delete_python_punctuation(text) do
    for <<codepoint::utf8 <- text>>, not python_punctuation?(codepoint), into: "" do
      <<codepoint::utf8>>
    end
  end

  defp python_punctuation?(codepoint)
       when codepoint in 0x21..0x2F or codepoint in 0x3A..0x40 or
              codepoint in 0x5B..0x60 or codepoint in 0x7B..0x7E,
       do: true

  defp python_punctuation?(_codepoint), do: false

  defp collapse_python_whitespace(text) do
    @python_whitespace
    |> Regex.split(text, trim: true)
    |> Enum.join(" ")
  end

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

    if pred_tokens == [] and gold_tokens == [] do
      # DSPy prints a diagnostic on this rare edge (both sides normalize to
      # nothing) and still scores 0; mirror the loudness, not just the value.
      Logger.warning(
        "F1 metric: rare edge case of empty normalized prediction AND ground truth; scoring 0.0"
      )
    end

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
  Computes HotPotQA-style F1 mirroring DSPy's `hotpot_f1_score`/`HotPotF1`.

  Identical to `f1/2` except that when either normalized side is one of the
  special HotPotQA labels `"yes"`, `"no"`, or `"noanswer"` and the sides
  differ, the score is 0.0 — the same gating the official HotPotQA evaluation
  script (`hotpot_evaluate_v1.py`) applies. When given multiple acceptable
  answers, the best score is returned.
  """
  def hotpot_f1(prediction, answers) when is_list(answers),
    do: answers |> Enum.map(&hotpot_f1(prediction, &1)) |> Enum.max(fn -> 0.0 end)

  def hotpot_f1(prediction, answer) do
    normalized_prediction = normalize_text(prediction)
    normalized_gold = normalize_text(answer)

    special? =
      normalized_prediction in @hotpot_special_labels or normalized_gold in @hotpot_special_labels

    if special? and normalized_prediction != normalized_gold do
      0.0
    else
      f1(prediction, answer)
    end
  end

  @doc """
  Returns a structured extractive-QA metric result.

  The result uses exact match as the pass/fail score and includes F1, answer
  type, and span-relation metadata for dashboards and parity reports.
  """
  def extractive_qa(prediction, answer, opts \\ []) do
    opts = validate_metric_opts!(opts, "Imp.Metrics.extractive_qa/3")
    exact_match? = em(prediction, answer)
    f1_score = f1(prediction, answer)
    metric_name = metric_name(opts, "extractive_qa_exact_match", "Imp.Metrics.extractive_qa/3")

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
    opts = validate_metric_opts!(opts, "Imp.Metrics.classification/3")
    metric_name = metric_name(opts, "classification_accuracy", "Imp.Metrics.classification/3")
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
    opts = validate_metric_opts!(opts, "Imp.Metrics.classification_report/2")
    rows = validate_rows!(rows, "Imp.Metrics.classification_report/2")
    pairs = Enum.map(rows, &classification_pair!(&1, "Imp.Metrics.classification_report/2"))

    labels =
      pairs |> Enum.flat_map(fn {gold, pred} -> [gold, pred] end) |> Enum.uniq() |> Enum.sort()

    total = length(pairs)
    correct = Enum.count(pairs, fn {gold, pred} -> gold == pred and gold != "" end)
    by_label = Map.new(labels, &{&1, label_stats(&1, pairs)})
    supports = Map.new(by_label, fn {label, stats} -> {label, stats["support"]} end)

    %{
      "task_metric" =>
        metric_name(opts, "classification_report", "Imp.Metrics.classification_report/2"),
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

  `prediction` may be a `%Imp.Prediction{}` with RAG retrieval metadata or a
  list of retrieved document maps. Expected ids can be strings or atoms.
  """
  def retrieval_recall(prediction, expected_ids, opts \\ []) do
    opts = validate_metric_opts!(opts, "Imp.Metrics.retrieval_recall/3")
    metric_name = metric_name(opts, "retrieval_recall", "Imp.Metrics.retrieval_recall/3")
    min_recall = min_recall(opts, "Imp.Metrics.retrieval_recall/3")
    expected = expected_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
    retrieved = prediction |> retrieved_ids() |> MapSet.new()
    hits = MapSet.intersection(expected, retrieved)

    recall =
      if MapSet.size(expected) == 0, do: 0.0, else: MapSet.size(hits) / MapSet.size(expected)

    %Result{
      score: recall,
      passed?: recall >= min_recall,
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

  defp classification_pair!({gold, predicted}, _context),
    do: {normalize_text(gold), normalize_text(predicted)}

  defp classification_pair!(%{} = row, context) do
    gold = Map.get(row, :gold, Map.get(row, "gold", Map.get(row, :label, Map.get(row, "label"))))

    predicted =
      Map.get(
        row,
        :predicted,
        Map.get(row, "predicted", Map.get(row, :prediction, Map.get(row, "prediction")))
      )

    if is_nil(gold) or is_nil(predicted) do
      raise ArgumentError,
            "#{context} rows must include gold/label and predicted/prediction fields, got: #{inspect(row)}"
    end

    {normalize_text(gold), normalize_text(predicted)}
  end

  defp classification_pair!(row, context) do
    raise ArgumentError,
          "#{context} rows must be {gold, predicted} tuples or maps, got: #{inspect(row)}"
  end

  defp retrieved_ids(%Imp.Prediction{metadata: metadata}) do
    metadata
    |> Map.get(:retrieval, %{})
    |> Map.get(:docs, [])
    |> retrieved_ids()
  end

  defp retrieved_ids(docs) when is_list(docs), do: Enum.map(docs, &doc_id/1)
  defp retrieved_ids(_prediction), do: []

  defp doc_id(%{} = doc), do: doc |> Map.get(:id, Map.get(doc, "id", "")) |> to_string()
  defp doc_id(_doc), do: ""

  defp validate_metric_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_metric_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end

  defp metric_name(opts, default, context) do
    case Keyword.get(opts, :metric_name, default) do
      name when is_binary(name) ->
        name

      name ->
        raise ArgumentError,
              "#{context} expects :metric_name to be a string, got: #{inspect(name)}"
    end
  end

  defp min_recall(opts, context) do
    case Keyword.get(opts, :min_recall, 1.0) do
      value when is_number(value) and value >= 0.0 and value <= 1.0 ->
        value * 1.0

      value ->
        raise ArgumentError,
              "#{context} expects :min_recall to be a number between 0.0 and 1.0, got: #{inspect(value)}"
    end
  end

  defp validate_rows!(rows, context) do
    if Enumerable.impl_for(rows) do
      rows
    else
      raise ArgumentError, "#{context} expects rows to be an enumerable, got: #{inspect(rows)}"
    end
  end

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

  Mirrors DSPy's `answer_exact_match` (dspy/evaluate/metrics.py): when the
  example field holds a LIST of acceptable answers, the prediction passes if
  it matches ANY member after `normalize_text/1`.

      iex> metric = Imp.Metrics.exact_match(:answer)
      iex> example = Imp.example(question: "What is 1+1?", answer: ["2", "two"])
      iex> metric.(example, Imp.prediction(answer: "Two"))
      true
  """
  def exact_match(field \\ :answer) do
    fn example, prediction ->
      predicted = normalize_text(Imp.Prediction.get(prediction, field))

      case Imp.Example.get(example, field) do
        answers when is_list(answers) ->
          Enum.any?(answers, &(normalize_text(&1) == predicted))

        answer ->
          normalize_text(answer) == predicted
      end
    end
  end

  @doc """
  Builds a metric that passes when an answer appears in a predicted context field.

  Mirrors DSPy's `answer_passage_match`: each passage is checked separately
  (a string context counts as a single passage) and matching uses DPR
  `has_answer` token-sequence semantics via `passage_match/2`, so an answer
  can never match inside an unrelated word and never across a passage seam.
  """
  def answer_passage_match(answer_field \\ :answer, context_field \\ :context) do
    fn example, prediction ->
      answers = example |> Imp.Example.get(answer_field) |> List.wrap()
      passages = prediction |> Imp.Prediction.get(context_field, []) |> List.wrap()
      passage_match(passages, answers)
    end
  end

  @doc """
  Returns whether any passage contains any answer, mirroring DSPy's
  `_passage_match` (dspy/evaluate/metrics.py) over DPR `has_answer`
  (dspy/dsp/utils/dpr.py).

  Answers and passages both go through `normalize_text/1` and DPR
  tokenization; an answer matches only as a contiguous token sequence within
  a single passage.
  """
  def passage_match(passages, answers) when is_list(passages) and is_list(answers) do
    tokenized_answers = Enum.map(answers, &dpr_normalize(normalize_text(&1)))

    Enum.any?(passages, fn passage ->
      has_answer(tokenized_answers, normalize_text(passage))
    end)
  end

  @doc """
  DPR `has_answer`: whether any tokenized answer occurs as a contiguous
  token subsequence of the DPR-normalized `text`.

  Faithful to DSPy's port of Facebook DPR, including the edge where an
  empty tokenized answer matches any text.
  """
  def has_answer(tokenized_answers, text) when is_list(tokenized_answers) do
    text_tokens = dpr_normalize(text)
    Enum.any?(tokenized_answers, &token_window_match?(text_tokens, &1))
  end

  @doc """
  DPR normalization (dspy/dsp/utils/dpr.py `DPR_normalize`): NFD, tokenize
  with the DPR SimpleTokenizer pattern, lowercase each token.
  """
  def dpr_normalize(text) do
    normalized = text |> to_string() |> nfd!()

    @dpr_token_regex
    |> Regex.scan(normalized)
    |> Enum.map(fn [token | _groups] -> String.downcase(token) end)
  end

  # Mirrors DPR has_answer's window scan: `for i in range(0, len(text) -
  # len(answer) + 1)`, so an empty answer matches at offset 0 of any text.
  defp token_window_match?(text_tokens, answer_tokens) do
    text_length = length(text_tokens)
    answer_length = length(answer_tokens)

    answer_length <= text_length and
      Enum.any?(0..(text_length - answer_length), fn offset ->
        Enum.slice(text_tokens, offset, answer_length) == answer_tokens
      end)
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

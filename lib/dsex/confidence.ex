defmodule DSEx.Confidence do
  @moduledoc """
  Confidence-aware evaluation for enum-constrained JSON classification.

  The implementation follows GEPA commit
  `65df4325e3fb4781cf2ab17dd144d6ce2f7b98fe` for joint token logprob,
  scoring formulas, feedback buckets, and alternative formatting. The exposed
  confidence objective is named `:raw_confidence`; it is not a calibrated
  probability.

  Missing logprobs fail closed by default. `fallback: :accuracy` must be
  selected explicitly to continue with accuracy only. In that mode the
  `:raw_confidence` objective is omitted and unavailability is recorded in
  metric metadata. This intentionally improves the upstream adapter's numeric
  `0.0` confidence objective for missing logprobs, which can be mistaken for a
  measured value.
  """

  alias DSEx.Confidence.Scoring

  @max_feedback_alternatives 3

  @type fallback :: :error | :accuracy

  @doc "Evaluates a prediction and returns a normalized metric result map."
  @spec evaluate(DSEx.Example.t(), DSEx.Prediction.t() | nil, keyword()) :: map()
  def evaluate(example, prediction, opts) do
    field = Keyword.fetch!(opts, :field)
    expected_field = Keyword.get(opts, :expected_field, :answer)
    enum_values = Keyword.fetch!(opts, :enum)
    high = Keyword.get(opts, :high_confidence_threshold, 0.99)
    low = Keyword.get(opts, :low_confidence_threshold, 0.90)

    scoring =
      Keyword.get(opts, :scoring, Scoring.LinearBlend.new(low_confidence_threshold: high))

    fallback = Keyword.get(opts, :fallback, :error)

    validate_thresholds!(high, low)
    validate_fallback!(fallback)

    expected = example |> DSEx.Example.get(expected_field) |> stringify()
    got = prediction_value(prediction, field)
    correct? = correct?(got, expected)

    metadata = if(match?(%DSEx.Prediction{}, prediction), do: prediction.metadata, else: %{})

    case DSEx.Capabilities.token_logprobs(metadata) do
      :ok ->
        evaluate_with_logprobs(
          metadata,
          expected,
          got,
          correct?,
          enum_values,
          field,
          scoring,
          high,
          low,
          fallback,
          additional_context(example, opts)
        )

      {:error, reason} when fallback == :accuracy ->
        accuracy_fallback(expected, got, correct?, reason, additional_context(example, opts))

      {:error, reason} ->
        unavailable_failure(reason)
    end
  end

  defp evaluate_with_logprobs(
         metadata,
         expected,
         got,
         correct?,
         enum_values,
         field,
         scoring,
         high,
         low,
         fallback,
         context
       ) do
    req_llm = map_value(metadata, :req_llm)
    content = map_value(req_llm, :content)
    logprobs = map_value(req_llm, :logprobs)

    case DSEx.Logprobs.extract(content, logprobs, field, enum_values) do
      {:ok, extraction} ->
        score = Scoring.score(scoring, correct?, extraction.joint_logprob)

        %{
          score: score,
          passed?: correct?,
          feedback:
            feedback(
              correct?,
              expected,
              got,
              extraction.joint_logprob,
              extraction.top_alternatives,
              context,
              high,
              low
            ),
          metadata: %{
            objective_scores: %{
              accuracy: accuracy(correct?),
              raw_confidence: extraction.raw_confidence
            },
            confidence: %{
              available?: true,
              joint_logprob: extraction.joint_logprob,
              raw_confidence: extraction.raw_confidence,
              top_alternatives: extraction.top_alternatives
            }
          }
        }

      {:error, reason} when fallback == :accuracy ->
        accuracy_fallback(
          expected,
          got,
          correct?,
          {:logprob_extraction_failed, reason},
          context
        )

      {:error, reason} ->
        unavailable_failure({:logprob_extraction_failed, reason})
    end
  end

  defp accuracy_fallback(expected, got, correct?, reason, context) do
    %{
      score: accuracy(correct?),
      passed?: correct?,
      feedback: feedback(correct?, expected, got, nil, [], context, 0.99, 0.90),
      metadata: %{
        objective_scores: %{accuracy: accuracy(correct?)},
        confidence: %{available?: false, reason: reason, fallback: :accuracy}
      }
    }
  end

  defp unavailable_failure(reason) do
    message = {:confidence_unavailable, reason}

    %{
      score: 0.0,
      passed?: false,
      feedback: message,
      metadata: %{
        dsex_metric_error: message,
        confidence: %{available?: false, reason: reason, fallback: :error}
      }
    }
  end

  @doc "Builds source-faithful reflective feedback from correctness and raw confidence."
  def feedback(correct?, expected, got, joint_logprob, alternatives, context, high, low) do
    raw_confidence = if is_number(joint_logprob), do: :math.exp(joint_logprob)
    got_text = got || "<parse error>"

    if correct? do
      cond do
        is_nil(raw_confidence) or raw_confidence >= high ->
          "Correct."

        raw_confidence < low ->
          alternatives = format_alternatives(alternatives, expected)

          "Correct but uncertain (#{percent(raw_confidence)} probability). " <>
            "Model answered '#{expected}' but was nearly split with alternatives." <>
            maybe_alternatives(" Top alternatives: ", alternatives) <>
            " The model cannot reliably distinguish between these categories with the current prompt."

        true ->
          alternatives = format_alternatives(alternatives, expected)

          "Correct (#{percent(raw_confidence)} probability)." <>
            maybe_alternatives(" Close alternatives: ", alternatives)
      end
    else
      incorrect_feedback(raw_confidence, expected, got_text, alternatives, context, high, low)
    end
  end

  defp incorrect_feedback(raw_confidence, expected, got, alternatives, context, high, low) do
    formatted = format_alternatives(alternatives, got)
    correct_alternative = find_alternative(alternatives, expected)

    base =
      cond do
        is_number(raw_confidence) and raw_confidence >= high ->
          "WRONG -- model has #{percent(raw_confidence)} certainty on '#{got}' " <>
            "but the correct answer is '#{expected}'. " <>
            "The model has no doubt about its wrong answer; " <>
            "the prompt is actively misleading it for this type of input." <>
            maybe_correct_alternative(expected, correct_alternative) <>
            maybe_alternatives(" Alternatives: ", formatted) <>
            " The prompt must add explicit rules to disambiguate '#{got}' vs '#{expected}'."

        is_number(raw_confidence) and raw_confidence >= low ->
          "Wrong (#{percent(raw_confidence)} probability). Expected '#{expected}' but got '#{got}'." <>
            maybe_alternatives(" Alternatives: ", formatted) <>
            " The prompt should better guide the model for this case."

        true ->
          confidence =
            if is_number(raw_confidence),
              do: "#{percent(raw_confidence)} probability",
              else: "unknown confidence"

          "Wrong (#{confidence}). Expected '#{expected}' but got '#{got}'. " <>
            "The model was uncertain -- better prompt guidance could fix this." <>
            maybe_alternatives(" Alternatives: ", formatted)
      end

    base <> format_context(context)
  end

  defp format_alternatives(alternatives, exclude) do
    alternatives
    |> Enum.take(@max_feedback_alternatives)
    |> Enum.flat_map(fn alternative ->
      value = map_value(alternative, :resolved_value) || map_value(alternative, :token) || ""
      raw_confidence = map_value(alternative, :raw_confidence) || 0.0

      if value != "" and value != exclude,
        do: ["'#{value}' (#{percent(raw_confidence)})"],
        else: []
    end)
    |> Enum.join(", ")
  end

  defp find_alternative(alternatives, target) do
    Enum.find_value(alternatives, fn alternative ->
      value = map_value(alternative, :resolved_value) || map_value(alternative, :token) || ""
      if value == target, do: map_value(alternative, :raw_confidence) || 0.0
    end)
  end

  defp maybe_correct_alternative(_expected, nil), do: ""

  defp maybe_correct_alternative(expected, raw_confidence) do
    " The correct category '#{expected}' only had #{percent(raw_confidence, 1)} probability."
  end

  defp maybe_alternatives(_prefix, ""), do: ""
  defp maybe_alternatives(prefix, alternatives), do: prefix <> alternatives <> "."

  defp format_context(context) when map_size(context) == 0, do: ""

  defp format_context(context) do
    lines = Enum.map_join(context, "\n", fn {key, value} -> "#{key}: #{value}" end)
    "\nAdditional context:\n" <> lines
  end

  defp additional_context(example, opts) do
    opts
    |> Keyword.get(:additional_context, [])
    |> Enum.map(fn key -> {key, DSEx.Example.get(example, key)} end)
    |> Map.new()
  end

  defp prediction_value(%DSEx.Prediction{} = prediction, field),
    do: prediction |> DSEx.Prediction.get(field) |> stringify()

  defp prediction_value(_prediction, _field), do: nil

  defp correct?(nil, _expected), do: false

  defp correct?(got, expected),
    do: String.downcase(String.trim(got)) == String.downcase(String.trim(expected))

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
  defp accuracy(true), do: 1.0
  defp accuracy(false), do: 0.0

  defp percent(value, decimals \\ 0) do
    :erlang.float_to_binary(value * 100.0, decimals: decimals) <> "%"
  end

  defp validate_thresholds!(high, low) do
    unless is_number(high) and high > 0.0 and high <= 1.0,
      do: raise(ArgumentError, "high_confidence_threshold must be in (0, 1]")

    unless is_number(low) and low > 0.0 and low < 1.0,
      do: raise(ArgumentError, "low_confidence_threshold must be in (0, 1)")
  end

  defp validate_fallback!(fallback) when fallback in [:error, :accuracy], do: :ok

  defp validate_fallback!(fallback),
    do: raise(ArgumentError, "fallback must be :error or :accuracy, got: #{inspect(fallback)}")

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil
end

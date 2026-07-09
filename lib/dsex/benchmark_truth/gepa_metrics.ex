defmodule DSEx.BenchmarkTruth.GepaMetrics do
  @moduledoc false

  def metric(spec) do
    output_key = spec["output_key"]

    case spec["upstream_metric"] do
      "AIME.metric integer exact match" ->
        &aime_integer_exact/2

      "dspy.evaluate.answer_exact_match" ->
        &hotpot_answer_exact/2

      "hover_utils.discrete_retrieval_eval" ->
        &hover_retrieval/2

      _other ->
        exact_output(output_key)
    end
  end

  defp aime_integer_exact(example, prediction) do
    with {gold, ""} <- example |> DSEx.Example.get(:answer) |> to_string() |> Integer.parse(),
         {predicted, ""} <-
           prediction |> DSEx.Prediction.get(:answer) |> to_string() |> Integer.parse() do
      gold == predicted
    else
      _ -> false
    end
  end

  defp hotpot_answer_exact(example, prediction) do
    answer = DSEx.Example.get(example, :answer)
    predicted = DSEx.Prediction.get(prediction, :answer)
    DSEx.Metrics.em(predicted, answer)
  end

  defp hover_retrieval(example, prediction) do
    gold_titles =
      example
      |> DSEx.Example.get(:supporting_facts, [])
      |> Enum.map(&supporting_fact_title/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&DSEx.Metrics.normalize_text/1)
      |> MapSet.new()

    found_titles =
      prediction
      |> DSEx.Prediction.get(:retrieved_docs, [])
      |> List.wrap()
      |> Enum.map(&retrieved_title/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&DSEx.Metrics.normalize_text/1)
      |> MapSet.new()

    MapSet.subset?(gold_titles, found_titles)
  end

  defp supporting_fact_title(%{"key" => key}), do: key
  defp supporting_fact_title(%{key: key}), do: key
  defp supporting_fact_title(_other), do: nil

  defp retrieved_title(value) when is_binary(value) do
    value |> String.split(" | ", parts: 2) |> hd()
  end

  defp retrieved_title(%{"title" => title}), do: title
  defp retrieved_title(%{title: title}), do: title
  defp retrieved_title(_other), do: nil

  defp exact_output(output_key) do
    fn example, prediction ->
      predicted = DSEx.Prediction.get(prediction, output_key)
      gold = DSEx.Example.get(example, output_key)
      DSEx.Metrics.normalize_text(predicted) == DSEx.Metrics.normalize_text(gold)
    end
  end
end

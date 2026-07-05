defmodule DSPy.Metrics do
  @moduledoc "Common evaluation metrics."

  def normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in ["a", "an", "the"]))
    |> Enum.join(" ")
  end

  def em(prediction, answers) when is_list(answers),
    do: Enum.any?(answers, &(normalize_text(prediction) == normalize_text(&1)))

  def em(prediction, answer), do: normalize_text(prediction) == normalize_text(answer)

  def f1(prediction, answers) when is_list(answers),
    do: answers |> Enum.map(&f1(prediction, &1)) |> Enum.max(fn -> 0.0 end)

  def f1(prediction, answer) do
    pred_tokens = normalize_text(prediction) |> String.split()
    gold_tokens = normalize_text(answer) |> String.split()
    common = Enum.count(pred_tokens, &(&1 in gold_tokens))

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

  def exact_match(field \\ :answer) do
    fn example, prediction ->
      normalize_text(DSPy.Example.get(example, field)) ==
        normalize_text(DSPy.Prediction.get(prediction, field))
    end
  end

  def answer_passage_match(answer_field \\ :answer, context_field \\ :context) do
    fn example, prediction ->
      answer = normalize_text(DSPy.Example.get(example, answer_field))
      context = normalize_text(DSPy.Prediction.get(prediction, context_field, ""))
      answer != "" and String.contains?(context, answer)
    end
  end
end

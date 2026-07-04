defmodule DSPy.Metrics do
  @moduledoc "Common evaluation metrics."

  def exact_match(field \\ :answer) do
    fn example, prediction ->
      normalize(DSPy.Example.get(example, field)) ==
        normalize(DSPy.Prediction.get(prediction, field))
    end
  end

  def answer_passage_match(answer_field \\ :answer, context_field \\ :context) do
    fn example, prediction ->
      answer = normalize(DSPy.Example.get(example, answer_field))
      context = normalize(DSPy.Prediction.get(prediction, context_field, ""))
      answer != "" and String.contains?(context, answer)
    end
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end

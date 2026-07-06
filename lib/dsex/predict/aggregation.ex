defmodule DSEx.Predict.Aggregation do
  @moduledoc "Aggregation helpers for multiple predictions."

  def default_normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  def majority(predictions, opts \\ []) do
    field = Keyword.get(opts, :field)
    normalize = Keyword.get(opts, :normalize, &default_normalize/1)

    predictions
    |> Enum.map(&value_for(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(normalize)
    |> Enum.max_by(fn {_key, values} -> length(values) end, fn -> {nil, []} end)
    |> elem(1)
    |> List.first()
  end

  defp value_for(%DSEx.Prediction{} = prediction, nil), do: prediction

  defp value_for(%DSEx.Prediction{} = prediction, field),
    do: DSEx.Prediction.get(prediction, field)

  defp value_for(map, field) when is_map(map) and not is_nil(field),
    do: Map.get(map, field) || Map.get(map, to_string(field))

  defp value_for(value, _field), do: value
end

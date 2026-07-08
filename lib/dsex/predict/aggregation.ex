defmodule DSEx.Predict.Aggregation do
  @moduledoc """
  Aggregation helpers for multiple predictions or raw values.

  `majority/2` is the common helper for self-consistency style workflows: run a
  program several times, then keep the most common answer. Pass `field: :answer`
  when aggregating `%DSEx.Prediction{}` values by a named output field. Without
  a field, maps and structs are still safe to compare because the default
  normalizer falls back to `inspect/1` for values that do not implement
  `String.Chars`.

  Ties keep the first value from the winning normalized group.

  ## Example

      iex> predictions = [
      ...>   DSEx.Prediction.new(answer: "Paris"),
      ...>   DSEx.Prediction.new(answer: "paris"),
      ...>   DSEx.Prediction.new(answer: "Lyon")
      ...> ]
      iex> DSEx.Predict.Aggregation.majority(predictions, field: :answer)
      "Paris"
  """

  @doc """
  Normalizes values for majority grouping.

  Strings, atoms, numbers, and other `String.Chars` values use `to_string/1`.
  Maps and structs fall back to `inspect/1`, avoiding crashes when callers
  aggregate full prediction values.
  """
  def default_normalize(value) do
    value
    |> stringable_text()
    |> String.trim()
    |> String.downcase()
  end

  @doc """
  Returns the most common value after normalization.

  Options:

  - `:field` extracts a field from predictions or maps before voting.
  - `:normalize` supplies a custom one-argument grouping function.
  """
  @option_schema [
    field: [
      type: {:custom, DSEx.FieldSelector, :validate_optional_name, []},
      default: nil
    ],
    normalize: [
      type: {:custom, __MODULE__, :validate_normalize, []},
      default: &__MODULE__.default_normalize/1
    ]
  ]

  def majority(predictions, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.Aggregation.majority/2")
    field = opts[:field]
    normalize = opts[:normalize]

    predictions
    |> Enum.map(&value_for(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(normalize)
    |> Enum.max_by(fn {_key, values} -> length(values) end, fn -> {nil, []} end)
    |> elem(1)
    |> List.first()
  end

  def validate_normalize(normalize) when is_function(normalize, 1), do: {:ok, normalize}

  def validate_normalize(normalize) do
    {:error, "expected a unary function, got: #{inspect(normalize)}"}
  end

  defp value_for(%DSEx.Prediction{} = prediction, nil), do: prediction

  defp value_for(%DSEx.Prediction{} = prediction, field),
    do: DSEx.Prediction.get(prediction, field)

  defp value_for(map, field) when is_map(map) and not is_nil(field),
    do: Map.get(map, field) || Map.get(map, to_string(field))

  defp value_for(value, _field), do: value

  defp stringable_text(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _impl -> to_string(value)
    end
  end
end

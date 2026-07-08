defmodule DSEx.Predict.KNN do
  @moduledoc """
  Callable KNN predictor over examples.

  `KNN` retrieves nearest examples from a trainset using token overlap. The
  `:field` option controls both sides of the match: which field is read from
  training examples and which input field is used as the query at call time.
  Pass a list of fields to concatenate several input fields.
  """

  defstruct [:retriever, :field]

  @option_schema [
    field: [
      type: {:custom, DSEx.FieldSelector, :validate_selector, []},
      default: :question
    ]
  ]

  def new(k, trainset, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.KNN.new/3")
    field = opts[:field]

    %__MODULE__{
      retriever: DSEx.Retrievers.KNN.new(trainset, k: k, field: field),
      field: field
    }
  end

  def call(%__MODULE__{retriever: retriever, field: field}, inputs) do
    query =
      inputs
      |> normalize_inputs!()
      |> query_text(field)

    retriever |> DSEx.Retrievers.KNN.call(query)
  end

  defp normalize_inputs!(inputs) when is_map(inputs), do: inputs

  defp normalize_inputs!(inputs) when is_list(inputs) do
    Map.new(inputs)
  rescue
    _error ->
      raise ArgumentError,
            "DSEx.Predict.KNN.call/2 expects inputs as a map or field pair list; got: #{inspect(inputs)}"
  end

  defp normalize_inputs!(inputs) do
    raise ArgumentError,
          "DSEx.Predict.KNN.call/2 expects inputs as a map or field pair list; got: #{inspect(inputs)}"
  end

  defp query_text(inputs, fields) when is_list(fields) do
    fields
    |> Enum.map(&Map.get(inputs, &1, Map.get(inputs, to_string(&1), "")))
    |> Enum.map_join(" ", &safe_text/1)
  end

  defp query_text(inputs, field),
    do: inputs |> Map.get(field, Map.get(inputs, to_string(field), "")) |> safe_text()

  defp safe_text(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _impl -> to_string(value)
    end
  end
end

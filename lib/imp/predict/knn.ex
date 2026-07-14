defmodule Imp.Predict.KNN do
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
      type: {:custom, Imp.FieldSelector, :validate_selector, []},
      default: :question
    ]
  ]

  def new(k, trainset, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.KNN.new/3")
    field = opts[:field]

    %__MODULE__{
      retriever: Imp.Retrievers.KNN.new(trainset, k: k, field: field),
      field: field
    }
  end

  def call(%__MODULE__{retriever: retriever, field: field}, inputs) do
    query =
      inputs
      |> normalize_inputs!()
      |> query_text(field)

    retriever |> Imp.Retrievers.KNN.call(query)
  end

  defp normalize_inputs!(inputs) when is_map(inputs), do: inputs

  defp normalize_inputs!(inputs) when is_list(inputs) do
    Map.new(inputs)
  rescue
    error ->
      reraise ArgumentError,
              "Imp.Predict.KNN.call/2 expects inputs as a map or field pair list; got: #{inspect(inputs)} (#{Exception.message(error)})",
              __STACKTRACE__
  end

  defp normalize_inputs!(inputs) do
    raise ArgumentError,
          "Imp.Predict.KNN.call/2 expects inputs as a map or field pair list; got: #{inspect(inputs)}"
  end

  defp query_text(inputs, fields) when is_list(fields) do
    fields
    |> Enum.map(&field_value(inputs, &1, ""))
    |> Enum.map_join(" ", &safe_text/1)
  end

  defp query_text(inputs, field),
    do: inputs |> field_value(field, "") |> safe_text()

  defp field_value(inputs, field, default) do
    cond do
      Map.has_key?(inputs, field) ->
        Map.fetch!(inputs, field)

      Map.has_key?(inputs, to_string(field)) ->
        Map.fetch!(inputs, to_string(field))

      is_binary(field) ->
        existing_atom_value(inputs, field, default)

      true ->
        default
    end
  end

  defp existing_atom_value(inputs, field, default) do
    atom = String.to_existing_atom(field)
    Map.get(inputs, atom, default)
  rescue
    ArgumentError -> default
  end

  defp safe_text(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _impl -> to_string(value)
    end
  end
end

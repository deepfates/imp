defmodule DSEx.Prediction do
  @moduledoc """
  Structured output from a DSEx program.

  Predictions carry the named output fields produced by a program plus optional
  completions, score, and metadata. Program modules use fields for task answers,
  metrics use `score` or score-like fields when normalizing results, and traces
  live under metadata so debugging information stays separate from task output.

  Like `DSEx.Example`, prediction keys are normalized without creating atoms
  from unknown external strings. This matters for provider JSON, user-provided
  schemas, and other dynamic boundaries.

  ## Example

      iex> prediction =
      ...>   DSEx.Prediction.new(%{"answer" => "Paris", "external_field" => 42},
      ...>     score: 1.0,
      ...>     metadata: %{trace: %{provider: :local}}
      ...>   )
      iex> DSEx.Prediction.get(prediction, :answer)
      "Paris"
      iex> DSEx.Prediction.get(prediction, "external_field")
      42
      iex> {prediction.score, prediction.metadata.trace.provider}
      {1.0, :local}
  """

  @type t :: %__MODULE__{
          fields: map(),
          completions: list(),
          score: number() | nil,
          metadata: map()
        }
  defstruct fields: %{}, completions: [], score: nil, metadata: %{}

  @option_schema [
    completions: [type: {:list, :any}, default: []],
    score: [type: :any, default: nil],
    metadata: [type: :map, default: %{}]
  ]

  @doc """
  Builds a prediction from fields and optional completions, score, and metadata.

  `fields` may be a map or field pair list. Existing atom names in string keys
  are resolved to those atoms, while unknown string keys remain strings.
  """
  def new(fields \\ %{}, opts \\ [])

  def new(fields, opts) when is_list(fields) or is_map(fields) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Prediction.new/2")

    %__MODULE__{
      fields: normalize_fields(fields),
      completions: opts[:completions],
      score: opts[:score],
      metadata: opts[:metadata]
    }
  end

  def new(fields, _opts) do
    raise ArgumentError,
          "DSEx.Prediction.new/2 expects a map or field pair list; got: #{inspect(fields)}"
  end

  @doc "Reads a prediction field, returning `default` when it is missing."
  def get(%__MODULE__{fields: fields}, key, default \\ nil),
    do: get_key(fields, normalize_key(key), default)

  @doc "Reads a prediction field or raises `KeyError` when it is missing."
  def fetch!(%__MODULE__{fields: fields}, key) do
    case fetch_key(fields, normalize_key(key)) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: fields
    end
  end

  @doc "Returns a copy of the prediction with one field set."
  def put(%__MODULE__{fields: fields} = prediction, key, value),
    do: %{prediction | fields: Map.put(fields, normalize_key(key), value)}

  @doc "Returns the prediction field map."
  def to_map(%__MODULE__{fields: fields}), do: fields

  @doc "Converts an example into a prediction, preserving fields and applying prediction options."
  def from_example(%DSEx.Example{} = example, opts \\ []),
    do: new(DSEx.Example.to_map(example), opts)

  defp normalize_fields(fields) do
    Enum.reduce(fields, %{}, fn
      {key, value}, normalized ->
        Map.put(normalized, normalize_key(key), value)

      invalid_entry, _normalized ->
        raise ArgumentError,
              "DSEx.Prediction.new/2 expects fields as {key, value} pairs; got entry: #{inspect(invalid_entry)}"
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp normalize_key(key) do
    raise ArgumentError,
          "DSEx.Prediction keys must be atoms or strings; got: #{inspect(key)}"
  end

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp get_key(fields, key, default) do
    case fetch_key(fields, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_key(fields, key) do
    cond do
      Map.has_key?(fields, key) ->
        Map.fetch(fields, key)

      is_atom(key) and Map.has_key?(fields, Atom.to_string(key)) ->
        Map.fetch(fields, Atom.to_string(key))

      is_binary(key) ->
        case existing_atom_or_string(key) do
          atom when is_atom(atom) -> Map.fetch(fields, atom)
          _string -> :error
        end

      true ->
        :error
    end
  end
end

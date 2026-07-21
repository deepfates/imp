defmodule Imp.Prediction do
  @moduledoc """
  Structured output from an Imp program.

  Predictions carry the named output fields produced by a program plus optional
  completions, score, and metadata. Program modules use fields for task answers,
  metrics use `score` or score-like fields when normalizing results, and traces
  live under metadata so debugging information stays separate from task output.

  Like `Imp.Example`, prediction keys are normalized without creating atoms
  from unknown external strings. This matters for provider JSON, user-provided
  schemas, and other dynamic boundaries.

  ## Example

      iex> prediction =
      ...>   Imp.Prediction.new(%{"answer" => "Paris", "external_field" => 42},
      ...>     score: 1.0,
      ...>     metadata: %{trace: %{provider: :local}}
      ...>   )
      iex> Imp.Prediction.get(prediction, :answer)
      "Paris"
      iex> Imp.Prediction.get(prediction, "external_field")
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
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Prediction.new/2")

    %__MODULE__{
      fields: normalize_fields(fields),
      completions: opts[:completions],
      score: opts[:score],
      metadata: opts[:metadata]
    }
  end

  def new(fields, _opts) do
    raise ArgumentError,
          "Imp.Prediction.new/2 expects a map or field pair list; got: #{inspect(fields)}"
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

  @doc """
  Returns the LM usage ledger for this prediction.

  Ports DSPy's `Prediction.get_lm_usage()`: a map of model key (for example
  `"openai/gpt-4o-mini"`) to merged usage counters, populated when the
  `:track_usage` setting is true during the program call. Returns an empty map
  when usage was not tracked.
  """
  def get_lm_usage(%__MODULE__{metadata: metadata}), do: Map.get(metadata, :lm_usage, %{})

  @doc "Returns a copy of the prediction with the LM usage ledger set (see `get_lm_usage/1`)."
  def set_lm_usage(%__MODULE__{metadata: metadata} = prediction, usage) when is_map(usage),
    do: %{prediction | metadata: Map.put(metadata, :lm_usage, usage)}

  @doc "Converts an example into a prediction, preserving fields and applying prediction options."
  def from_example(%Imp.Example{} = example, opts \\ []),
    do: new(Imp.Example.to_map(example), opts)

  defp normalize_fields(fields) do
    Enum.reduce(fields, %{}, fn
      {key, value}, normalized ->
        Map.put(normalized, normalize_key(key), value)

      invalid_entry, _normalized ->
        raise ArgumentError,
              "Imp.Prediction.new/2 expects fields as {key, value} pairs; got entry: #{inspect(invalid_entry)}"
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp normalize_key(key) do
    raise ArgumentError,
          "Imp.Prediction keys must be atoms or strings; got: #{inspect(key)}"
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

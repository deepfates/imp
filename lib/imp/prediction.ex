defmodule Imp.Prediction do
  @moduledoc """
  Structured output from an Imp program.

  Predictions carry the named output fields produced by a program plus optional
  completions, score, and metadata. Program modules use fields for task answers,
  metrics use `score` or score-like fields when normalizing results, and traces
  live under metadata so debugging information stays separate from task output.

  Like `Imp.Example`, a key keeps the type it was given and no string is turned
  into an atom; every function that takes a key compares keys by their text.

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

  `fields` may be a map or field pair list. Keys stay the atoms or strings they
  were given.
  """
  def new(fields \\ %{}, opts \\ [])

  def new(fields, opts) when is_list(fields) or is_map(fields) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Prediction.new/2")

    %__MODULE__{
      fields: Imp.FieldMap.new!(fields, "Imp.Prediction.new/2", "Imp.Prediction"),
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
  def get(%__MODULE__{fields: fields}, key, default \\ nil) do
    case Imp.FieldMap.fetch(fields, key!(key)) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Reads a prediction field or raises `KeyError` when it is missing."
  def fetch!(%__MODULE__{fields: fields}, key) do
    case Imp.FieldMap.fetch(fields, key!(key)) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: fields
    end
  end

  @doc "Returns a copy of the prediction with one field set."
  def put(%__MODULE__{fields: fields} = prediction, key, value),
    do: %{prediction | fields: Imp.FieldMap.put(fields, key!(key), value)}

  @doc "Returns the prediction field map."
  def to_map(%__MODULE__{fields: fields}), do: fields

  @doc """
  Whether the program that made this prediction ended with its outputs.

  An `Imp.Predict.ReActV2` turn that was interrupted and could not answer says
  so with `termination_reason: :incomplete` in the prediction's metadata, and
  its fields hold no outputs. Every other prediction is complete.

      iex> Imp.Prediction.complete?(Imp.Prediction.new(%{answer: "Paris"}))
      true
      iex> Imp.Prediction.complete?(
      ...>   Imp.Prediction.new(%{}, metadata: %{termination_reason: :incomplete})
      ...> )
      false
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{metadata: metadata}),
    do: Map.get(metadata, :termination_reason) != :incomplete

  @doc """
  Returns the LM usage ledger for this prediction.

  Ports DSPy's `Prediction.get_lm_usage()`: a map of model key (for example
  `"openai/gpt-4o-mini"`) to merged usage counters, populated when the
  `:track_usage` setting is true during the program call. Returns an empty map
  when usage was not tracked.
  """
  def get_lm_usage(%__MODULE__{metadata: metadata}), do: Map.get(metadata, :lm_usage, %{})

  @doc false
  def set_lm_usage(%__MODULE__{metadata: metadata} = prediction, usage) when is_map(usage),
    do: %{prediction | metadata: Map.put(metadata, :lm_usage, usage)}

  @doc "Converts an example into a prediction, preserving fields and applying prediction options."
  def from_example(%Imp.Example{} = example, opts \\ []),
    do: new(Imp.Example.to_map(example), opts)

  defp key!(key), do: Imp.FieldMap.key!(key, "Imp.Prediction")
end

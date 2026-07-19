defmodule Imp.Signature do
  @moduledoc """
  Input/output contract for an Imp program.

  A signature names the fields a program receives and the fields it must
  produce. It is the center of the Imp programming model: adapters render it
  for models, schemas validate structured outputs, optimizers mutate programs
  around it, and persistence stores it as plain data.

  The compact string form is ideal for most code:

      iex> signature = Imp.Signature.new("question: string -> answer: short_span")
      iex> Imp.Signature.input_names(signature)
      [:question]
      iex> Imp.Signature.output_names(signature)
      [:answer]
      iex> Imp.Signature.json_schema(signature)["properties"]["answer"]["x-imp-answerShape"]
      :short_span

  Use the map form when constraints or metadata should be explicit data:

      iex> signature =
      ...>   Imp.Signature.new(%{
      ...>     inputs: [:text],
      ...>     outputs: [
      ...>       %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}}
      ...>     ]
      ...>   })
      iex> Imp.Signature.json_schema(signature)["properties"]["sentiment"]["enum"]
      ["positive", "negative"]
  """

  alias Imp.Signature.Field

  @enforce_keys [:inputs, :outputs]
  defstruct [:instructions, inputs: [], outputs: [], metadata: %{}]

  @type t :: %__MODULE__{
          instructions: String.t(),
          inputs: [Field.t()],
          outputs: [Field.t()],
          metadata: map()
        }

  @doc """
  Builds a signature from a compact spec string, map, or existing signature.

  Strings use the `inputs -> outputs` grammar and may include field types,
  descriptions, enums, and answer-shape aliases. Maps accept atom or string keys
  and are useful when signatures are loaded from JSON or built from structured
  configuration.
  """
  def new(spec, instructions \\ nil)

  def new(%__MODULE__{} = signature, _instructions), do: signature

  def new(spec, instructions) when is_binary(spec) do
    {inputs, outputs} = Imp.Signature.Parser.parse(spec)

    %__MODULE__{
      inputs: inputs,
      outputs: outputs,
      instructions: resolve_instructions(instructions, inputs, outputs)
    }
  end

  def new(%{} = attrs, instructions) do
    inputs = Map.get(attrs, :inputs, Map.get(attrs, "inputs"))
    outputs = Map.get(attrs, :outputs, Map.get(attrs, "outputs"))

    if is_nil(inputs) or is_nil(outputs) do
      raise ArgumentError,
            "signature map requires :inputs/:outputs or \"inputs\"/\"outputs\" keys"
    end

    inputs = build_fields!(inputs, :input, "Imp.Signature.new/2 :inputs")
    outputs = build_fields!(outputs, :output, "Imp.Signature.new/2 :outputs")

    %__MODULE__{
      inputs: inputs,
      outputs: outputs,
      instructions:
        resolve_instructions(
          instructions || Map.get(attrs, :instructions, Map.get(attrs, "instructions")),
          inputs,
          outputs
        ),
      metadata: Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    }
  end

  @doc "Returns a signature, constructing one when given a supported spec value."
  def ensure(value), do: new(value)

  @doc "Returns input field names in declaration order."
  def input_names(%__MODULE__{inputs: fields}), do: Enum.map(fields, & &1.name)

  @doc "Returns output field names in declaration order."
  def output_names(%__MODULE__{outputs: fields}), do: Enum.map(fields, & &1.name)

  @doc "Returns all field names, inputs first and outputs second."
  def field_names(%__MODULE__{} = signature),
    do: input_names(signature) ++ output_names(signature)

  @doc """
  Appends one or more fields to the input or output side of a signature.

  `fields` accepts the same field shapes as `Imp.Signature.Field.new/2`.
  """
  def extend(%__MODULE__{} = signature, fields, kind) when kind in [:input, :output] do
    parsed = build_fields!(List.wrap(fields), kind, "Imp.Signature.extend/3 fields")

    case kind do
      :input -> %{signature | inputs: signature.inputs ++ parsed}
      :output -> %{signature | outputs: signature.outputs ++ parsed}
    end
  end

  def extend(%__MODULE__{}, _fields, kind) do
    raise ArgumentError,
          "Imp.Signature.extend/3 expects kind to be :input or :output, got: #{inspect(kind)}"
  end

  @doc """
  Prepends an output field.

  Chain-of-thought style modules use this to add a `:reasoning` field before
  the task outputs while preserving the original contract.
  """
  def prepend_output(%__MODULE__{} = signature, field),
    do: %{signature | outputs: [Field.new(field, :output) | signature.outputs]}

  @doc """
  Returns a compact `inputs -> outputs` display string.

  This is intentionally a readable summary, not a lossless serialization. Use
  `dump/1` when types, constraints, instructions, and metadata must round-trip.
  """
  def to_spec(%__MODULE__{} = signature),
    do: "#{join_names(signature.inputs)} -> #{join_names(signature.outputs)}"

  @doc "Serializes a signature to JSON-friendly data."
  def dump(%__MODULE__{} = signature) do
    %{
      "instructions" => signature.instructions,
      "inputs" => Enum.map(signature.inputs, &Field.dump/1),
      "outputs" => Enum.map(signature.outputs, &Field.dump/1),
      "metadata" => signature.metadata
    }
  end

  @doc "Exports output fields as a JSON-schema-shaped object."
  def json_schema(%__MODULE__{} = signature),
    do: Imp.Schema.json_schema(signature.outputs)

  @doc "Loads a signature produced by `dump/1`."
  def load(%{"inputs" => inputs, "outputs" => outputs} = state) do
    %__MODULE__{
      inputs: build_fields!(inputs, :input, "Imp.Signature.load/1 \"inputs\""),
      outputs: build_fields!(outputs, :output, "Imp.Signature.load/1 \"outputs\""),
      instructions: Map.get(state, "instructions"),
      metadata: Map.get(state, "metadata", %{})
    }
  end

  def load(state) do
    raise ArgumentError,
          "Imp.Signature.load/1 expects a map with \"inputs\" and \"outputs\", got: #{inspect(state)}"
  end

  # DSPy `make_signature` treats an empty-string `__doc__` (and a missing one) as
  # absent and substitutes `_default_instructions`. Elixir treats only nil/false
  # as falsy, so a bare "" survived. Match DSPy: nil OR exactly "" -> default.
  # Whitespace-only instructions are NOT replaced (DSPy keeps them; they render
  # empty after cleandoc), so only the empty string is special-cased (dee-wrx5).
  defp resolve_instructions(nil, inputs, outputs), do: default_instructions(inputs, outputs)
  defp resolve_instructions("", inputs, outputs), do: default_instructions(inputs, outputs)
  defp resolve_instructions(instructions, _inputs, _outputs), do: instructions

  defp default_instructions(inputs, outputs) do
    input_names = inputs |> Enum.map(&"`#{&1.name}`") |> Enum.join(", ")
    output_names = outputs |> Enum.map(&"`#{&1.name}`") |> Enum.join(", ")
    "Given the fields #{input_names}, produce the fields #{output_names}."
  end

  defp build_fields!(fields, kind, context) do
    if Enumerable.impl_for(fields) do
      Enum.map(fields, &Field.new(&1, kind))
    else
      raise ArgumentError, "#{context} expects an enumerable of fields, got: #{inspect(fields)}"
    end
  rescue
    error in ArgumentError ->
      reraise ArgumentError, [message: "#{context}: #{Exception.message(error)}"], __STACKTRACE__
  end

  defp join_names(fields), do: fields |> Enum.map(&to_string(&1.name)) |> Enum.join(", ")
end

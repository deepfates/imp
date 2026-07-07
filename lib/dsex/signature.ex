defmodule DSEx.Signature do
  @moduledoc """
  Input/output contract for a DSEx module.
  """

  alias DSEx.Signature.Field

  @enforce_keys [:inputs, :outputs]
  defstruct [:instructions, inputs: [], outputs: [], metadata: %{}]

  @type t :: %__MODULE__{
          instructions: String.t(),
          inputs: [Field.t()],
          outputs: [Field.t()],
          metadata: map()
        }

  def new(spec, instructions \\ nil)

  def new(%__MODULE__{} = signature, _instructions), do: signature

  def new(spec, instructions) when is_binary(spec) do
    {inputs, outputs} = DSEx.Signature.Parser.parse(spec)

    %__MODULE__{
      inputs: inputs,
      outputs: outputs,
      instructions: instructions || default_instructions(inputs, outputs)
    }
  end

  def new(%{} = attrs, instructions) do
    inputs = Map.get(attrs, :inputs, Map.get(attrs, "inputs"))
    outputs = Map.get(attrs, :outputs, Map.get(attrs, "outputs"))

    if is_nil(inputs) or is_nil(outputs) do
      raise ArgumentError,
            "signature map requires :inputs/:outputs or \"inputs\"/\"outputs\" keys"
    end

    inputs = Enum.map(inputs, &Field.new(&1, :input))
    outputs = Enum.map(outputs, &Field.new(&1, :output))

    %__MODULE__{
      inputs: inputs,
      outputs: outputs,
      instructions:
        instructions || Map.get(attrs, :instructions, Map.get(attrs, "instructions")) ||
          default_instructions(inputs, outputs),
      metadata: Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    }
  end

  def ensure(value), do: new(value)
  def input_names(%__MODULE__{inputs: fields}), do: Enum.map(fields, & &1.name)
  def output_names(%__MODULE__{outputs: fields}), do: Enum.map(fields, & &1.name)

  def field_names(%__MODULE__{} = signature),
    do: input_names(signature) ++ output_names(signature)

  def extend(%__MODULE__{} = signature, fields, kind) when kind in [:input, :output] do
    parsed = Enum.map(List.wrap(fields), &Field.new(&1, kind))

    case kind do
      :input -> %{signature | inputs: signature.inputs ++ parsed}
      :output -> %{signature | outputs: signature.outputs ++ parsed}
    end
  end

  def prepend_output(%__MODULE__{} = signature, field),
    do: %{signature | outputs: [Field.new(field, :output) | signature.outputs]}

  def to_spec(%__MODULE__{} = signature),
    do: "#{join_names(signature.inputs)} -> #{join_names(signature.outputs)}"

  def dump(%__MODULE__{} = signature) do
    %{
      "instructions" => signature.instructions,
      "inputs" => Enum.map(signature.inputs, &Field.dump/1),
      "outputs" => Enum.map(signature.outputs, &Field.dump/1),
      "metadata" => signature.metadata
    }
  end

  def json_schema(%__MODULE__{} = signature),
    do: DSEx.Schema.json_schema(signature.outputs)

  def load(%{"inputs" => inputs, "outputs" => outputs} = state) do
    %__MODULE__{
      inputs: Enum.map(inputs, &Field.load/1),
      outputs: Enum.map(outputs, &Field.load/1),
      instructions: Map.get(state, "instructions"),
      metadata: Map.get(state, "metadata", %{})
    }
  end

  defp default_instructions(inputs, outputs) do
    input_names = inputs |> Enum.map(&"`#{&1.name}`") |> Enum.join(", ")
    output_names = outputs |> Enum.map(&"`#{&1.name}`") |> Enum.join(", ")
    "Given the fields #{input_names}, produce the fields #{output_names}."
  end

  defp join_names(fields), do: fields |> Enum.map(&to_string(&1.name)) |> Enum.join(", ")
end

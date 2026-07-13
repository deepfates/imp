defmodule DSEx.Predict.ProgramOfThought do
  @moduledoc "Program-of-thought module that asks for code/tool actions then evaluates through safe runtime hooks."

  @behaviour DSEx.Module

  defstruct [:signature, :predict, output_field: :answer]

  @option_schema [
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    output_field: [
      type: {:custom, __MODULE__, :validate_output_field, []},
      default: nil
    ]
  ]

  def validate_output_field(nil), do: {:ok, nil}
  def validate_output_field(field), do: DSEx.FieldSelector.validate_name(field)

  def new(signature, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.ProgramOfThought.new/2")
    original = DSEx.Signature.ensure(signature)

    program_signature = %{
      original
      | outputs: [
          DSEx.Signature.Field.new(
            %{
              name: :program,
              type: :any,
              desc: "Safe Elixir expression to evaluate",
              metadata: %{optional: true}
            },
            :output
          ),
          DSEx.Signature.Field.new(
            %{
              name: :tool,
              desc: "Optional tool name to call before the next program step",
              metadata: %{optional: true}
            },
            :output
          ),
          DSEx.Signature.Field.new(
            %{
              name: :arguments,
              type: :any,
              desc:
                "Optional raw tool arguments; maps and provider JSON strings are both accepted",
              metadata: %{optional: true}
            },
            :output
          )
        ]
    }

    %__MODULE__{
      signature: original,
      predict: DSEx.Predict.Predict.new(program_signature, opts),
      output_field: resolve_output_field!(original, opts[:output_field])
    }
  end

  @impl true
  def call(%__MODULE__{} = pot, inputs) do
    with {:ok, prediction} <- predict_step(pot, inputs),
         program when is_binary(program) <- DSEx.Prediction.get(prediction, :program),
         {:ok, value} <- DSEx.Sandbox.eval(program, inputs),
         {:ok, prediction} <- project_outputs(pot, prediction, value) do
      {:ok, prediction}
    else
      nil -> {:error, :missing_program}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_generated_program, other}}
    end
  end

  @doc false
  def predict_step(%__MODULE__{} = pot, inputs) do
    DSEx.Predict.Predict.call(pot.predict, inputs)
  end

  @doc false
  def project_outputs(
        %__MODULE__{signature: %{outputs: [_field]}, output_field: output_field},
        %DSEx.Prediction{} = prediction,
        value
      ) do
    {:ok, DSEx.Prediction.put(prediction, output_field, value)}
  end

  def project_outputs(
        %__MODULE__{signature: %{outputs: outputs}},
        %DSEx.Prediction{} = prediction,
        value
      )
      when is_map(value) do
    with {:ok, fields} <- normalize_output_fields(outputs, value),
         :ok <- validate_output_fields(outputs, fields) do
      prediction =
        Enum.reduce(outputs, prediction, fn field, acc ->
          DSEx.Prediction.put(acc, field.name, Map.fetch!(fields, field.name))
        end)

      {:ok, prediction}
    end
  end

  def project_outputs(%__MODULE__{signature: signature}, %DSEx.Prediction{}, value) do
    {:error,
     {:invalid_program_outputs, {:expected_map, DSEx.Signature.output_names(signature), value}}}
  end

  defp normalize_output_fields(outputs, value) do
    {fields, unknown, duplicates} =
      Enum.reduce(value, {%{}, [], []}, fn {key, field_value}, {fields, unknown, duplicates} ->
        case declared_output_name(outputs, key) do
          nil ->
            {fields, [key | unknown], duplicates}

          name when is_map_key(fields, name) ->
            {fields, unknown, [name | duplicates]}

          name ->
            {Map.put(fields, name, field_value), unknown, duplicates}
        end
      end)

    missing = outputs |> Enum.map(& &1.name) |> Enum.reject(&Map.has_key?(fields, &1))

    cond do
      unknown != [] -> {:error, {:unknown_output_fields, stable_keys(unknown)}}
      duplicates != [] -> {:error, {:duplicate_output_fields, stable_keys(duplicates)}}
      missing != [] -> {:error, {:missing_output_fields, missing}}
      true -> {:ok, fields}
    end
  end

  defp declared_output_name(outputs, key) when is_atom(key) or is_binary(key) do
    Enum.find_value(outputs, fn field ->
      if field.name == key or to_string(field.name) == to_string(key), do: field.name
    end)
  end

  defp declared_output_name(_outputs, _key), do: nil

  defp validate_output_fields(outputs, fields) do
    case DSEx.Schema.validate_fields(outputs, fields) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_output_fields, errors}}
    end
  end

  defp stable_keys(keys), do: keys |> Enum.uniq() |> Enum.sort_by(&inspect/1)

  defp resolve_output_field!(signature, nil) do
    signature
    |> output_names()
    |> List.first()
  end

  defp resolve_output_field!(signature, field) do
    outputs = output_names(signature)

    if field in outputs do
      field
    else
      raise ArgumentError,
            "DSEx.Predict.ProgramOfThought.new/2 :output_field must be one of the signature outputs; got #{inspect(field)} for outputs #{inspect(outputs)}"
    end
  end

  defp output_names(signature), do: Enum.map(signature.outputs, & &1.name)
end

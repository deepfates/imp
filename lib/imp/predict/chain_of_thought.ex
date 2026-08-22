defmodule Imp.Predict.ChainOfThought do
  @moduledoc "Predict variant that asks for a `:reasoning` field before task outputs."

  @behaviour Imp.Module

  defstruct [:predict]

  def new(signature, opts \\ []) do
    {rationale_field, opts} = Keyword.pop(opts, :rationale_field)
    {rationale_field_type, opts} = Keyword.pop(opts, :rationale_field_type, :string)

    rationale_field =
      case rationale_field do
        nil ->
          %{
            name: :reasoning,
            desc: "${reasoning}",
            type: rationale_field_type
          }

        %Imp.Signature.Field{} = field ->
          %{field | name: :reasoning, kind: :output}

        field when is_map(field) or is_list(field) ->
          field
          |> Map.new()
          |> Map.put(:name, :reasoning)

        other ->
          raise ArgumentError,
                "Imp.chain_of_thought/2 :rationale_field must be a field map, keyword list, or Signature.Field; got: #{inspect(other)}"
      end

    signature =
      signature
      |> Imp.Signature.ensure()
      # DSPy 3.3.1 keeps the legacy default as `str`; callers opt into its
      # native-capable Reasoning type through `rationale_field_type`.
      |> Imp.Signature.prepend_output(rationale_field)

    %__MODULE__{predict: Imp.Predict.Predict.new(signature, opts)}
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: Imp.Predict.Predict.call(predict, inputs)
end

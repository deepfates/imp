defmodule Imp.Predict.ChainOfThought do
  @moduledoc "Predict variant that asks for a `:reasoning` field before task outputs."

  @behaviour Imp.Module

  defstruct [:predict]

  @option_schema Imp.Predict.Predict.option_schema() ++
                   [
                     rationale_field: [
                       type:
                         {:or,
                          [
                            nil,
                            {:struct, Imp.Signature.Field},
                            {:map, :any, :any},
                            :keyword_list
                          ]},
                       doc:
                         "The reasoning field, as a field map, keyword list or " <>
                           "`Imp.Signature.Field`; its name is always `:reasoning`. " <>
                           "When absent or `nil`, a field of `:rationale_field_type`."
                     ],
                     rationale_field_type: [
                       type: :any,
                       default: :string,
                       doc:
                         "The type of the default reasoning field; `:reasoning` asks a " <>
                           "model that reasons natively for its own reasoning."
                     ]
                   ]

  @doc """
  Builds a program that asks for `:reasoning` before the signature's outputs.

  Takes `Imp.Predict.Predict.new/2`'s options and two of its own. An unknown
  option raises `ArgumentError`.

  ## Options

  #{NimbleOptions.docs(@option_schema)}
  """
  def new(signature, opts \\ []) do
    Imp.Predict.Predict.validate_options!(
      opts,
      @option_schema,
      "Imp.Predict.ChainOfThought.new/2"
    )

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
      end

    signature =
      signature
      |> Imp.Signature.ensure()
      # The reasoning field defaults to a plain string; `:rationale_field_type`
      # opts into the native-capable reasoning type.
      |> Imp.Signature.prepend_output(rationale_field)

    %__MODULE__{predict: Imp.Predict.Predict.new(signature, opts)}
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: Imp.Predict.Predict.call(predict, inputs)
end

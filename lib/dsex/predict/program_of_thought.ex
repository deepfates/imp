defmodule DSEx.Predict.ProgramOfThought do
  @moduledoc "Program-of-thought module that asks for code/tool actions then evaluates through safe runtime hooks."

  @behaviour DSEx.Module

  defstruct [:predict, output_field: :answer]

  @option_schema [
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    output_field: [
      type: {:custom, DSEx.FieldSelector, :validate_name, []},
      default: :answer
    ]
  ]

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
      predict: DSEx.Predict.Predict.new(program_signature, opts),
      output_field: opts[:output_field]
    }
  end

  @impl true
  def call(%__MODULE__{} = pot, inputs) do
    with {:ok, prediction} <- predict_step(pot, inputs),
         program when is_binary(program) <- DSEx.Prediction.get(prediction, :program),
         {:ok, value} <- DSEx.Sandbox.eval(program, inputs) do
      {:ok, prediction |> DSEx.Prediction.put(pot.output_field, value)}
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
end

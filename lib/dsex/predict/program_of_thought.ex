defmodule DSEx.Predict.ProgramOfThought do
  @moduledoc "Program-of-thought module that asks for code/expression then evaluates it in `DSEx.Sandbox`."

  @behaviour DSEx.Module

  defstruct [:predict, output_field: :answer]

  def new(signature, opts \\ []) do
    original = DSEx.Signature.ensure(signature)

    program_signature = %{
      original
      | outputs: [
          DSEx.Signature.Field.new(
            %{name: :program, desc: "Arithmetic expression to evaluate"},
            :output
          )
        ]
    }

    %__MODULE__{
      predict: DSEx.Predict.Predict.new(program_signature, opts),
      output_field: Keyword.get(opts, :output_field, :answer)
    }
  end

  @impl true
  def call(%__MODULE__{} = pot, inputs) do
    with {:ok, prediction} <- DSEx.Predict.Predict.call(pot.predict, inputs),
         program when is_binary(program) <- DSEx.Prediction.get(prediction, :program),
         {:ok, value} <- DSEx.Sandbox.eval(program, inputs) do
      {:ok, prediction |> DSEx.Prediction.put(pot.output_field, value)}
    else
      nil -> {:error, :missing_program}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_program, other}}
    end
  end
end

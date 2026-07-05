defmodule DSPy.Predict.ProgramOfThought do
  @moduledoc "Program-of-thought module that asks for code/expression then evaluates it in `DSPy.Sandbox`."

  @behaviour DSPy.Module

  defstruct [:predict, output_field: :answer]

  def new(signature, opts \\ []) do
    original = DSPy.Signature.ensure(signature)

    program_signature = %{
      original
      | outputs: [
          DSPy.Signature.Field.new(
            %{name: :program, desc: "Arithmetic expression to evaluate"},
            :output
          )
        ]
    }

    %__MODULE__{
      predict: DSPy.Predict.Predict.new(program_signature, opts),
      output_field: Keyword.get(opts, :output_field, :answer)
    }
  end

  @impl true
  def call(%__MODULE__{} = pot, inputs) do
    with {:ok, prediction} <- DSPy.Predict.Predict.call(pot.predict, inputs),
         program when is_binary(program) <- DSPy.Prediction.get(prediction, :program),
         {:ok, value} <- DSPy.Sandbox.eval(program, inputs) do
      {:ok, prediction |> DSPy.Prediction.put(pot.output_field, value)}
    else
      nil -> {:error, :missing_program}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_program, other}}
    end
  end
end

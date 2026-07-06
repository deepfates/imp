defmodule Dachshund.Predict.ProgramOfThought do
  @moduledoc "Program-of-thought module that asks for code/expression then evaluates it in `Dachshund.Sandbox`."

  @behaviour Dachshund.Module

  defstruct [:predict, output_field: :answer]

  def new(signature, opts \\ []) do
    original = Dachshund.Signature.ensure(signature)

    program_signature = %{
      original
      | outputs: [
          Dachshund.Signature.Field.new(
            %{name: :program, desc: "Arithmetic expression to evaluate"},
            :output
          )
        ]
    }

    %__MODULE__{
      predict: Dachshund.Predict.Predict.new(program_signature, opts),
      output_field: Keyword.get(opts, :output_field, :answer)
    }
  end

  @impl true
  def call(%__MODULE__{} = pot, inputs) do
    with {:ok, prediction} <- Dachshund.Predict.Predict.call(pot.predict, inputs),
         program when is_binary(program) <- Dachshund.Prediction.get(prediction, :program),
         {:ok, value} <- Dachshund.Sandbox.eval(program, inputs) do
      {:ok, prediction |> Dachshund.Prediction.put(pot.output_field, value)}
    else
      nil -> {:error, :missing_program}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_program, other}}
    end
  end
end

defmodule DSPy.Predict.ChainOfThought do
  @moduledoc "Predict variant that asks for a `:reasoning` field before task outputs."

  @behaviour DSPy.Module

  defstruct [:predict]

  def new(signature, opts \\ []) do
    signature =
      signature
      |> DSPy.Signature.ensure()
      |> DSPy.Signature.prepend_output(%{
        name: :reasoning,
        desc: "Reasoning before the final answer"
      })

    %__MODULE__{predict: DSPy.Predict.Predict.new(signature, opts)}
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs), do: DSPy.Predict.Predict.call(predict, inputs)
end

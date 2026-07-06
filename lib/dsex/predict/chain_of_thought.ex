defmodule DSEx.Predict.ChainOfThought do
  @moduledoc "Predict variant that asks for a `:reasoning` field before task outputs."

  @behaviour DSEx.Module

  defstruct [:predict]

  def new(signature, opts \\ []) do
    signature =
      signature
      |> DSEx.Signature.ensure()
      |> DSEx.Signature.prepend_output(%{
        name: :reasoning,
        desc: "Reasoning before the final answer"
      })

    %__MODULE__{predict: DSEx.Predict.Predict.new(signature, opts)}
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: DSEx.Predict.Predict.call(predict, inputs)
end

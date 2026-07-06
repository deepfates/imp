defmodule Dachshund.Predict.ChainOfThought do
  @moduledoc "Predict variant that asks for a `:reasoning` field before task outputs."

  @behaviour Dachshund.Module

  defstruct [:predict]

  def new(signature, opts \\ []) do
    signature =
      signature
      |> Dachshund.Signature.ensure()
      |> Dachshund.Signature.prepend_output(%{
        name: :reasoning,
        desc: "Reasoning before the final answer"
      })

    %__MODULE__{predict: Dachshund.Predict.Predict.new(signature, opts)}
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: Dachshund.Predict.Predict.call(predict, inputs)
end

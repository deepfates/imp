defmodule Imp.Predict.ChainOfThought do
  @moduledoc "Predict variant that asks for a `:reasoning` field before task outputs."

  @behaviour Imp.Module

  defstruct [:predict]

  def new(signature, opts \\ []) do
    signature =
      signature
      |> Imp.Signature.ensure()
      |> Imp.Signature.prepend_output(%{
        name: :reasoning,
        desc: "Work through the problem step by step before giving the final answer"
      })

    %__MODULE__{predict: Imp.Predict.Predict.new(signature, opts)}
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: Imp.Predict.Predict.call(predict, inputs)
end

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
        # DSPy 3.2.1 ChainOfThought sets the reasoning field description to the
        # "${reasoning}" placeholder, which its ChatAdapter renders as an empty
        # description. Match it exactly for prompt parity (epic dee-8zev).
        desc: "${reasoning}"
      })

    %__MODULE__{predict: Imp.Predict.Predict.new(signature, opts)}
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: Imp.Predict.Predict.call(predict, inputs)
end

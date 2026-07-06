defmodule DSEx.Evaluate.SemanticF1 do
  @moduledoc "LM-backed semantic F1 evaluator translated as an executable DSEx module."

  @behaviour DSEx.Module

  defstruct [:predict]

  def new(opts \\ []) do
    %__MODULE__{
      predict:
        DSEx.Predict.ChainOfThought.new(
          "question, ground_truth, system_response -> precision: number, recall: number, f1: number",
          opts
        )
    }
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: DSEx.Predict.ChainOfThought.call(predict, inputs)
end

defmodule DSEx.Evaluate.CompleteAndGrounded do
  @moduledoc "LM-backed completeness and groundedness evaluator."

  @behaviour DSEx.Module

  defstruct [:predict]

  def new(opts \\ []) do
    %__MODULE__{
      predict:
        DSEx.Predict.ChainOfThought.new(
          "question, context, answer -> completeness: number, groundedness: number",
          opts
        )
    }
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: DSEx.Predict.ChainOfThought.call(predict, inputs)
end

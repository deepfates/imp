defmodule DSPy.Evaluate.SemanticF1 do
  @moduledoc "LM-backed semantic F1 evaluator translated as an executable DSPy module."

  @behaviour DSPy.Module

  defstruct [:predict]

  def new(opts \\ []) do
    %__MODULE__{
      predict:
        DSPy.Predict.ChainOfThought.new(
          "question, ground_truth, system_response -> precision, recall, f1",
          opts
        )
    }
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: DSPy.Predict.ChainOfThought.call(predict, inputs)
end

defmodule DSPy.Evaluate.CompleteAndGrounded do
  @moduledoc "LM-backed completeness and groundedness evaluator."

  @behaviour DSPy.Module

  defstruct [:predict]

  def new(opts \\ []) do
    %__MODULE__{
      predict:
        DSPy.Predict.ChainOfThought.new(
          "question, context, answer -> completeness, groundedness",
          opts
        )
    }
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: DSPy.Predict.ChainOfThought.call(predict, inputs)
end

defmodule Dachshund.Evaluate.SemanticF1 do
  @moduledoc "LM-backed semantic F1 evaluator translated as an executable Dachshund module."

  @behaviour Dachshund.Module

  defstruct [:predict]

  def new(opts \\ []) do
    %__MODULE__{
      predict:
        Dachshund.Predict.ChainOfThought.new(
          "question, ground_truth, system_response -> precision, recall, f1",
          opts
        )
    }
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: Dachshund.Predict.ChainOfThought.call(predict, inputs)
end

defmodule Dachshund.Evaluate.CompleteAndGrounded do
  @moduledoc "LM-backed completeness and groundedness evaluator."

  @behaviour Dachshund.Module

  defstruct [:predict]

  def new(opts \\ []) do
    %__MODULE__{
      predict:
        Dachshund.Predict.ChainOfThought.new(
          "question, context, answer -> completeness, groundedness",
          opts
        )
    }
  end

  @impl true
  def call(%__MODULE__{predict: predict}, inputs),
    do: Dachshund.Predict.ChainOfThought.call(predict, inputs)
end

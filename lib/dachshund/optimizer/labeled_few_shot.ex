defmodule Dachshund.Optimizer.LabeledFewShot do
  @moduledoc "Compile a predictor by attaching the first labeled examples as demos."

  defstruct k: 4

  def new(opts \\ []), do: %__MODULE__{k: Keyword.get(opts, :k, 4)}

  def compile(%__MODULE__{k: k}, program, trainset) do
    demos = Enum.take(trainset, k)

    case program do
      %Dachshund.Predict.Predict{} ->
        Dachshund.Predict.Predict.with_demos(program, demos)

      %Dachshund.Predict.ChainOfThought{predict: predict} ->
        %{program | predict: Dachshund.Predict.Predict.with_demos(predict, demos)}

      other ->
        other
    end
  end
end

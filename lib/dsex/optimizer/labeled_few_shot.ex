defmodule DSEx.Optimizer.LabeledFewShot do
  @moduledoc "Compile a predictor by attaching the first labeled examples as demos."

  defstruct k: 4

  def new(opts \\ []), do: %__MODULE__{k: Keyword.get(opts, :k, 4)}

  def compile(%__MODULE__{k: k}, program, trainset) do
    demos = Enum.take(trainset, k)

    case program do
      %DSEx.Predict.Predict{} ->
        DSEx.Predict.Predict.with_demos(program, demos)

      %DSEx.Predict.ChainOfThought{predict: predict} ->
        %{program | predict: DSEx.Predict.Predict.with_demos(predict, demos)}

      other ->
        other
    end
  end
end

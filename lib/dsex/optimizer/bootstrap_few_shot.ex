defmodule DSEx.Optimizer.BootstrapFewShot do
  @moduledoc """
  Compile a predictor by selecting successful demonstrations from a trainset.
  """

  defstruct [:metric, max_bootstrapped_demos: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      max_bootstrapped_demos: Keyword.get(opts, :max_bootstrapped_demos, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    demos =
      trainset
      |> Enum.filter(fn example ->
        inputs = example |> DSEx.Example.inputs() |> DSEx.Example.to_map()

        case program.__struct__.call(program, inputs) do
          {:ok, prediction} -> optimizer.metric.(example, prediction) |> DSEx.Metrics.pass?()
          {:error, _reason} -> false
        end
      end)
      |> Enum.take(optimizer.max_bootstrapped_demos)

    put_demos(program, demos)
  end

  defp put_demos(%DSEx.Predict.Predict{} = program, demos),
    do: DSEx.Predict.Predict.with_demos(program, demos)

  defp put_demos(%DSEx.Predict.ChainOfThought{predict: predict} = program, demos),
    do: %{program | predict: DSEx.Predict.Predict.with_demos(predict, demos)}

  defp put_demos(program, _demos), do: program
end

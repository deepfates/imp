defmodule Dachshund.Optimizer.BootstrapFewShot do
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
        inputs = example |> Dachshund.Example.inputs() |> Dachshund.Example.to_map()

        case program.__struct__.call(program, inputs) do
          {:ok, prediction} -> truthy?(optimizer.metric.(example, prediction))
          {:error, _reason} -> false
        end
      end)
      |> Enum.take(optimizer.max_bootstrapped_demos)

    put_demos(program, demos)
  end

  defp put_demos(%Dachshund.Predict.Predict{} = program, demos),
    do: Dachshund.Predict.Predict.with_demos(program, demos)

  defp put_demos(%Dachshund.Predict.ChainOfThought{predict: predict} = program, demos),
    do: %{program | predict: Dachshund.Predict.Predict.with_demos(predict, demos)}

  defp put_demos(program, _demos), do: program
  defp truthy?(value), do: value in [true, 1, 1.0] or (is_number(value) and value > 0)
end

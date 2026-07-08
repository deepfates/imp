defmodule DSEx.Optimizer.BootstrapFinetune do
  @moduledoc "Creates provider training jobs from bootstrapped demonstrations."

  defstruct [:metric, :trainer, max_demos: 32]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      trainer: Keyword.get(opts, :trainer),
      max_demos: non_negative_integer(Keyword.get(opts, :max_demos, 32))
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    boot =
      DSEx.Optimizer.BootstrapFewShot.new(optimizer.metric,
        max_bootstrapped_demos: optimizer.max_demos
      )

    compiled = DSEx.Optimizer.BootstrapFewShot.compile(boot, program, trainset)
    demos = get_demos(compiled)
    lm = get_lm(compiled)

    case optimizer.trainer do
      nil ->
        %{program: compiled, error: :trainer_required}

      trainer ->
        case DSEx.Clients.Trainer.finetune(trainer, lm || %{}, demos, []) do
          {:ok, job} -> %{program: compiled, job: job}
          {:error, reason} -> %{program: compiled, error: reason}
        end
    end
  end

  defp get_demos(%DSEx.Predict.Predict{demos: demos}), do: demos
  defp get_demos(%DSEx.Predict.ChainOfThought{predict: predict}), do: get_demos(predict)
  defp get_demos(_program), do: []

  defp get_lm(%DSEx.Predict.Predict{lm: lm}), do: lm
  defp get_lm(%DSEx.Predict.ChainOfThought{predict: predict}), do: get_lm(predict)
  defp get_lm(_program), do: nil

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0
end

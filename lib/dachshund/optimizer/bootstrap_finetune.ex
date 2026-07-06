defmodule Dachshund.Optimizer.BootstrapFinetune do
  @moduledoc "Creates provider training jobs from bootstrapped demonstrations."

  defstruct [:metric, trainer: Dachshund.Clients.LocalTrainer, max_demos: 32]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      trainer: Keyword.get(opts, :trainer, Dachshund.Clients.LocalTrainer),
      max_demos: Keyword.get(opts, :max_demos, 32)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    boot =
      Dachshund.Optimizer.BootstrapFewShot.new(optimizer.metric,
        max_bootstrapped_demos: optimizer.max_demos
      )

    compiled = Dachshund.Optimizer.BootstrapFewShot.compile(boot, program, trainset)
    demos = get_demos(compiled)
    lm = get_lm(compiled)

    case Dachshund.Clients.Trainer.finetune(optimizer.trainer, lm || %{}, demos, []) do
      {:ok, job} -> %{program: compiled, job: job}
      {:error, reason} -> %{program: compiled, error: reason}
    end
  end

  defp get_demos(%Dachshund.Predict.Predict{demos: demos}), do: demos
  defp get_demos(%Dachshund.Predict.ChainOfThought{predict: predict}), do: get_demos(predict)
  defp get_demos(_program), do: []

  defp get_lm(%Dachshund.Predict.Predict{lm: lm}), do: lm
  defp get_lm(%Dachshund.Predict.ChainOfThought{predict: predict}), do: get_lm(predict)
  defp get_lm(_program), do: nil
end

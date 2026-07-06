defmodule DSEx.Optimizer.BootstrapFinetune do
  @moduledoc "Creates provider training jobs from bootstrapped demonstrations."

  defstruct [:metric, trainer: DSEx.Clients.LocalTrainer, max_demos: 32]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      trainer: Keyword.get(opts, :trainer, DSEx.Clients.LocalTrainer),
      max_demos: Keyword.get(opts, :max_demos, 32)
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

    case DSEx.Clients.Trainer.finetune(optimizer.trainer, lm || %{}, demos, []) do
      {:ok, job} -> %{program: compiled, job: job}
      {:error, reason} -> %{program: compiled, error: reason}
    end
  end

  defp get_demos(%DSEx.Predict.Predict{demos: demos}), do: demos
  defp get_demos(%DSEx.Predict.ChainOfThought{predict: predict}), do: get_demos(predict)
  defp get_demos(_program), do: []

  defp get_lm(%DSEx.Predict.Predict{lm: lm}), do: lm
  defp get_lm(%DSEx.Predict.ChainOfThought{predict: predict}), do: get_lm(predict)
  defp get_lm(_program), do: nil
end

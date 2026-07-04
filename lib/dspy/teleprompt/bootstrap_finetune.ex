defmodule DSPy.Teleprompt.BootstrapFinetune do
  @moduledoc "Creates provider training jobs from bootstrapped demonstrations."

  defstruct [:metric, trainer: DSPy.Clients.LocalTrainer, max_demos: 32]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      trainer: Keyword.get(opts, :trainer, DSPy.Clients.LocalTrainer),
      max_demos: Keyword.get(opts, :max_demos, 32)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    boot =
      DSPy.Teleprompt.BootstrapFewShot.new(optimizer.metric,
        max_bootstrapped_demos: optimizer.max_demos
      )

    compiled = DSPy.Teleprompt.BootstrapFewShot.compile(boot, program, trainset)
    demos = get_demos(compiled)
    lm = get_lm(compiled)

    case DSPy.Clients.Trainer.finetune(optimizer.trainer, lm || %{}, demos, []) do
      {:ok, job} -> %{program: compiled, job: job}
      {:error, reason} -> %{program: compiled, error: reason}
    end
  end

  defp get_demos(%DSPy.Predict.Predict{demos: demos}), do: demos
  defp get_demos(%DSPy.Predict.ChainOfThought{predict: predict}), do: get_demos(predict)
  defp get_demos(_program), do: []

  defp get_lm(%DSPy.Predict.Predict{lm: lm}), do: lm
  defp get_lm(%DSPy.Predict.ChainOfThought{predict: predict}), do: get_lm(predict)
  defp get_lm(_program), do: nil
end

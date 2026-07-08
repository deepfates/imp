defmodule DSEx.Optimizer.BootstrapFinetune do
  @moduledoc "Creates provider training jobs from bootstrapped demonstrations."

  defstruct [:metric, :trainer, max_demos: 32]

  @option_schema [
    trainer: [type: :any, default: nil],
    max_demos: [type: :non_neg_integer, default: 32]
  ]

  def new(metric, opts \\ []) do
    validate_metric!(metric)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.BootstrapFinetune.new/2")

    %__MODULE__{
      metric: metric,
      trainer: opts[:trainer],
      max_demos: opts[:max_demos]
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

  defp validate_metric!(metric) when is_function(metric, 2), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Optimizer.BootstrapFinetune.new/2 expects a metric function with arity 2; got: #{inspect(metric)}"
  end
end

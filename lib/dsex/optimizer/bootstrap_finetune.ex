defmodule DSEx.Optimizer.BootstrapFinetune do
  @moduledoc "Creates provider training jobs from bootstrapped demonstrations."

  defstruct [:metric, :trainer, max_demos: 32]

  @option_schema [
    trainer: [type: {:custom, DSEx.Clients.Trainer, :validate_provider, []}, default: nil],
    max_demos: [type: :non_neg_integer, default: 32]
  ]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(
      metric,
      2,
      "DSEx.Optimizer.BootstrapFinetune.new/2",
      "metric"
    )

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
    demos = DSEx.ProgramAccess.demos(compiled)
    lm = DSEx.ProgramAccess.lm(compiled)

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
end

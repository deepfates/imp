defmodule DSEx.Optimizer.GRPO do
  @moduledoc "Provider-neutral GRPO job builder for reinforcement-style training."

  defstruct [:reward_fn, :trainer]

  @option_schema [
    trainer: [type: {:custom, DSEx.Clients.Trainer, :validate_provider, []}, default: nil]
  ]

  def new(reward_fn, opts \\ []) do
    DSEx.FunctionContract.validate!(reward_fn, 1, "DSEx.Optimizer.GRPO.new/2", "reward")
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.GRPO.new/2")

    %__MODULE__{
      reward_fn: reward_fn,
      trainer: opts[:trainer]
    }
  end

  def compile(%__MODULE__{trainer: nil}, _program, _trainset), do: {:error, :trainer_required}

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    with :ok <- DSEx.Clients.Trainer.supports_method(optimizer.trainer, :grpo) do
      enriched =
        Enum.map(trainset, fn example ->
          reward = optimizer.reward_fn.(example)
          DSEx.Example.put(example, :reward, reward)
        end)

      lm = DSEx.ProgramAccess.lm(program) || %{}

      DSEx.Clients.Trainer.finetune(optimizer.trainer, lm, enriched, method: :grpo)
    end
  end
end

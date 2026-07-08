defmodule DSEx.Optimizer.GRPO do
  @moduledoc "Provider-neutral GRPO job builder for reinforcement-style training."

  defstruct [:reward_fn, :trainer]

  @option_schema [
    trainer: [type: :any, default: nil]
  ]

  def new(reward_fn, opts \\ []) do
    validate_reward_fn!(reward_fn)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.GRPO.new/2")

    %__MODULE__{
      reward_fn: reward_fn,
      trainer: opts[:trainer]
    }
  end

  def compile(%__MODULE__{trainer: nil}, _program, _trainset), do: {:error, :trainer_required}

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    enriched =
      Enum.map(trainset, fn example ->
        reward = optimizer.reward_fn.(example)
        DSEx.Example.put(example, :reward, reward)
      end)

    lm =
      case program do
        %DSEx.Predict.Predict{lm: lm} -> lm
        %DSEx.Predict.ChainOfThought{predict: %DSEx.Predict.Predict{lm: lm}} -> lm
        _ -> %{}
      end

    DSEx.Clients.Trainer.finetune(optimizer.trainer, lm, enriched, method: :grpo)
  end

  defp validate_reward_fn!(reward_fn) when is_function(reward_fn, 1), do: :ok

  defp validate_reward_fn!(reward_fn) do
    raise ArgumentError,
          "DSEx.Optimizer.GRPO.new/2 expects a reward function with arity 1; got: #{inspect(reward_fn)}"
  end
end

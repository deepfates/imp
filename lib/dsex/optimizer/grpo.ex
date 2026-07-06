defmodule DSEx.Optimizer.GRPO do
  @moduledoc "Provider-neutral GRPO job builder for reinforcement-style training."

  defstruct [:reward_fn, :trainer]

  def new(reward_fn, opts \\ []),
    do: %__MODULE__{
      reward_fn: reward_fn,
      trainer: Keyword.get(opts, :trainer)
    }

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
end

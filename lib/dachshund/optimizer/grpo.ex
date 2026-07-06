defmodule Dachshund.Optimizer.GRPO do
  @moduledoc "Provider-neutral GRPO job builder for reinforcement-style training."

  defstruct [:reward_fn, trainer: Dachshund.Clients.LocalTrainer]

  def new(reward_fn, opts \\ []),
    do: %__MODULE__{
      reward_fn: reward_fn,
      trainer: Keyword.get(opts, :trainer, Dachshund.Clients.LocalTrainer)
    }

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    enriched =
      Enum.map(trainset, fn example ->
        reward = optimizer.reward_fn.(example)
        Dachshund.Example.put(example, :reward, reward)
      end)

    lm =
      case program do
        %Dachshund.Predict.Predict{lm: lm} -> lm
        %Dachshund.Predict.ChainOfThought{predict: %Dachshund.Predict.Predict{lm: lm}} -> lm
        _ -> %{}
      end

    Dachshund.Clients.Trainer.finetune(optimizer.trainer, lm, enriched, method: :grpo)
  end
end

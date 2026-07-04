defmodule DSPy.Teleprompt.GRPO do
  @moduledoc "Provider-neutral GRPO job builder for reinforcement-style training."

  defstruct [:reward_fn, trainer: DSPy.Clients.LocalTrainer]

  def new(reward_fn, opts \\ []),
    do: %__MODULE__{
      reward_fn: reward_fn,
      trainer: Keyword.get(opts, :trainer, DSPy.Clients.LocalTrainer)
    }

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    enriched =
      Enum.map(trainset, fn example ->
        reward = optimizer.reward_fn.(example)
        DSPy.Example.put(example, :reward, reward)
      end)

    lm =
      case program do
        %DSPy.Predict.Predict{lm: lm} -> lm
        %DSPy.Predict.ChainOfThought{predict: %DSPy.Predict.Predict{lm: lm}} -> lm
        _ -> %{}
      end

    DSPy.Clients.Trainer.finetune(optimizer.trainer, lm, enriched, method: :grpo)
  end
end

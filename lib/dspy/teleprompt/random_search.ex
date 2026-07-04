defmodule DSPy.Teleprompt.RandomSearch do
  @moduledoc "Try random demo subsets and keep the program with the best dev score."

  defstruct [:metric, candidates: 8, demos_per_candidate: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      candidates: Keyword.get(opts, :candidates, 8),
      demos_per_candidate: Keyword.get(opts, :demos_per_candidate, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    evaluator = DSPy.Evaluate.new(devset, optimizer.metric)

    1..optimizer.candidates
    |> Enum.map(fn _ ->
      demos = trainset |> Enum.shuffle() |> Enum.take(optimizer.demos_per_candidate)

      candidate =
        DSPy.Teleprompt.LabeledFewShot.compile(
          %DSPy.Teleprompt.LabeledFewShot{k: optimizer.demos_per_candidate},
          program,
          demos
        )

      {DSPy.Evaluate.run(evaluator, candidate).score, candidate}
    end)
    |> Enum.max_by(fn {score, _candidate} -> score end)
    |> elem(1)
  end
end

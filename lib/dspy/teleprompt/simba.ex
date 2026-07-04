defmodule DSPy.Teleprompt.SIMBA do
  @moduledoc "Simple stochastic improvement loop over demo subsets and concise instructions."

  defstruct [:metric, steps: 8, demos_per_step: 3]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      steps: Keyword.get(opts, :steps, 8),
      demos_per_step: Keyword.get(opts, :demos_per_step, 3)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    evaluator = DSPy.Evaluate.new(devset, optimizer.metric)
    initial = {DSPy.Evaluate.run(evaluator, program).score, program}

    1..optimizer.steps
    |> Enum.reduce(initial, fn _step, {best_score, best_program} ->
      demos = trainset |> Enum.shuffle() |> Enum.take(optimizer.demos_per_step)

      instruction =
        (DSPy.Teleprompt.InstructionSearch.current_instruction(best_program) || "") <>
          "\nPrefer answers that score well on the metric."

      candidate =
        %DSPy.Teleprompt.LabeledFewShot{k: optimizer.demos_per_step}
        |> DSPy.Teleprompt.LabeledFewShot.compile(
          DSPy.Teleprompt.InstructionSearch.put_instruction(best_program, instruction),
          demos
        )

      score = DSPy.Evaluate.run(evaluator, candidate).score
      if score >= best_score, do: {score, candidate}, else: {best_score, best_program}
    end)
    |> elem(1)
  end
end

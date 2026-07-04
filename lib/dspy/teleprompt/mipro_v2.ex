defmodule DSPy.Teleprompt.MIPROv2 do
  @moduledoc "Joint instruction and demonstration search inspired by DSPy's MIPROv2."

  defstruct [:metric, trials: 12, demos_per_candidate: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      trials: Keyword.get(opts, :trials, 12),
      demos_per_candidate: Keyword.get(opts, :demos_per_candidate, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    candidates = DSPy.Teleprompt.InstructionSearch.candidate_instructions(program, trainset)
    evaluator = DSPy.Evaluate.new(devset, optimizer.metric)

    1..optimizer.trials
    |> Enum.map(fn trial ->
      instruction = Enum.at(candidates, rem(trial - 1, length(candidates)))
      demos = trainset |> Enum.shuffle() |> Enum.take(optimizer.demos_per_candidate)

      candidate =
        %DSPy.Teleprompt.LabeledFewShot{k: optimizer.demos_per_candidate}
        |> DSPy.Teleprompt.LabeledFewShot.compile(
          DSPy.Teleprompt.InstructionSearch.put_instruction(program, instruction),
          demos
        )

      {DSPy.Evaluate.run(evaluator, candidate).score, candidate}
    end)
    |> Enum.max_by(fn {score, _candidate} -> score end)
    |> elem(1)
  end
end

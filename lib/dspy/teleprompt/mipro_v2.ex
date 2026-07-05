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

    results =
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

        result = DSPy.Evaluate.run(evaluator, candidate)
        {result.score, candidate, %{trial: trial, instruction: instruction, demos: demos}}
      end)

    {best_score, best, _metadata} =
      Enum.max_by(results, fn {score, _candidate, _metadata} -> score end)

    DSPy.Teleprompt.Report.attach(
      best,
      DSPy.Teleprompt.Report.new(%{
        optimizer: :mipro_v2,
        best_score: best_score,
        candidate_count: length(results),
        candidates:
          Enum.map(results, fn {score, _candidate, metadata} ->
            Map.put(metadata, :score, score)
          end)
      })
    )
  end
end

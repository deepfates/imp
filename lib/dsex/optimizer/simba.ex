defmodule DSEx.Optimizer.SIMBA do
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
    evaluator = DSEx.Evaluate.new(devset, optimizer.metric)
    initial = {DSEx.Evaluate.run(evaluator, program).score, program}

    {best_score, best_program, candidates} =
      1..optimizer.steps
      |> Enum.reduce({elem(initial, 0), elem(initial, 1), []}, fn step,
                                                                  {best_score, best_program,
                                                                   candidates} ->
        demos = demo_window(trainset, step, optimizer.demos_per_step)

        instruction =
          (DSEx.Optimizer.InstructionSearch.current_instruction(best_program) || "") <>
            "\nPrefer answers that score well on the metric."

        candidate =
          %DSEx.Optimizer.LabeledFewShot{k: optimizer.demos_per_step}
          |> DSEx.Optimizer.LabeledFewShot.compile(
            DSEx.Optimizer.InstructionSearch.put_instruction(best_program, instruction),
            demos
          )

        score = DSEx.Evaluate.run(evaluator, candidate).score

        candidate_record = %{
          step: step,
          score: score,
          demos: demos,
          accepted: score >= best_score
        }

        if score >= best_score do
          {score, candidate, candidates ++ [candidate_record]}
        else
          {best_score, best_program, candidates ++ [candidate_record]}
        end
      end)

    DSEx.Optimizer.Report.attach(
      best_program,
      DSEx.Optimizer.Report.new(%{
        optimizer: :simba,
        best_score: best_score,
        candidate_count: length(candidates),
        candidates: candidates,
        metadata: %{
          baseline_score: elem(initial, 0),
          policy: :monotonic_minibatch_ascent
        }
      })
    )
  end

  defp demo_window(_trainset, _step, k) when k <= 0, do: []
  defp demo_window([], _step, _k), do: []

  defp demo_window(trainset, step, k) do
    offset = rem(step - 1, length(trainset))

    trainset
    |> Stream.cycle()
    |> Stream.drop(offset)
    |> Enum.take(k)
  end
end

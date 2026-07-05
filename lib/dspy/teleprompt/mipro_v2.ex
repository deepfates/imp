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
    instructions = DSPy.Teleprompt.InstructionSearch.candidate_instructions(program, trainset)
    demo_sets = demo_candidates(trainset, optimizer.demos_per_candidate)
    evaluator = DSPy.Evaluate.new(devset, optimizer.metric)
    baseline = {DSPy.Evaluate.run(evaluator, program).score, program, %{trial: 0, baseline: true}}

    results =
      instructions
      |> candidate_pairs(demo_sets)
      |> Enum.take(optimizer.trials)
      |> Enum.with_index(1)
      |> Enum.map(fn {{instruction, demos}, trial} ->
        candidate = build_candidate(program, instruction, demos, optimizer.demos_per_candidate)
        result = DSPy.Evaluate.run(evaluator, candidate)
        {result.score, candidate, %{trial: trial, instruction: instruction, demos: demos}}
      end)
      |> Kernel.++([baseline])

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
          end),
        metadata: %{
          search: :joint_instruction_demo_grid,
          instruction_count: length(instructions),
          demo_candidate_count: length(demo_sets)
        }
      })
    )
  end

  defp candidate_pairs(instructions, demo_sets) do
    for instruction <- instructions, demos <- demo_sets, do: {instruction, demos}
  end

  defp demo_candidates(_trainset, k) when k <= 0, do: [[]]

  defp demo_candidates([], _k), do: [[]]

  defp demo_candidates(trainset, k) do
    1..length(trainset)
    |> Enum.map(fn index ->
      offset = index - 1

      trainset
      |> Stream.cycle()
      |> Stream.drop(offset)
      |> Enum.take(k)
    end)
    |> Enum.uniq()
  end

  defp build_candidate(program, instruction, demos, k) do
    %DSPy.Teleprompt.LabeledFewShot{k: k}
    |> DSPy.Teleprompt.LabeledFewShot.compile(
      DSPy.Teleprompt.InstructionSearch.put_instruction(program, instruction),
      demos
    )
  end
end

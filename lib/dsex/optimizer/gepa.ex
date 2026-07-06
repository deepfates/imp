defmodule DSEx.Optimizer.GEPA do
  @moduledoc """
  Compatibility wrapper over `DSEx.Optimize.GEPA`.

  The GEPA search implementation lives in `DSEx.Optimize.GEPA`. This module
  adapts program instruction optimization into an artifact optimization problem
  so DSEx does not maintain two unrelated GEPA algorithms.
  """

  defstruct [:metric, feedback_fn: nil, generations: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      feedback_fn: Keyword.get(opts, :feedback_fn),
      generations: Keyword.get(opts, :generations, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    feedback = feedback(optimizer, trainset)
    examples = Enum.map(devset, &DSEx.Example.to_map/1)

    artifact =
      DSEx.Optimize.Anything.new_artifact(
        :instruction,
        DSEx.Optimizer.InstructionSearch.current_instruction(program) || "Complete the task."
      )

    report =
      DSEx.Optimize.GEPA.optimize(
        artifact,
        evaluator(program, optimizer.metric),
        examples: examples,
        generations: optimizer.generations,
        mutation_fn: fn _artifact, asi, generation ->
          "#{feedback}\nReflection #{generation}: #{Enum.join(asi, "; ")}"
        end
      )

    candidates =
      Enum.map(report.candidates, fn candidate ->
        %{
          score: candidate.aggregate_score,
          instruction: candidate.artifact.text,
          id: candidate.id,
          parent_id: candidate.parent_id,
          mutation: candidate.mutation
        }
      end)

    compiled =
      DSEx.Optimizer.InstructionSearch.put_instruction(program, report.best.artifact.text)

    DSEx.Optimizer.Report.attach(
      compiled,
      DSEx.Optimizer.Report.new(%{
        optimizer: :gepa,
        best_score: report.best.aggregate_score,
        candidate_count: length(candidates),
        candidates: candidates,
        metadata: %{
          feedback: feedback,
          generations: optimizer.generations,
          implementation: DSEx.Optimize.GEPA,
          frontier_size: length(report.frontier)
        }
      })
    )
  end

  defp evaluator(program, metric) do
    fn artifact, examples ->
      instruction = artifact.text
      candidate = DSEx.Optimizer.InstructionSearch.put_instruction(program, instruction)

      per_example_scores =
        Enum.map(examples, fn example_map ->
          example = DSEx.Example.new(example_map)

          {:ok, prediction} =
            DSEx.call(candidate, DSEx.Example.inputs(example) |> DSEx.Example.to_map())

          metric.(example, prediction) |> DSEx.Metrics.score()
        end)

      %{
        per_example_scores: per_example_scores,
        asi: misses(examples, per_example_scores)
      }
    end
  end

  defp misses(examples, scores) do
    examples
    |> Enum.zip(scores)
    |> Enum.reject(fn {_example, score} -> score > 0 end)
    |> Enum.map(fn {example, _score} -> "Improve result for #{inspect(example)}" end)
  end

  defp feedback(%__MODULE__{feedback_fn: fun}, trainset) when is_function(fun, 1),
    do: fun.(trainset)

  defp feedback(_optimizer, trainset), do: default_feedback(trainset)

  defp default_feedback(trainset),
    do: "Use observed examples carefully. Training examples available: #{length(trainset)}."
end

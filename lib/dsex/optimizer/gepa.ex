defmodule DSEx.Optimizer.GEPA do
  @moduledoc """
  Program-level GEPA optimizer for DSEx signatures.

  `DSEx.Optimizer.GEPA` treats a program's instruction as the artifact under
  search, then uses `DSEx.Optimize.GEPA` to generate reflective instruction
  candidates. It is the DSEx-native bridge between signature programs and
  artifact optimization, not a Python compatibility layer.
  """

  defstruct [:metric, feedback_fn: nil, generations: 4]

  @option_schema [
    feedback_fn: [type: :any, default: nil],
    generations: [type: :non_neg_integer, default: 4]
  ]

  def new(metric, opts \\ []) do
    validate_metric!(metric)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.GEPA.new/2")
    validate_feedback_fn!(opts[:feedback_fn])

    %__MODULE__{
      metric: metric,
      feedback_fn: opts[:feedback_fn],
      generations: opts[:generations]
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    {feedback, feedback_errors} = feedback(optimizer, trainset)
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
          mutation: candidate.mutation,
          diagnostics: candidate.diagnostics
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
        errors: feedback_errors ++ report.errors,
        metadata: %{
          feedback: feedback,
          generations: optimizer.generations,
          implementation: DSEx.Optimize.GEPA,
          frontier_size: length(report.frontier),
          status: if(feedback_errors == [] and report.errors == [], do: :ok, else: :with_errors)
        }
      })
    )
  end

  defp evaluator(program, metric) do
    fn artifact, examples ->
      instruction = artifact.text
      candidate = DSEx.Optimizer.InstructionSearch.put_instruction(program, instruction)

      {per_example_scores, failures} =
        Enum.map(examples, fn example_map ->
          example = DSEx.Example.new(example_map)

          case DSEx.call(candidate, DSEx.Example.inputs(example) |> DSEx.Example.to_map()) do
            {:ok, prediction} ->
              {metric.(example, prediction) |> DSEx.Metrics.score(), nil}

            {:error, reason} ->
              {0.0, "Program call failed for #{inspect(example_map)}: #{inspect(reason)}"}
          end
        end)
        |> Enum.unzip()

      %{
        per_example_scores: per_example_scores,
        asi: failures |> Enum.reject(&is_nil/1) |> Kernel.++(misses(examples, per_example_scores))
      }
    end
  end

  defp misses(examples, scores) do
    examples
    |> Enum.zip(scores)
    |> Enum.reject(fn {_example, score} -> score > 0 end)
    |> Enum.map(fn {example, _score} -> "Improve result for #{inspect(example)}" end)
  end

  defp feedback(%__MODULE__{feedback_fn: fun}, trainset) when is_function(fun, 1) do
    {to_string(fun.(trainset)), []}
  rescue
    exception ->
      default = default_feedback(trainset)

      {default,
       [
         %{
           stage: :feedback,
           error: Exception.message(exception),
           fallback: default
         }
       ]}
  catch
    kind, reason ->
      default = default_feedback(trainset)

      {default,
       [
         %{
           stage: :feedback,
           error: "#{kind}: #{inspect(reason)}",
           fallback: default
         }
       ]}
  end

  defp feedback(_optimizer, trainset), do: {default_feedback(trainset), []}

  defp default_feedback(trainset),
    do: "Use observed examples carefully. Training examples available: #{length(trainset)}."

  defp validate_metric!(metric) when is_function(metric, 2), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Optimizer.GEPA.new/2 expects a metric function with arity 2; got: #{inspect(metric)}"
  end

  defp validate_feedback_fn!(nil), do: :ok
  defp validate_feedback_fn!(feedback_fn) when is_function(feedback_fn, 1), do: :ok

  defp validate_feedback_fn!(feedback_fn) do
    raise ArgumentError,
          "DSEx.Optimizer.GEPA.new/2 expects :feedback_fn to be nil or an arity-1 function; got: #{inspect(feedback_fn)}"
  end
end

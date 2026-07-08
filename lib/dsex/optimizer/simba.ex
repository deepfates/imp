defmodule DSEx.Optimizer.SIMBA do
  @moduledoc "Simple stochastic improvement loop over demo subsets and concise instructions."

  defstruct [:metric, :judge_lm, steps: 8, demos_per_step: 3]

  @option_schema [
    steps: [type: :non_neg_integer, default: 8],
    judge_lm: [type: :any, default: nil],
    demos_per_step: [type: :non_neg_integer, default: 3]
  ]

  def new(metric, opts \\ []) do
    validate_metric!(metric)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.SIMBA.new/2")

    %__MODULE__{
      metric: metric,
      steps: opts[:steps],
      judge_lm: opts[:judge_lm],
      demos_per_step: opts[:demos_per_step]
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    with {:ok, evaluator} <- new_evaluator(devset, optimizer.metric),
         {:ok, baseline_score} <- evaluate_score(evaluator, program, %{step: :baseline}) do
      {trainset, setup_errors} = materialize_trainset(trainset)

      {best_score, best_program, candidates, errors} =
        step_indices(optimizer.steps)
        |> Enum.reduce({baseline_score, program, [], setup_errors}, fn step,
                                                                       {best_score, best_program,
                                                                        candidates, errors} ->
          demos = demo_window(trainset, step, optimizer.demos_per_step)

          instruction = introspective_instruction(best_program, optimizer.judge_lm, candidates)

          candidate =
            %DSEx.Optimizer.LabeledFewShot{k: optimizer.demos_per_step}
            |> DSEx.Optimizer.LabeledFewShot.compile(
              DSEx.Optimizer.InstructionSearch.put_instruction(best_program, instruction),
              demos
            )

          case evaluate_score(evaluator, candidate, %{step: step, demos: demos}) do
            {:ok, score} ->
              candidate_record = %{
                step: step,
                score: score,
                demos: demos,
                accepted: score >= best_score
              }

              if score >= best_score do
                {score, candidate, candidates ++ [candidate_record], errors}
              else
                {best_score, best_program, candidates ++ [candidate_record], errors}
              end

            {:error, error} ->
              candidate_record = %{
                step: step,
                score: nil,
                demos: demos,
                accepted: false,
                error: error
              }

              {best_score, best_program, candidates ++ [candidate_record],
               errors ++ [%{stage: :candidate_evaluation, reason: error, metadata: %{step: step}}]}
          end
        end)

      attach_report(best_program, optimizer, best_score, candidates, errors, %{
        baseline_score: baseline_score,
        status: if(errors == [], do: :ok, else: :with_errors)
      })
    else
      {:error, error} ->
        attach_report(program, optimizer, nil, [], [%{stage: :setup, reason: error}], %{
          baseline_score: nil,
          status: :all_candidates_failed
        })
    end
  end

  defp attach_report(program, optimizer, best_score, candidates, errors, metadata) do
    DSEx.Optimizer.Report.attach(
      program,
      DSEx.Optimizer.Report.new(%{
        optimizer: :simba,
        best_score: best_score,
        candidate_count: length(candidates),
        candidates: candidates,
        errors: errors,
        metadata:
          Map.merge(metadata, %{
            policy: :monotonic_minibatch_ascent,
            introspection: not is_nil(optimizer.judge_lm)
          })
      })
    )
  end

  defp new_evaluator(devset, metric) do
    {:ok, DSEx.Evaluate.new(devset, metric)}
  rescue
    error -> {:error, error_message(error)}
  catch
    kind, reason -> {:error, error_message({kind, reason})}
  end

  defp evaluate_score(evaluator, program, _metadata) do
    {:ok, DSEx.Evaluate.run(evaluator, program).score}
  rescue
    error -> {:error, error_message(error)}
  catch
    kind, reason -> {:error, error_message({kind, reason})}
  end

  defp materialize_trainset(trainset) do
    {Enum.to_list(trainset), []}
  rescue
    error -> {[], [%{stage: :trainset, reason: error_message(error)}]}
  catch
    kind, reason -> {[], [%{stage: :trainset, reason: error_message({kind, reason})}]}
  end

  defp introspective_instruction(program, nil, _candidates),
    do:
      (DSEx.Optimizer.InstructionSearch.current_instruction(program) || "") <>
        "\nPrefer answers that score well on the metric."

  defp introspective_instruction(program, judge_lm, candidates) do
    prompt =
      Jason.encode!(%{
        current_instruction: DSEx.Optimizer.InstructionSearch.current_instruction(program),
        recent_candidates: Enum.take(candidates, -4)
      })

    case DSEx.LM.generate(judge_lm, [%{role: :user, content: prompt}], []) do
      {:ok, %{instruction: instruction}} -> instruction
      {:ok, %{"instruction" => instruction}} -> instruction
      {:ok, instruction} when is_binary(instruction) -> instruction
      _other -> introspective_instruction(program, nil, candidates)
    end
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

  defp step_indices(steps) when steps > 0, do: 1..steps
  defp step_indices(_steps), do: []

  defp validate_metric!(metric) when is_function(metric, 2) or is_function(metric, 3), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Optimizer.SIMBA.new/2 expects a metric function with arity 2 or 3; got: #{inspect(metric)}"
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

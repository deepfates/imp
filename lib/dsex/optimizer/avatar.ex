defmodule DSEx.Optimizer.Avatar do
  @moduledoc """
  Rewrites Avatar actor instructions from positive and negative trajectories.

  Each round evaluates the current actor, contrasts bounded positive and
  negative examples, asks typed predictors for feedback and a rewritten
  instruction, evaluates that candidate, and retains it only when it improves
  the configured objective.
  """

  alias DSEx.Optimizer.Avatar.EvalResult

  defstruct [
    :metric,
    :comparator,
    :rewriter,
    max_iters: 10,
    lower_bound: 0,
    upper_bound: 1,
    max_positive_inputs: 10,
    max_negative_inputs: 10,
    optimize_for: :max
  ]

  @option_schema [
    max_iters: [type: :non_neg_integer, default: 10],
    lower_bound: [type: {:or, [:integer, :float]}, default: 0],
    upper_bound: [type: {:or, [:integer, :float]}, default: 1],
    max_positive_inputs: [type: :pos_integer, default: 10],
    max_negative_inputs: [type: :pos_integer, default: 10],
    optimize_for: [type: :atom, default: :max],
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    comparator_lm: [type: {:custom, DSEx.LM, :validate_lm, []}, default: nil],
    rewrite_lm: [type: {:custom, DSEx.LM, :validate_lm, []}, default: nil],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    config: [type: :keyword_list, default: []]
  ]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(metric, [2, 3], "DSEx.Optimizer.Avatar.new/2", "metric")
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.Avatar.new/2")

    unless opts[:optimize_for] in [:max, :min] do
      raise ArgumentError, "DSEx.Optimizer.Avatar.new/2: :optimize_for must be :max or :min"
    end

    if opts[:lower_bound] > opts[:upper_bound] do
      raise ArgumentError, "DSEx.Optimizer.Avatar.new/2: :lower_bound must be <= :upper_bound"
    end

    common_opts = Keyword.take(opts, [:adapter, :config])
    default_lm = opts[:lm]

    %__MODULE__{
      metric: metric,
      max_iters: opts[:max_iters],
      lower_bound: opts[:lower_bound],
      upper_bound: opts[:upper_bound],
      max_positive_inputs: opts[:max_positive_inputs],
      max_negative_inputs: opts[:max_negative_inputs],
      optimize_for: opts[:optimize_for],
      comparator:
        DSEx.Predict.Predict.new(
          comparator_signature(),
          maybe_lm(common_opts, opts[:comparator_lm] || default_lm)
        ),
      rewriter:
        DSEx.Predict.Predict.new(
          rewrite_signature(),
          maybe_lm(common_opts, opts[:rewrite_lm] || default_lm)
        )
    }
  end

  def compile(%__MODULE__{} = optimizer, %DSEx.Predict.Avatar{} = student, trainset) do
    trainset = Enum.to_list(trainset)
    evaluator = DSEx.Evaluate.new(trainset, optimizer.metric, max_concurrency: 1)
    baseline = DSEx.Evaluate.run(evaluator, student)

    state = %{
      program: student,
      evaluation: baseline,
      candidates: [candidate_record(0, student, baseline.score, true, true)],
      errors: evaluation_errors(0, baseline),
      rounds: [],
      stop_reason: :max_iters
    }

    state =
      if optimizer.max_iters == 0 do
        %{state | stop_reason: :max_iters}
      else
        Enum.reduce_while(1..optimizer.max_iters, state, fn round, state ->
          optimize_round(optimizer, evaluator, round, state)
        end)
      end

    report =
      DSEx.Optimizer.Report.new(%{
        optimizer: :avatar,
        best_score: state.evaluation.score,
        candidate_count: length(state.candidates),
        candidates: state.candidates,
        errors: state.errors,
        metadata: %{
          status: report_status(state),
          stop_reason: state.stop_reason,
          optimize_for: optimizer.optimize_for,
          lower_bound: optimizer.lower_bound,
          upper_bound: optimizer.upper_bound,
          rounds: state.rounds,
          trainset_size: Enum.count(trainset)
        }
      })

    DSEx.Optimizer.Report.attach(state.program, report)
  end

  def compile(%__MODULE__{}, program, _trainset) do
    raise ArgumentError,
          "DSEx.Optimizer.Avatar.compile/3 expects a DSEx.Predict.Avatar, got: #{inspect(program)}"
  end

  defp optimize_round(optimizer, evaluator, round, state) do
    {positive, negative} = classified_results(optimizer, state.evaluation)

    cond do
      positive == [] ->
        halt_missing_class(state, round, :no_positive_examples)

      negative == [] ->
        halt_missing_class(state, round, :no_negative_examples)

      true ->
        positive = Enum.take(positive, optimizer.max_positive_inputs)
        negative = Enum.take(negative, optimizer.max_negative_inputs)

        with {:ok, feedback} <- compare(optimizer, state.program, positive, negative),
             {:ok, instruction} <- rewrite(optimizer, state.program, feedback) do
          candidate = DSEx.Predict.Avatar.put_instruction(state.program, instruction)
          evaluation = DSEx.Evaluate.run(evaluator, candidate)
          selected? = better?(optimizer.optimize_for, evaluation.score, state.evaluation.score)

          record = candidate_record(round, candidate, evaluation.score, false, selected?)

          state = %{
            state
            | candidates: state.candidates ++ [record],
              errors: state.errors ++ evaluation_errors(round, evaluation),
              rounds:
                state.rounds ++
                  [
                    %{
                      iteration: round,
                      positive_count: length(positive),
                      negative_count: length(negative),
                      feedback: feedback,
                      proposed_instruction: instruction,
                      score: evaluation.score,
                      selected?: selected?
                    }
                  ]
          }

          if selected? do
            {:cont, %{state | program: candidate, evaluation: evaluation}}
          else
            {:cont, state}
          end
        else
          {:error, stage, reason} ->
            error = %{iteration: round, stage: stage, reason: error_message(reason)}

            {:halt,
             %{
               state
               | errors: state.errors ++ [error],
                 stop_reason: stage,
                 rounds: state.rounds ++ [%{iteration: round, error: error}]
             }}
        end
    end
  end

  defp halt_missing_class(state, round, reason) do
    error = %{iteration: round, stage: :classification, reason: reason}

    {:halt,
     %{
       state
       | errors: state.errors ++ [error],
         stop_reason: reason,
         rounds: state.rounds ++ [%{iteration: round, error: error}]
     }}
  end

  defp classified_results(optimizer, evaluation) do
    Enum.reduce(evaluation.rows, {[], []}, fn row, {positive, negative} ->
      result = eval_result(row)

      cond do
        positive_score?(optimizer, row.score) -> {positive ++ [result], negative}
        negative_score?(optimizer, row.score) -> {positive, negative ++ [result]}
        true -> {positive, negative}
      end
    end)
  end

  defp eval_result(row) do
    inputs =
      case row.example do
        %DSEx.Example{} = example -> example |> DSEx.Example.inputs() |> DSEx.Example.to_map()
        _ -> %{}
      end

    %EvalResult{
      example: inputs,
      score: row.score,
      actions: if(row.prediction, do: DSEx.Prediction.get(row.prediction, :actions, []), else: [])
    }
  end

  defp compare(optimizer, program, positive, negative) do
    inputs = %{
      instruction: DSEx.Predict.Avatar.current_instruction(program),
      actions: tool_descriptions(program),
      pos_input_with_metrics: Enum.map(positive, &Map.from_struct/1),
      neg_input_with_metrics: Enum.map(negative, &Map.from_struct/1)
    }

    case DSEx.Predict.Predict.call(optimizer.comparator, inputs) do
      {:ok, prediction} -> {:ok, DSEx.Prediction.fetch!(prediction, :feedback)}
      {:error, reason} -> {:error, :comparison, reason}
    end
  end

  defp rewrite(optimizer, program, feedback) do
    inputs = %{
      previous_instruction: DSEx.Predict.Avatar.current_instruction(program),
      feedback: feedback
    }

    case DSEx.Predict.Predict.call(optimizer.rewriter, inputs) do
      {:ok, prediction} -> {:ok, DSEx.Prediction.fetch!(prediction, :new_instruction)}
      {:error, reason} -> {:error, :instruction_rewrite, reason}
    end
  end

  defp tool_descriptions(program) do
    program.tools
    |> Map.values()
    |> Enum.map(&"#{&1.name}: #{&1.description}")
    |> Kernel.++(["Finish: return final task outputs"])
  end

  defp candidate_record(iteration, program, score, baseline?, selected?) do
    %{
      iteration: iteration,
      instruction: DSEx.Predict.Avatar.current_instruction(program),
      score: score,
      baseline: baseline?,
      selected?: selected?
    }
  end

  defp evaluation_errors(iteration, evaluation) do
    Enum.map(evaluation.errors, &Map.merge(%{iteration: iteration, stage: :evaluation}, &1))
  end

  defp better?(:max, candidate, current), do: candidate > current
  defp better?(:min, candidate, current), do: candidate < current

  defp positive_score?(%{optimize_for: :max, upper_bound: bound}, score), do: score >= bound
  defp positive_score?(%{optimize_for: :min, lower_bound: bound}, score), do: score <= bound
  defp negative_score?(%{optimize_for: :max, lower_bound: bound}, score), do: score <= bound
  defp negative_score?(%{optimize_for: :min, upper_bound: bound}, score), do: score >= bound

  defp report_status(%{errors: []}), do: :ok
  defp report_status(%{candidates: [_baseline]}), do: :stopped
  defp report_status(_state), do: :with_errors

  defp maybe_lm(opts, nil), do: opts
  defp maybe_lm(opts, lm), do: Keyword.put(opts, :lm, lm)

  defp comparator_signature do
    DSEx.Signature.new(%{
      inputs: [
        %{name: :instruction, type: :string},
        %{name: :actions, type: :array},
        %{name: :pos_input_with_metrics, type: :array},
        %{name: :neg_input_with_metrics, type: :array}
      ],
      outputs: [%{name: :feedback, type: :string}],
      instructions: """
      Contrast successful and unsuccessful Avatar action trajectories.
      Identify input patterns, action-logic inconsistencies, and specific changes in tool use
      that should improve the negative examples. Return actionable feedback.
      """
    })
  end

  defp rewrite_signature do
    DSEx.Signature.new(%{
      inputs: [
        %{name: :previous_instruction, type: :string},
        %{name: :feedback, type: :string}
      ],
      outputs: [%{name: :new_instruction, type: :string}],
      instructions: """
      Rewrite the previous Avatar actor instruction to incorporate the feedback.
      Retain its general guidelines, explain effective tool use, and use no more than three paragraphs.
      """
    })
  end

  defp error_message(%_{} = error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)
end

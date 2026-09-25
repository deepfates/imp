defmodule Imp.Optimizer.Avatar do
  @behaviour Imp.Optimizer
  @moduledoc """
  Rewrites Avatar actor instructions from positive and negative trajectories.

  Each round evaluates the current actor, contrasts bounded positive and
  negative examples, asks typed predictors for feedback and a rewritten
  instruction, evaluates that candidate, and retains it only when it improves
  the configured objective.
  """

  alias Imp.Optimizer.Avatar.EvalResult

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
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    comparator_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
    rewrite_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    config: [type: :keyword_list, default: []]
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Optimizer.Avatar.new/2", "metric")

    opts =
      Imp.Predict.Options.validate!(opts, @option_schema, "Imp.Optimizer.Avatar.new/2")

    unless opts[:optimize_for] in [:max, :min] do
      raise ArgumentError, "Imp.Optimizer.Avatar.new/2: :optimize_for must be :max or :min"
    end

    if opts[:lower_bound] > opts[:upper_bound] do
      raise ArgumentError, "Imp.Optimizer.Avatar.new/2: :lower_bound must be <= :upper_bound"
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
        Imp.Predict.new(
          comparator_signature(),
          maybe_lm(common_opts, opts[:comparator_lm] || default_lm)
        ),
      rewriter:
        Imp.Predict.new(
          rewrite_signature(),
          maybe_lm(common_opts, opts[:rewrite_lm] || default_lm)
        )
    }
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :unsupported},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      {:ok, compile(optimizer, program, Imp.Optimizer.fetch_dataset!(opts, :trainset))}
    end
  end

  @doc false
  def compile(%__MODULE__{} = optimizer, %Imp.Predict.Avatar{} = student, trainset) do
    trainset = Enum.to_list(trainset)
    evaluator = Imp.Evaluate.new(trainset, optimizer.metric, max_concurrency: 1)
    baseline = Imp.Evaluate.run(evaluator, student)

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
      Imp.Optimizer.Report.new(%{
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

    Imp.Optimizer.Report.attach(state.program, report)
  end

  def compile(%__MODULE__{}, program, _trainset) do
    raise ArgumentError,
          "Imp.Optimizer.Avatar.compile/3 expects an Imp.Predict.Avatar, got: #{inspect(program)}"
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
          candidate = Imp.Predict.Avatar.put_instruction(state.program, instruction)
          evaluation = Imp.Evaluate.run(evaluator, candidate)

          selected? =
            evaluation.errors == [] and
              better?(optimizer.optimize_for, evaluation.score, state.evaluation.score)

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
        %Imp.Example{} = example -> example |> Imp.Example.inputs() |> Imp.Example.to_map()
        _ -> %{}
      end

    %EvalResult{
      example: inputs,
      score: row.score,
      actions: if(row.prediction, do: Imp.Prediction.get(row.prediction, :actions, []), else: [])
    }
  end

  defp compare(optimizer, program, positive, negative) do
    inputs = %{
      instruction: Imp.Predict.Avatar.current_instruction(program),
      actions: tool_descriptions(program),
      pos_input_with_metrics: Enum.map(positive, &Map.from_struct/1),
      neg_input_with_metrics: Enum.map(negative, &Map.from_struct/1)
    }

    result = Imp.Predict.call(optimizer.comparator, inputs)
    Imp.OperationalSafetyError.raise_if_present!(result)

    case result do
      {:ok, prediction} -> {:ok, Imp.Prediction.fetch!(prediction, :feedback)}
      {:error, reason} -> {:error, :comparison, reason}
    end
  end

  defp rewrite(optimizer, program, feedback) do
    inputs = %{
      previous_instruction: Imp.Predict.Avatar.current_instruction(program),
      feedback: feedback
    }

    result = Imp.Predict.call(optimizer.rewriter, inputs)
    Imp.OperationalSafetyError.raise_if_present!(result)

    case result do
      {:ok, prediction} -> {:ok, Imp.Prediction.fetch!(prediction, :new_instruction)}
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
      instruction: Imp.Predict.Avatar.current_instruction(program),
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
    Imp.Signature.new(%{
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
    Imp.Signature.new(%{
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

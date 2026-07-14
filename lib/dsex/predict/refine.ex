defmodule DSEx.Predict.Refine do
  @moduledoc """
  Iteratively call a program until a metric passes or attempts are exhausted.

  With no explicit `:feedback_fn`, Refine uses the wrapped program's LM to ask
  for bounded repair advice after a below-threshold attempt. The advice is
  passed to the next attempt as `:hint_`. Explicit callbacks remain the
  compatibility path and take precedence over automatic feedback.
  """

  alias DSEx.Predict.Attempt

  defstruct [
    :program,
    :metric,
    :feedback_fn,
    :fail_count,
    max_attempts: 3,
    threshold: 1.0
  ]

  @option_schema [
    feedback_fn: [
      type: {:custom, __MODULE__, :validate_feedback_fn, []},
      default: nil
    ],
    fail_count: [type: {:or, [:non_neg_integer, nil]}, default: nil],
    max_attempts: [type: :non_neg_integer, default: 3],
    threshold: [type: {:or, [:integer, :float, nil]}, default: 1.0]
  ]

  def new(program, metric, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.Refine.new/3")
    DSEx.FunctionContract.validate!(metric, 2, "DSEx.Predict.Refine.new/3", "metric")

    %__MODULE__{
      program: program,
      metric: metric,
      feedback_fn: opts[:feedback_fn],
      fail_count: opts[:fail_count],
      max_attempts: opts[:max_attempts],
      threshold: opts[:threshold]
    }
  end

  def validate_feedback_fn(nil), do: {:ok, nil}
  def validate_feedback_fn(feedback_fn) when is_function(feedback_fn, 1), do: {:ok, feedback_fn}

  def validate_feedback_fn(feedback_fn) do
    {:error, "expected nil or a unary function, got: #{inspect(feedback_fn)}"}
  end

  def call(%__MODULE__{max_attempts: 0}, _inputs), do: {:error, :no_attempts, []}

  def call(%__MODULE__{} = refine, inputs) do
    rollout_ids = Attempt.rollout_ids(refine.program, refine.max_attempts)
    failure_budget = refine.fail_count || refine.max_attempts

    run_attempts(refine, inputs, rollout_ids, 1, nil, [], nil, 0, failure_budget)
  end

  defp run_attempts(
         _refine,
         _inputs,
         [],
         _attempt,
         _advice,
         [],
         _best,
         _failed_calls,
         _failure_budget
       ),
       do: {:error, :no_attempts, []}

  defp run_attempts(
         refine,
         inputs,
         [rollout_id | rest],
         attempt,
         advice,
         outcomes,
         best,
         failed_calls,
         failure_budget
       ) do
    program =
      refine.program
      |> Attempt.bind(rollout_id)
      |> maybe_extend_hint_signature(advice)

    attempt_inputs = maybe_add_hint(inputs, advice)

    case DSEx.Module.call(program, attempt_inputs) do
      {:ok, prediction} ->
        metric_result = Attempt.score(refine.metric, prediction)
        outcome = %{attempt: attempt, prediction: prediction, metric: metric_result}
        outcomes = outcomes ++ [outcome]
        best = choose_best(best, outcome)

        if threshold_reached?(refine.threshold, metric_result.score) or rest == [] do
          {:ok, attach_history(best.prediction, outcomes)}
        else
          next_advice = feedback(refine, inputs, outcomes, prediction, metric_result)

          run_attempts(
            refine,
            inputs,
            rest,
            attempt + 1,
            next_advice,
            outcomes,
            best,
            failed_calls,
            failure_budget
          )
        end

      {:error, reason} ->
        failed_calls = failed_calls + 1

        if failed_calls > failure_budget do
          {:error, {:refine_fail_count_exceeded, safe_reason(reason)}, []}
        else
          case rest do
            [] ->
              case best do
                nil -> {:error, safe_reason(reason), []}
                _best -> {:ok, attach_history(best.prediction, outcomes)}
              end

            _ ->
              run_attempts(
                refine,
                inputs,
                rest,
                attempt + 1,
                advice,
                outcomes,
                best,
                failed_calls,
                failure_budget
              )
          end
        end
    end
  end

  defp choose_best(nil, outcome), do: outcome

  defp choose_best(best, %{metric: metric} = outcome) do
    if metric.score > best.metric.score, do: outcome, else: best
  end

  defp threshold_reached?(nil, _score), do: false
  defp threshold_reached?(threshold, score), do: score >= threshold

  defp attach_history(prediction, outcomes) do
    history = Enum.map(outcomes, &history_entry/1)
    DSEx.Prediction.put(prediction, :refine_history, history)
  end

  defp history_entry(%{attempt: attempt, prediction: prediction, metric: metric}) do
    %{
      attempt: attempt,
      prediction: prediction,
      score: metric.score,
      feedback: metric.feedback
    }
  end

  defp maybe_add_hint(inputs, nil), do: inputs

  defp maybe_add_hint(inputs, {:per_predictor, advice}) do
    inputs
    |> Map.new()
    |> Map.put(:hint_, advice)
  end

  defp maybe_add_hint(inputs, advice) do
    inputs
    |> Map.new()
    |> Map.put(:hint_, advice)
  end

  defp maybe_extend_hint_signature(program, nil), do: program

  defp maybe_extend_hint_signature(program, {:per_predictor, advice}) do
    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      DSEx.ProgramParameters.update_predictor(acc, name, fn predictor ->
        signature = extend_hint_input(predictor.signature)
        own_advice = Map.get(advice, name, Map.get(advice, to_string(name), "N/A"))

        %{
          predictor
          | signature: %{
              signature
              | instructions: advice_instructions(signature, name, own_advice)
            }
        }
      end)
    end)
  rescue
    _error -> program
  end

  defp maybe_extend_hint_signature(program, _advice) do
    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      DSEx.ProgramParameters.update_predictor(acc, name, fn predictor ->
        %{predictor | signature: extend_hint_input(predictor.signature)}
      end)
    end)
  rescue
    _error -> program
  end

  defp feedback(%{feedback_fn: feedback_fn}, _inputs, outcomes, _prediction, _metric_result)
       when is_function(feedback_fn, 1) do
    safe_callback_feedback(feedback_fn, Enum.map(outcomes, &history_entry/1))
  end

  defp feedback(refine, inputs, outcomes, _prediction, metric_result) do
    case feedback_lm(refine.program) do
      nil -> nil
      lm -> automatic_feedback(refine, lm, inputs, outcomes, metric_result)
    end
  end

  defp feedback_lm(program) do
    predictor_lm =
      case DSEx.ProgramParameters.predictors(program) do
        [%{predictor: %{lm: lm}} | _] -> lm
        _ -> nil
      end

    predictor_lm || DSEx.Settings.get().lm
  rescue
    _error -> nil
  end

  defp automatic_feedback(refine, lm, inputs, outcomes, metric_result) do
    entries = DSEx.ProgramParameters.predictors(refine.program)
    predictor_names = predictor_names(entries)

    feedback_program = DSEx.Predict.Predict.new(feedback_signature(), lm: lm)

    feedback_inputs = %{
      program_code: program_definition(refine.program),
      modules_defn: module_definitions(entries),
      module_names: predictor_names,
      program_inputs: DSEx.Redaction.redact(Map.new(inputs)),
      program_trajectory: per_predictor_trajectory(outcomes, predictor_names),
      program_outputs: outputs(outcomes),
      reward_code: metric_contract(),
      target_threshold: refine.threshold,
      reward_value: metric_result.score
    }

    case DSEx.Predict.Predict.call(feedback_program, feedback_inputs) do
      {:ok, advice_prediction} ->
        {:per_predictor, parse_advice(advice_prediction, predictor_names)}

      {:error, reason} ->
        {:feedback_error, safe_reason(reason)}
    end
  rescue
    error -> {:feedback_error, safe_reason(error)}
  catch
    kind, reason -> {:feedback_error, safe_reason({kind, reason})}
  end

  defp predictor_names([]), do: ["main"]
  defp predictor_names(entries), do: Enum.map(entries, &to_string(&1.name))

  defp feedback_signature do
    DSEx.Signature.new(%{
      inputs: [
        %{name: :program_code, desc: "The program definition being analyzed."},
        %{name: :modules_defn, desc: "Each predictor definition, including its I/O."},
        %{name: :program_inputs, desc: "The inputs to the program being analyzed."},
        %{name: :program_trajectory, desc: "The execution trajectory with predictor I/O."},
        %{name: :program_outputs, desc: "The outputs produced by the program."},
        %{name: :reward_code, desc: "The executable reward contract available to DSEx."},
        %{name: :target_threshold, type: :number, desc: "The target reward threshold."},
        %{name: :reward_value, type: :number, desc: "The observed reward value."},
        %{name: :module_names, type: :array, desc: "Predictor names requiring advice."}
      ],
      outputs: [
        %{name: :discussion, desc: "Assign blame for the below-threshold reward."},
        %{name: :advice, type: :object, desc: "Concrete advice keyed by predictor name."}
      ],
      instructions:
        "Assign blame to each predictor that contributed to the below-threshold reward, then provide concrete repair advice for each predictor. Use N/A when a predictor is not to blame."
    })
  end

  defp program_definition(program) do
    %{
      language: "Elixir",
      module: module_name(program)
    }
    |> DSEx.Redaction.redact()
  end

  defp module_definitions(entries) do
    entries
    |> Enum.map(&predictor_definition/1)
    |> DSEx.Redaction.redact()
  end

  defp predictor_definition(%{name: name, predictor: predictor}) do
    %{
      name: to_string(name),
      module: module_name(predictor),
      signature: signature_definition(Map.get(predictor, :signature)),
      config: DSEx.Redaction.redact(Map.get(predictor, :config, []))
    }
  end

  defp signature_definition(%DSEx.Signature{} = signature), do: DSEx.Signature.dump(signature)
  defp signature_definition(_signature), do: nil

  defp module_name(%module{}), do: inspect(module)
  defp module_name(other), do: inspect(other)

  defp per_predictor_trajectory(outcomes, predictor_names) do
    trajectory =
      Enum.map(outcomes, fn %{attempt: attempt, prediction: prediction} ->
        %{
          attempt: attempt,
          output: DSEx.Redaction.redact(DSEx.Prediction.to_map(prediction)),
          trace: prediction_trace(prediction)
        }
      end)

    Map.new(predictor_names, &{&1, trajectory})
  end

  defp outputs(outcomes) do
    Enum.map(outcomes, fn %{attempt: attempt, prediction: prediction} ->
      %{attempt: attempt, output: DSEx.Redaction.redact(DSEx.Prediction.to_map(prediction))}
    end)
  end

  defp prediction_trace(%DSEx.Prediction{metadata: metadata}) do
    metadata
    |> Map.get(:trace, Map.get(metadata, "trace", []))
    |> DSEx.Redaction.redact()
  end

  defp metric_contract do
    %{
      contract: "metric_contract",
      language: "Elixir",
      arity: 2,
      input: "metric.(example, prediction)",
      output: "boolean, number, map, Metrics.Result, or Prediction"
    }
  end

  defp parse_advice(prediction, predictor_names) do
    advice = DSEx.Prediction.get(prediction, :advice, %{})

    advice =
      if is_map(advice), do: advice, else: %{}

    Map.new(predictor_names, fn name ->
      {name, Map.get(advice, name, Map.get(advice, to_string(name), "N/A")) || "N/A"}
    end)
  end

  defp extend_hint_input(%DSEx.Signature{} = signature) do
    if :hint_ in DSEx.Signature.input_names(signature) do
      signature
    else
      DSEx.Signature.extend(
        signature,
        %{
          name: :hint_,
          desc: "Repair advice from the previous attempt",
          metadata: %{optional: true}
        },
        :input
      )
    end
  end

  defp advice_instructions(signature, name, advice) do
    (signature.instructions || "") <>
      "\n\nRepair advice for #{name}: #{advice |> inspect() |> DSEx.Redaction.redact()}"
  end

  defp safe_callback_feedback(feedback_fn, history) do
    feedback_fn.(history)
  rescue
    error -> {:feedback_error, safe_reason(error)}
  catch
    kind, reason -> {:feedback_error, safe_reason({kind, reason})}
  end

  defp safe_reason(reason) when is_atom(reason) or is_number(reason) or is_boolean(reason),
    do: reason

  defp safe_reason(nil), do: nil
  defp safe_reason(reason) when is_binary(reason), do: DSEx.Redaction.redact(reason)

  defp safe_reason(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&safe_reason/1)
    |> List.to_tuple()
  end

  defp safe_reason(reason) when is_list(reason), do: Enum.map(reason, &safe_reason/1)
  defp safe_reason(reason) when is_map(reason), do: DSEx.Redaction.redact(reason)
  defp safe_reason(reason), do: DSEx.Redaction.redact(Attempt.error_message(reason))
end

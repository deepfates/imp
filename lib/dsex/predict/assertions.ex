defmodule DSEx.Predict.Assertions do
  @moduledoc """
  Wraps a DSEx program with assertion-guided self-refinement.

  Each attempt calls the wrapped program, evaluates named assertions, and stops
  once all assertions pass. Failed attempts produce a textual `:hint_` for the
  next attempt so ordinary signatures can opt into self-repair without a special
  provider API.

  If attempts are exhausted, the best prediction by assertion pass rate is
  returned with `:assertion_score`, `:assertion_failures`, and
  `:assertion_history` fields. Pass `strict: true` to return an error instead
  when no attempt satisfies every assertion.
  """

  defstruct [:program, :assertions, max_attempts: 3, strict: false]

  @option_schema [
    max_attempts: [type: :non_neg_integer, default: 3],
    strict: [type: :boolean, default: false]
  ]

  def new(program, assertions, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.Assertions.new/3")
    assertions = assertions |> List.wrap() |> Enum.map(&DSEx.Assertion.normalize!/1)

    if assertions == [] do
      raise ArgumentError, "DSEx.Predict.Assertions.new/3 expects at least one assertion"
    end

    %__MODULE__{
      program: program,
      assertions: assertions,
      max_attempts: opts[:max_attempts],
      strict: opts[:strict]
    }
  end

  def call(%__MODULE__{} = wrapper, inputs) do
    inputs = Map.new(inputs)

    wrapper.max_attempts
    |> attempts()
    |> Enum.reduce_while(%{best: nil, history: [], last_error: nil}, fn attempt, state ->
      attempt_inputs = maybe_put_hint(inputs, state.history)

      case DSEx.Module.call(wrapper.program, attempt_inputs) do
        {:ok, prediction} ->
          evaluation = evaluate_assertions(wrapper.assertions, inputs, prediction)

          history_entry = %{
            attempt: attempt,
            score: evaluation.score,
            failures: evaluation.failures,
            prediction: prediction
          }

          state =
            state
            |> Map.update!(:history, &(&1 ++ [history_entry]))
            |> maybe_update_best(prediction, evaluation)

          if evaluation.passed? do
            {:halt, {:ok, attach_assertion_metadata(prediction, evaluation, state.history)}}
          else
            {:cont, state}
          end

        {:error, reason} ->
          {:cont, %{state | last_error: reason}}
      end
    end)
    |> finish(wrapper)
  end

  defp attempts(max_attempts) when is_integer(max_attempts) and max_attempts > 0,
    do: 1..max_attempts

  defp attempts(_max_attempts), do: []

  defp maybe_put_hint(inputs, []), do: inputs

  defp maybe_put_hint(inputs, history) do
    Map.put(inputs, :hint_, render_feedback(history))
  end

  defp render_feedback(history) do
    history
    |> List.last()
    |> Map.get(:failures, [])
    |> Enum.map_join("\n", fn failure -> "- #{failure.name}: #{failure.message}" end)
  end

  defp evaluate_assertions(assertions, inputs, prediction) do
    failures =
      assertions
      |> Enum.map(&evaluate_assertion(&1, inputs, prediction))
      |> Enum.reject(& &1.passed?)

    passed = length(assertions) - length(failures)

    %{
      passed?: failures == [],
      score: passed / length(assertions),
      failures: failures
    }
  end

  defp evaluate_assertion(%DSEx.Assertion{} = assertion, inputs, prediction) do
    case call_predicate(assertion.predicate, inputs, prediction) do
      true ->
        %{name: assertion.name, passed?: true, message: assertion.message}

      %DSEx.Metrics.Result{} = result ->
        %{
          name: assertion.name,
          passed?: DSEx.Metrics.pass?(result),
          message: to_message(result.feedback, assertion.message)
        }

      {:ok, true} ->
        %{name: assertion.name, passed?: true, message: assertion.message}

      {:ok, false} ->
        %{name: assertion.name, passed?: false, message: assertion.message}

      {:error, reason} ->
        %{
          name: assertion.name,
          passed?: false,
          message: "#{assertion.message} #{inspect(reason)}"
        }

      other ->
        %{name: assertion.name, passed?: truthy?(other), message: assertion.message}
    end
  rescue
    error ->
      %{
        name: assertion.name,
        passed?: false,
        message: "#{assertion.message} #{Exception.message(error)}"
      }
  catch
    kind, reason ->
      %{
        name: assertion.name,
        passed?: false,
        message: "#{assertion.message} #{inspect({kind, reason})}"
      }
  end

  defp call_predicate(predicate, inputs, prediction) when is_function(predicate, 2),
    do: predicate.(inputs, prediction)

  defp call_predicate(predicate, _inputs, prediction) when is_function(predicate, 1),
    do: predicate.(prediction)

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_other), do: true

  defp to_message(nil, fallback), do: fallback
  defp to_message("", fallback), do: fallback
  defp to_message(message, _fallback) when is_binary(message), do: message
  defp to_message(message, _fallback), do: inspect(message)

  defp maybe_update_best(%{best: nil} = state, prediction, evaluation),
    do: %{state | best: {prediction, evaluation}}

  defp maybe_update_best(%{best: {_prediction, best_eval}} = state, prediction, evaluation) do
    if evaluation.score > best_eval.score,
      do: %{state | best: {prediction, evaluation}},
      else: state
  end

  defp finish({:ok, _prediction} = result, _wrapper), do: result

  defp finish(%{best: {prediction, evaluation}, history: history}, %{strict: false}) do
    {:ok, attach_assertion_metadata(prediction, evaluation, history)}
  end

  defp finish(%{best: {_prediction, evaluation}, history: history}, %{strict: true}) do
    {:error, {:assertions_failed, evaluation.failures, history}}
  end

  defp finish(%{last_error: reason, history: history}, _wrapper) when not is_nil(reason) do
    {:error, reason, history}
  end

  defp finish(%{history: history}, _wrapper), do: {:error, :no_attempts, history}

  defp attach_assertion_metadata(prediction, evaluation, history) do
    prediction
    |> DSEx.Prediction.put(:assertion_score, evaluation.score)
    |> DSEx.Prediction.put(:assertion_failures, evaluation.failures)
    |> DSEx.Prediction.put(:assertion_history, history)
  end
end

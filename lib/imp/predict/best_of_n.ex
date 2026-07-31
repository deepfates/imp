defmodule Imp.Predict.BestOfN do
  @moduledoc "Run a program multiple times and keep the prediction with the highest metric score."

  alias Imp.Predict.{Attempt, Search}
  alias Imp.Predict.Search.Candidate

  defstruct [:program, :metric, :feedback_fn, :fail_count, n: 3, threshold: 1.0]

  @option_schema [
    n: [type: :non_neg_integer, default: 3],
    feedback_fn: [
      type: {:custom, __MODULE__, :validate_feedback_fn, []},
      default: nil
    ],
    fail_count: [type: {:or, [:non_neg_integer, nil]}, default: nil],
    threshold: [type: {:or, [:integer, :float, nil]}, default: 1.0]
  ]

  def new(program, metric, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.BestOfN.new/3")
    Imp.FunctionContract.validate!(metric, 2, "Imp.Predict.BestOfN.new/3", "metric")

    %__MODULE__{
      program: program,
      metric: metric,
      n: opts[:n],
      feedback_fn: opts[:feedback_fn],
      fail_count: opts[:fail_count],
      threshold: opts[:threshold]
    }
  end

  def validate_feedback_fn(nil), do: {:ok, nil}
  def validate_feedback_fn(feedback_fn) when is_function(feedback_fn, 1), do: {:ok, feedback_fn}

  def validate_feedback_fn(feedback_fn) do
    {:error, "expected nil or a unary function, got: #{inspect(feedback_fn)}"}
  end

  def call(%__MODULE__{} = best, inputs) do
    rollout_ids = Attempt.rollout_ids(best.program, best.n)

    rollout_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {rollout_id, attempt} ->
      Candidate.new(attempt, rollout_id, %{attempts: 1})
    end)
    |> Search.run(
      fn candidate, _context ->
        program = Attempt.bind(best.program, candidate.value)

        case Imp.Module.call(program, inputs) do
          # DSPy best_of_n.py: `reward = self.reward_fn(kwargs, pred)` — the
          # reward function sees the caller's actual inputs.
          {:ok, prediction} -> {:ok, prediction, Attempt.score(best.metric, inputs, prediction)}
          {:error, reason} -> {:error, reason}
        end
      end,
      mode: :sequential,
      threshold: best.threshold,
      # DSPy best_of_n.py: `fail_count = fail_count or N` — one more failure
      # than the budget aborts the whole run, even when a best exists.
      fail_budget: best.fail_count || best.n,
      tie_policy: :first
    )
    |> case do
      %{stop_reason: {:fail_budget_exceeded, _id}, outcomes: outcomes} ->
        last_error = outcomes |> Enum.reverse() |> Enum.find_value(&Map.get(&1, :error))
        {:error, {:best_of_n_fail_count_exceeded, last_error}}

      %{best: nil, outcomes: outcomes} ->
        errors = Enum.map(outcomes, &%{attempt: &1.candidate_id, error: &1.error})
        {:error, no_successful_predictions_error(rollout_ids, errors)}

      %{best: %{value: prediction}, outcomes: outcomes} ->
        predictions = for %{status: :ok, value: value} <- outcomes, do: value
        {:ok, attach_feedback(prediction, best.feedback_fn, predictions)}
    end
  end

  defp no_successful_predictions_error([], _results), do: :no_successful_predictions

  defp no_successful_predictions_error(_attempts, errors) do
    {:no_successful_predictions, errors}
  end

  defp attach_feedback(prediction, nil, _predictions), do: prediction

  defp attach_feedback(prediction, feedback_fn, predictions),
    do: Imp.Prediction.put(prediction, :feedback, safe_feedback(feedback_fn, predictions))

  defp safe_feedback(feedback_fn, predictions) do
    feedback_fn.(predictions)
  rescue
    safety in Imp.OperationalSafetyError -> raise safety
    error -> {:feedback_error, Attempt.error_message(error)}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety -> raise safety
        nil -> {:feedback_error, Attempt.error_message({kind, reason})}
      end
  end
end

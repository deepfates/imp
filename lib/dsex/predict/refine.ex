defmodule DSEx.Predict.Refine do
  @moduledoc "Iteratively call a program until a metric passes or attempts are exhausted."

  alias DSEx.Predict.{Attempt, Search}
  alias DSEx.Predict.Search.Candidate

  defstruct [:program, :metric, :feedback_fn, max_attempts: 3, threshold: 1.0]

  @option_schema [
    feedback_fn: [
      type: {:custom, __MODULE__, :validate_feedback_fn, []},
      default: nil
    ],
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
      max_attempts: opts[:max_attempts],
      threshold: opts[:threshold]
    }
  end

  def validate_feedback_fn(nil), do: {:ok, nil}
  def validate_feedback_fn(feedback_fn) when is_function(feedback_fn, 1), do: {:ok, feedback_fn}

  def validate_feedback_fn(feedback_fn) do
    {:error, "expected nil or a unary function, got: #{inspect(feedback_fn)}"}
  end

  def call(%__MODULE__{} = refine, inputs) do
    rollout_ids = Attempt.rollout_ids(refine.program, refine.max_attempts)

    rollout_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {rollout_id, attempt} ->
      Candidate.new(attempt, rollout_id, %{attempts: 1})
    end)
    |> Search.run(
      fn candidate, context ->
        history = history(context.outcomes)
        attempt_inputs = maybe_add_hint(inputs, refine.feedback_fn, history)
        program = Attempt.bind(refine.program, candidate.value)

        case DSEx.Module.call(program, attempt_inputs) do
          {:ok, prediction} -> {:ok, prediction, Attempt.score(refine.metric, prediction)}
          {:error, reason} -> {:error, reason}
        end
      end,
      mode: :sequential,
      threshold: refine.threshold,
      tie_policy: :first
    )
    |> case do
      %{best: %{value: prediction}, outcomes: outcomes} ->
        history = history(outcomes)
        {:ok, DSEx.Prediction.put(prediction, :refine_history, history)}

      %{best: nil, outcomes: []} ->
        {:error, :no_attempts, []}

      %{best: nil, outcomes: outcomes} ->
        {:error, outcomes |> List.last() |> Map.fetch!(:error), []}
    end
  end

  defp history(outcomes) do
    for %{status: :ok, candidate_id: attempt, value: prediction} <- outcomes do
      %{attempt: attempt, prediction: prediction}
    end
  end

  defp maybe_add_hint(inputs, nil, _history), do: inputs
  defp maybe_add_hint(inputs, _feedback_fn, []), do: inputs

  defp maybe_add_hint(inputs, feedback_fn, history) do
    inputs
    |> Map.new()
    |> Map.put(:hint_, safe_feedback(feedback_fn, history))
  end

  defp safe_feedback(feedback_fn, history) do
    feedback_fn.(history)
  rescue
    error -> {:feedback_error, Attempt.error_message(error)}
  catch
    kind, reason -> {:feedback_error, Attempt.error_message({kind, reason})}
  end
end

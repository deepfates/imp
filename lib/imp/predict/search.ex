defmodule Imp.Predict.Search.Candidate do
  @moduledoc """
  An explicitly identified candidate for request-local inference search.

  `projected_budget` is a non-negative, multidimensional estimate used for
  admission and accounting. It does not represent measured provider usage.
  """

  @enforce_keys [:id, :value]
  defstruct [:id, :value, projected_budget: %{}]

  @type budget :: %{optional(term()) => non_neg_integer() | float()}
  @type t :: %__MODULE__{id: term(), value: term(), projected_budget: budget()}

  @doc "Builds a candidate and validates its projected budget."
  def new(id, value, projected_budget \\ %{}) do
    if is_nil(id), do: raise(ArgumentError, "search candidate id cannot be nil")

    %__MODULE__{
      id: id,
      value: value,
      projected_budget: validate_budget!(projected_budget, "search candidate projected budget")
    }
  end

  @doc false
  def validate_budget!(budget, label) when is_map(budget) do
    Enum.each(budget, fn {dimension, amount} ->
      unless is_number(amount) and amount >= 0 do
        raise ArgumentError,
              "#{label} #{inspect(dimension)} must be a non-negative number, got: #{inspect(amount)}"
      end
    end)

    budget
  end

  def validate_budget!(budget, label) do
    raise ArgumentError, "#{label} must be a map, got: #{inspect(budget)}"
  end
end

defmodule Imp.Predict.Search.Result do
  @moduledoc """
  The ordered outcomes, provenance, selection, and projected-budget accounting
  produced by `Imp.Predict.Search.run/3`.
  """

  defstruct [
    :best,
    :stop_reason,
    outcomes: [],
    provenance: [],
    admitted_budget: %{},
    observed_budget: %{}
  ]

  @type t :: %__MODULE__{
          best: map() | nil,
          stop_reason: term(),
          outcomes: [map()],
          provenance: [map()],
          admitted_budget: map(),
          observed_budget: map()
        }
end

defmodule Imp.Predict.Search do
  @moduledoc """
  Executes a bounded candidate search owned by one inference request.

  Search supports sequential evaluation with causal prior outcomes or bounded
  concurrent evaluation, deterministic tie selection, threshold stopping,
  ordered-prefix projected budgets, task failure isolation, and complete
  candidate-order provenance. It keeps no global or persistent search state.

  Projected budgets describe caller estimates. Actual token usage, latency, and
  provider billing must be measured separately by the caller or provider.
  """

  alias Imp.Predict.Search.{Candidate, Result}

  @type evaluator :: (Candidate.t(), map() -> {:ok, term(), term()} | {:error, term()})

  @option_schema [
    mode: [type: {:in, [:sequential, :concurrent]}, default: :sequential],
    max_concurrency: [type: :pos_integer, default: System.schedulers_online()],
    timeout: [type: {:or, [:timeout, :pos_integer]}, default: :infinity],
    threshold: [type: {:or, [:integer, :float, nil]}, default: nil],
    tie_policy: [type: {:in, [:first, :last]}, default: :first],
    budget: [type: {:custom, __MODULE__, :validate_budget, []}, default: :infinity]
  ]

  @doc "Runs a bounded, deterministic candidate search."
  @spec run([Candidate.t()], evaluator(), keyword()) :: Result.t()
  def run(candidates, evaluator, opts \\ [])

  def run(candidates, evaluator, opts)
      when is_list(candidates) and is_function(evaluator, 2) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.Search.run/3")
    candidates = validate_candidates!(candidates)
    {admitted, rejected} = admit(candidates, opts[:budget])
    admitted_budget = sum_budget(admitted)

    metadata = %{
      candidate_count: length(candidates),
      admitted_count: length(admitted),
      mode: opts[:mode],
      tie_policy: opts[:tie_policy]
    }

    Imp.Telemetry.span([:imp, :predict, :search], metadata, fn ->
      {outcomes, stop_reason} = execute(admitted, evaluator, opts)
      outcomes = Enum.sort_by(outcomes, & &1.candidate_index)
      provenance = provenance(candidates, outcomes, rejected, stop_reason)

      %Result{
        best: choose_best(outcomes, opts[:tie_policy]),
        stop_reason: normalize_stop_reason(stop_reason, rejected, candidates),
        outcomes: outcomes,
        provenance: provenance,
        admitted_budget: admitted_budget,
        observed_budget: outcomes |> Enum.map(& &1.projected_budget) |> merge_budgets()
      }
    end)
  end

  def run(candidates, evaluator, _opts) do
    raise ArgumentError,
          "Imp.Predict.Search.run/3 expects a candidate list and an arity-2 evaluator, got: " <>
            "#{inspect(candidates)} and #{inspect(evaluator)}"
  end

  @doc false
  def validate_budget(:infinity), do: {:ok, :infinity}

  def validate_budget(budget) do
    {:ok, Candidate.validate_budget!(budget, "search budget")}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp validate_candidates!(candidates) do
    Enum.each(candidates, fn
      %Candidate{} -> :ok
      candidate -> raise ArgumentError, "expected a Search.Candidate, got: #{inspect(candidate)}"
    end)

    duplicate_ids =
      candidates
      |> Enum.frequencies_by(& &1.id)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_ids != [] do
      raise ArgumentError,
            "search candidate ids must be unique, duplicates: #{inspect(duplicate_ids)}"
    end

    Enum.with_index(candidates)
  end

  defp admit(indexed, :infinity), do: {indexed, []}

  defp admit(indexed, budget) do
    {admitted, rejected, _used, _exhausted?} =
      Enum.reduce(indexed, {[], [], %{}, false}, fn candidate,
                                                    {admitted, rejected, used, exhausted?} ->
        cond do
          exhausted? ->
            {admitted, rejected ++ [candidate], used, true}

          fits?(used, candidate_budget(candidate), budget) ->
            {admitted ++ [candidate], rejected, add_budget(used, candidate_budget(candidate)),
             false}

          true ->
            {admitted, rejected ++ [candidate], used, true}
        end
      end)

    {admitted, rejected}
  end

  defp execute([], _evaluator, _opts), do: {[], :completed}

  defp execute(candidates, evaluator, opts) do
    case opts[:mode] do
      :sequential -> execute_sequential(candidates, evaluator, opts)
      :concurrent -> execute_concurrent(candidates, evaluator, opts)
    end
  end

  defp execute_sequential(candidates, evaluator, opts) do
    Enum.reduce_while(candidates, {[], :completed}, fn indexed, {outcomes, _reason} ->
      outcome = run_sequential(indexed, evaluator, outcomes, opts[:timeout])
      outcomes = outcomes ++ [outcome]

      if threshold_reached?(outcome, opts[:threshold]),
        do: {:halt, {outcomes, {:threshold_reached, outcome.candidate_id}}},
        else: {:cont, {outcomes, :completed}}
    end)
  end

  defp execute_concurrent(candidates, evaluator, opts) do
    candidates
    |> Imp.Tasks.async_stream(
      fn indexed -> evaluate(indexed, evaluator, []) end,
      ordered: false,
      max_concurrency: opts[:max_concurrency],
      timeout: opts[:timeout],
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.reduce_while({[], :completed}, fn task_result, {outcomes, _reason} ->
      outcome = concurrent_outcome(task_result)
      outcomes = outcomes ++ [outcome]

      if threshold_reached?(outcome, opts[:threshold]),
        do: {:halt, {outcomes, {:threshold_reached, outcome.candidate_id}}},
        else: {:cont, {outcomes, :completed}}
    end)
  end

  defp run_sequential(indexed, evaluator, outcomes, timeout) do
    task = Imp.Tasks.async_nolink(fn -> evaluate(indexed, evaluator, outcomes) end)

    case Task.yield(task, timeout) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        failed_outcome(indexed, {:task_exit, reason})

      nil ->
        _ = Imp.Tasks.cancel(task)
        failed_outcome(indexed, :timeout, :timeout)
    end
  end

  defp evaluate({%Candidate{} = candidate, index}, evaluator, outcomes) do
    started = System.monotonic_time()
    metadata = %{candidate_id: candidate.id, candidate_index: index}

    Imp.Telemetry.execute(
      [:imp, :predict, :search, :candidate, :start],
      %{system_time: System.system_time()},
      metadata
    )

    outcome =
      try do
        case evaluator.(candidate, %{
               outcomes: outcomes,
               provenance: Enum.map(outcomes, &provenance_entry/1)
             }) do
          {:ok, value, metric_result} ->
            metric_result = Imp.Metrics.normalize_result(metric_result)

            base_outcome(candidate, index, :ok)
            |> Map.merge(%{
              value: value,
              score: metric_result.score,
              metric_result: metric_result
            })

          {:error, reason} ->
            failed_outcome({candidate, index}, reason)

          other ->
            failed_outcome({candidate, index}, {:invalid_evaluator_result, other})
        end
      rescue
        error -> failed_outcome({candidate, index}, {:exception, Exception.message(error)})
      catch
        kind, reason -> failed_outcome({candidate, index}, {kind, reason})
      end

    duration = System.monotonic_time() - started
    outcome = Map.put(outcome, :duration, duration)

    Imp.Telemetry.execute(
      [:imp, :predict, :search, :candidate, :stop],
      %{duration: duration},
      Map.put(metadata, :status, outcome.status)
    )

    outcome
  end

  defp concurrent_outcome({:ok, outcome}), do: outcome

  defp concurrent_outcome({:exit, {{candidate, index}, :timeout}}),
    do: failed_outcome({candidate, index}, :timeout, :timeout)

  defp concurrent_outcome({:exit, {{candidate, index}, reason}}),
    do: failed_outcome({candidate, index}, {:task_exit, reason})

  defp base_outcome(candidate, index, status) do
    %{
      candidate_id: candidate.id,
      candidate_index: index,
      projected_budget: candidate.projected_budget,
      status: status
    }
  end

  defp failed_outcome(indexed, reason, status \\ :error)

  defp failed_outcome({candidate, index}, reason, status),
    do: base_outcome(candidate, index, status) |> Map.put(:error, reason)

  defp threshold_reached?(%{status: :ok, score: score}, threshold) when is_number(threshold),
    do: score >= threshold

  defp threshold_reached?(_outcome, _threshold), do: false

  defp choose_best(outcomes, tie_policy) do
    Enum.reduce(outcomes, nil, fn
      %{status: :ok} = outcome, nil ->
        outcome

      %{status: :ok, score: score} = outcome, %{score: best_score} when score > best_score ->
        outcome

      %{status: :ok, score: score} = outcome, %{score: score} when tie_policy == :last ->
        outcome

      _outcome, best ->
        best
    end)
  end

  defp provenance(candidates, outcomes, rejected, stop_reason) do
    by_index = Map.new(outcomes, &{&1.candidate_index, provenance_entry(&1)})
    rejected_indexes = MapSet.new(rejected, &elem(&1, 1))

    Enum.map(candidates, fn {candidate, index} ->
      Map.get_lazy(by_index, index, fn ->
        cond do
          MapSet.member?(rejected_indexes, index) ->
            base_provenance(candidate, index, :budget_exceeded)

          match?({:threshold_reached, _id}, stop_reason) ->
            base_provenance(candidate, index, :cancelled)
            |> Map.put(:reason, stop_reason)

          true ->
            base_provenance(candidate, index, :cancelled)
        end
      end)
    end)
  end

  defp provenance_entry(outcome) do
    outcome
    |> Map.take([
      :candidate_id,
      :candidate_index,
      :projected_budget,
      :status,
      :score,
      :error,
      :duration
    ])
  end

  defp base_provenance(candidate, index, status),
    do: base_outcome(candidate, index, status) |> Map.delete(:value)

  defp normalize_stop_reason({:threshold_reached, _id} = reason, _rejected, _candidates),
    do: reason

  defp normalize_stop_reason(_reason, [_ | _] = rejected, _candidates),
    do: {:budget_exhausted, rejected |> hd() |> elem(0) |> Map.fetch!(:id)}

  defp normalize_stop_reason(_reason, _rejected, []), do: :no_candidates
  defp normalize_stop_reason(reason, _rejected, _candidates), do: reason

  defp sum_budget(indexed), do: indexed |> Enum.map(&candidate_budget/1) |> merge_budgets()
  defp candidate_budget({candidate, _index}), do: candidate.projected_budget

  defp merge_budgets(budgets), do: Enum.reduce(budgets, %{}, &add_budget(&2, &1))
  defp add_budget(left, right), do: Map.merge(left, right, fn _key, a, b -> a + b end)

  defp fits?(used, projected, limit) do
    projected
    |> add_budget(used)
    |> Enum.all?(fn {dimension, amount} -> amount <= Map.get(limit, dimension, 0) end)
  end
end

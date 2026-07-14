defmodule Imp.Optimizer.GEPA.BudgetLedger do
  @moduledoc false

  alias Imp.Optimizer.GEPA.Budget

  defstruct reservations: %{}

  @type reservation :: %{
          metric_calls: non_neg_integer(),
          full_evaluations: non_neg_integer(),
          reflection_calls: non_neg_integer()
        }

  @type t :: %__MODULE__{reservations: %{optional(String.t()) => reservation()}}

  def new, do: %__MODULE__{}

  def reserve(%__MODULE__{} = ledger, %Budget{} = budget, id, requested)
      when is_binary(id) and is_map(requested) do
    reservation = normalize!(requested)

    if Map.has_key?(ledger.reservations, id) do
      raise ArgumentError, "duplicate GEPA budget reservation #{inspect(id)}"
    end

    totals = totals(ledger)

    with :ok <- available(budget, totals, reservation, :metric_calls),
         :ok <- available(budget, totals, reservation, :full_evaluations),
         :ok <- available(budget, totals, reservation, :reflection_calls) do
      {:ok, %{ledger | reservations: Map.put(ledger.reservations, id, reservation)}}
    end
  end

  def commit(%__MODULE__{} = ledger, %Budget{} = budget, id, actual)
      when is_binary(id) and is_map(actual) do
    reservation = Map.fetch!(ledger.reservations, id)
    actual = normalize!(actual)

    Enum.each(Map.keys(reservation), fn key ->
      if actual[key] > reservation[key] do
        raise ArgumentError,
              "GEPA #{key} report #{actual[key]} exceeds reservation #{reservation[key]} for #{id}"
      end
    end)

    budget =
      Budget.commit_reserved(
        budget,
        actual.metric_calls,
        actual.full_evaluations,
        actual.reflection_calls
      )

    {budget, %{ledger | reservations: Map.delete(ledger.reservations, id)}}
  end

  def commit_ambiguous(%__MODULE__{} = ledger, %Budget{} = budget, id) do
    reservation = Map.fetch!(ledger.reservations, id)
    commit(ledger, budget, id, reservation)
  end

  def release(%__MODULE__{} = ledger, id) when is_binary(id) do
    case Map.pop(ledger.reservations, id) do
      {nil, _reservations} ->
        raise ArgumentError, "unknown GEPA budget reservation #{inspect(id)}"

      {reservation, reservations} ->
        {reservation, %{ledger | reservations: reservations}}
    end
  end

  def empty?(%__MODULE__{reservations: reservations}), do: map_size(reservations) == 0

  def dump(%__MODULE__{} = ledger) do
    ledger.reservations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {id, reservation} ->
      %{
        "id" => id,
        "metric_calls" => reservation.metric_calls,
        "full_evaluations" => reservation.full_evaluations,
        "reflection_calls" => reservation.reflection_calls
      }
    end)
  end

  def load!(entries) when is_list(entries) do
    Enum.reduce(entries, new(), fn entry, ledger ->
      id = Map.fetch!(entry, "id")

      reservation =
        normalize!(%{
          metric_calls: Map.fetch!(entry, "metric_calls"),
          full_evaluations: Map.fetch!(entry, "full_evaluations"),
          reflection_calls: Map.fetch!(entry, "reflection_calls")
        })

      if Map.has_key?(ledger.reservations, id) do
        raise ArgumentError, "duplicate GEPA budget reservation #{inspect(id)}"
      end

      %{ledger | reservations: Map.put(ledger.reservations, id, reservation)}
    end)
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid GEPA budget ledger: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(value),
    do: raise(ArgumentError, "GEPA budget ledger must be a list, got: #{inspect(value)}")

  defp totals(%__MODULE__{reservations: reservations}) do
    Enum.reduce(reservations, normalize!(%{}), fn {_id, reservation}, totals ->
      Map.new(totals, fn {key, value} -> {key, value + reservation[key]} end)
    end)
  end

  defp available(budget, totals, reservation, key) do
    used = Map.fetch!(budget, key)
    requested = used + totals[key] + reservation[key]
    limit = Map.fetch!(budget, String.to_existing_atom("max_#{key}"))

    if limit == :infinity or requested <= limit,
      do: :ok,
      else: {:error, {:budget_exhausted, key, requested, limit}}
  end

  defp normalize!(values) do
    Map.new([:metric_calls, :full_evaluations, :reflection_calls], fn key ->
      value = Map.get(values, key, 0)

      unless is_integer(value) and value >= 0 do
        raise ArgumentError, "GEPA budget reservation #{key} must be a non-negative integer"
      end

      {key, value}
    end)
  end
end

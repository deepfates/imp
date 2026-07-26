defmodule Imp.Optimizer.GEPA.Adapter do
  @moduledoc """
  Behaviour for integrating named GEPA candidates with an evaluated system.

  An adapter owns system construction, execution, scoring, and conversion of
  captured evaluation data into component-specific reflection records. Example
  failures should be represented in the returned result and trajectories;
  exceptions are reserved for systemic failures.

  Implementations are stateful structs. The functions in this module dispatch
  to the struct's module after the behaviour contract has been implemented.
  """

  alias Imp.Optimizer.GEPA.{Candidate, Result}

  @type t :: struct()
  @type reflective_dataset :: %{optional(Candidate.component_name()) => [map()]}

  @callback evaluate(t(), [term()], Candidate.t(), keyword()) :: Result.t()
  @callback make_reflective_dataset(t(), Candidate.t(), Result.t(), [Candidate.component_name()]) ::
              reflective_dataset()
  @callback metric_call_reservation(t(), [term()], Candidate.t(), keyword()) :: non_neg_integer()
  @callback batch_evaluate(t(), [{Candidate.t(), [term()]}], keyword()) :: [Result.t()]
  @callback get_adapter_state(t()) :: map()
  @callback set_adapter_state(t(), map()) :: t() | :ok
  @optional_callbacks metric_call_reservation: 4,
                      batch_evaluate: 3,
                      get_adapter_state: 1,
                      set_adapter_state: 2

  @doc "Evaluates a candidate against an ordered batch of examples."
  @spec evaluate(t(), [term()], Candidate.t(), keyword()) :: Result.t()
  def evaluate(%module{} = adapter, batch, candidate, opts) do
    module.evaluate(adapter, batch, candidate, opts)
  end

  @doc "Builds component-keyed, actionable records for reflective mutation."
  @spec make_reflective_dataset(t(), Candidate.t(), Result.t(), [Candidate.component_name()]) ::
          reflective_dataset()
  def make_reflective_dataset(%module{} = adapter, candidate, result, components_to_update) do
    module.make_reflective_dataset(adapter, candidate, result, components_to_update)
  end

  @doc "Evaluates multiple candidate/batch pairs through the adapter's grouped callback or fallback."
  @spec batch_evaluate(t(), [{Candidate.t(), [term()]}], keyword()) :: [Result.t()]
  def batch_evaluate(%module{} = adapter, items, opts \\ []) when is_list(items) do
    if function_exported?(module, :batch_evaluate, 3) do
      module.batch_evaluate(adapter, items, opts)
    else
      Enum.map(items, fn {candidate, batch} ->
        evaluate(adapter, batch, candidate, opts)
      end)
    end
  end

  @doc false
  def snapshot_state(%module{} = adapter) do
    state =
      if function_exported?(module, :get_adapter_state, 1),
        do: module.get_adapter_state(adapter),
        else: %{}

    if is_map(state),
      do: Map.new(state),
      else: raise(ArgumentError, "GEPA adapter get_adapter_state/1 must return a map")
  end

  @doc false
  def restore_state(%module{} = adapter, state) when is_map(state) do
    if function_exported?(module, :set_adapter_state, 2) do
      case module.set_adapter_state(adapter, Map.new(state)) do
        %{__struct__: ^module} = restored ->
          restored

        :ok ->
          adapter

        other ->
          raise ArgumentError,
                "GEPA adapter set_adapter_state/2 must return the adapter or :ok, got: #{inspect(other)}"
      end
    else
      adapter
    end
  end

  @doc "Returns the exact upper bound reserved before an evaluation is dispatched."
  @spec metric_call_reservation(t(), [term()], Candidate.t(), keyword()) :: non_neg_integer()
  def metric_call_reservation(%module{} = adapter, batch, candidate, opts) do
    reservation =
      if function_exported?(module, :metric_call_reservation, 4),
        do: module.metric_call_reservation(adapter, batch, candidate, opts),
        else: length(batch)

    if is_integer(reservation) and reservation >= 0 do
      reservation
    else
      raise ArgumentError,
            "GEPA adapter metric_call_reservation/4 must return a non-negative integer"
    end
  end
end

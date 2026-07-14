defmodule Imp.Optimizer.GEPA.Callback do
  @moduledoc """
  Synchronous, observational callbacks for GEPA optimization.

  This behaviour mirrors the lifecycle in GEPA `v0.1.1` while making the
  callback contract explicit for the BEAM. A callback is either a module whose
  implemented hooks have arity one, or `{module, context}` whose hooks have
  arity two. Every hook is optional and receives an event map; configured
  callbacks receive their context as the second argument.

  Callbacks run synchronously in registration order. Their return values are
  ignored, so callbacks cannot replace optimizer state or decisions. A callback
  failure is isolated, reported as redacted telemetry and a warning, and does
  not prevent later callbacks from observing the event.

      defmodule AuditCallback do
        @behaviour Imp.Optimizer.GEPA.Callback

        @impl true
        def on_iteration_end(event, owner) do
          send(owner, {:gepa_iteration, event.iteration, event.proposal_accepted})
        end
      end

      Imp.Optimizer.GEPA.new(metric, callbacks: [{AuditCallback, self()}])

  Event maps use atom keys and expose immutable Elixir values. In particular,
  `:state` and `:final_state` are snapshots by value rather than mutable handles.
  Candidate identifiers, rejection reasons, trajectories, and exceptions stay
  as native Elixir terms rather than being stringified. This is the deliberate
  Elixir equivalent of upstream's observational state access.
  """

  @events [
    :on_optimization_start,
    :on_optimization_end,
    :on_iteration_start,
    :on_iteration_end,
    :on_candidate_selected,
    :on_minibatch_sampled,
    :on_evaluation_start,
    :on_evaluation_end,
    :on_evaluation_skipped,
    :on_valset_evaluated,
    :on_reflective_dataset_built,
    :on_combee_batch_selected,
    :on_combee_aggregation,
    :on_proposal_start,
    :on_proposal_end,
    :on_candidate_accepted,
    :on_candidate_rejected,
    :on_merge_attempted,
    :on_merge_accepted,
    :on_merge_rejected,
    :on_pareto_front_updated,
    :on_state_saved,
    :on_budget_updated,
    :on_error
  ]

  @type event :: map()
  @type callback :: module() | {module(), term()}
  @type callbacks :: [callback()]

  for event <- @events do
    @callback unquote(event)(event()) :: term()
    @callback unquote(event)(event(), term()) :: term()
  end

  @optional_callbacks Enum.flat_map(@events, &[{&1, 1}, {&1, 2}])

  @doc "Returns the callback lifecycle hook names in upstream order."
  @spec events() :: [atom()]
  def events, do: @events

  @doc false
  @spec validate(term()) :: {:ok, callbacks()} | {:error, String.t()}
  def validate(callbacks) when is_list(callbacks) do
    case Enum.find(callbacks, &(not valid_callback?(&1))) do
      nil ->
        {:ok, callbacks}

      invalid ->
        {:error,
         "expected callback modules or {module, context} tuples, got: #{inspect(invalid)}"}
    end
  end

  def validate(callbacks),
    do: {:error, "expected a list of callback modules, got: #{inspect(callbacks)}"}

  @doc false
  @spec notify(callbacks(), atom(), event()) :: :ok
  def notify([], event, payload) when event in @events and is_map(payload), do: :ok

  def notify(callbacks, event, payload)
      when is_list(callbacks) and event in @events and is_map(payload) do
    Enum.each(callbacks, &invoke(&1, event, payload))
  end

  defp valid_callback?(module) when is_atom(module), do: callback_module?(module)

  defp valid_callback?({module, _context}) when is_atom(module),
    do: callback_module?(module)

  defp valid_callback?(_callback), do: false

  defp callback_module?(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in List.wrap(module.module_info(:attributes)[:behaviour])
  end

  defp invoke({module, context}, event, payload) do
    if function_exported?(module, event, 2), do: safely_invoke(module, event, [payload, context])
  end

  defp invoke(module, event, payload) do
    if function_exported?(module, event, 1), do: safely_invoke(module, event, [payload])
  end

  defp safely_invoke(module, event, arguments) do
    apply(module, event, arguments)
    :ok
  rescue
    exception -> report_failure(module, event, :error, exception)
  catch
    kind, reason -> report_failure(module, event, kind, reason)
  end

  defp report_failure(module, event, kind, reason) do
    error_class = error_class(kind, reason)

    Imp.Telemetry.execute(
      [:imp, :optimizer, :gepa, :callback, :exception],
      %{count: 1},
      %{callback: module, callback_event: event, kind: kind, error_class: error_class}
    )

    Imp.Observability.log(
      :warning,
      "GEPA callback failed",
      callback: module,
      callback_event: event,
      kind: kind,
      error_class: error_class
    )

    :ok
  end

  defp error_class(:error, %{__struct__: module}), do: module
  defp error_class(kind, _reason), do: kind
end

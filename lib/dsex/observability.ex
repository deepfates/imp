defmodule DSEx.Observability do
  @moduledoc """
  Public inspection, optimizer progress, and DSEx-scoped logging controls.

  All history inspection is redacted by default. Optimizer subscriptions use
  telemetry and deliver messages without owning optimizer processes.
  """

  require Logger

  @logging_key {__MODULE__, :logging_enabled}
  @optimizer_events [
    [:dsex, :optimizer, :progress],
    [:dsex, :optimizer, :trial, :start],
    [:dsex, :optimizer, :trial, :stop],
    [:dsex, :optimizer, :trial, :exception]
  ]

  @default_trace_events [
    [:dsex, :lm, :start],
    [:dsex, :lm, :stop],
    [:dsex, :lm, :stream, :start],
    [:dsex, :lm, :stream, :chunk],
    [:dsex, :lm, :stream, :stop],
    [:dsex, :tool, :start],
    [:dsex, :tool, :stop],
    [:dsex, :retriever, :start],
    [:dsex, :retriever, :stop],
    [:dsex, :optimizer, :progress],
    [:dsex, :training, :start],
    [:dsex, :training, :stop]
  ]

  defmodule Trace do
    @moduledoc "Result and ordered, redacted telemetry events captured by `DSEx.trace/2`."
    @enforce_keys [:result, :events]
    defstruct [:result, :events]
  end

  defmodule ProgressSubscription do
    @moduledoc "Handle returned by `DSEx.Observability.subscribe_optimizer/1`."
    @enforce_keys [:id, :owner]
    defstruct [:id, :owner]
  end

  @doc "Renders signature-shaped history as readable, redacted JSON turns."
  def inspect_history(history, opts \\ []) do
    opts =
      DSEx.Options.validate!(
        opts,
        [
          limit: [type: :pos_integer, default: 10],
          redact: [type: :boolean, default: true],
          io: [type: :any, default: nil]
        ],
        "DSEx.Observability.inspect_history/2"
      )

    history = DSEx.History.new(history)
    history = if opts[:redact], do: DSEx.History.redact(history), else: history

    rendered =
      history
      |> DSEx.History.messages()
      |> Enum.take(-opts[:limit])
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {turn, index} ->
        "Turn #{index}\n" <> Jason.encode!(turn, pretty: true)
      end)

    if opts[:io], do: IO.write(opts[:io], rendered)
    rendered
  end

  @doc "Runs a function while collecting selected redacted DSEx telemetry events."
  def trace(fun, opts \\ [])

  def trace(fun, opts) when is_function(fun, 0) do
    events = Keyword.get(opts, :events, @default_trace_events)

    unless is_list(events) and Enum.all?(events, &is_list/1) do
      raise ArgumentError,
            "DSEx.Observability.trace/2 expects :events to be a list of event names"
    end

    id = "dsex-trace-#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> [] end)
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_trace_event/4, agent)

    try do
      result = fun.()
      %Trace{result: result, events: Agent.get(agent, &Enum.reverse/1)}
    after
      :telemetry.detach(id)
      Agent.stop(agent)
    end
  end

  def trace(fun, _opts) do
    raise ArgumentError,
          "DSEx.Observability.trace/2 expects a zero-arity function; got: #{inspect(fun)}"
  end

  @doc false
  def handle_trace_event(event, measurements, metadata, agent) do
    Agent.update(agent, &[{event, measurements, metadata} | &1])
  end

  @doc "Subscribes the owner process to normalized optimizer progress events."
  def subscribe_optimizer(opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    unless is_pid(owner) do
      raise ArgumentError, "DSEx.Observability.subscribe_optimizer/1 expects :owner to be a pid"
    end

    id = "dsex-optimizer-progress-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(id, @optimizer_events, &__MODULE__.handle_optimizer_event/4, owner)

    %ProgressSubscription{id: id, owner: owner}
  end

  @doc "Detaches an optimizer progress subscription."
  def unsubscribe_optimizer(%ProgressSubscription{id: id}) do
    :telemetry.detach(id)
  end

  def unsubscribe_optimizer(subscription) do
    raise ArgumentError,
          "DSEx.Observability.unsubscribe_optimizer/1 expects a ProgressSubscription; got: #{inspect(subscription)}"
  end

  @doc false
  def handle_optimizer_event(event, measurements, metadata, owner) do
    send(owner, {:dsex_optimizer_progress, event, measurements, metadata})
  end

  @doc "Enables DSEx application logging."
  def enable_logging do
    :persistent_term.put(@logging_key, true)
    :ok
  end

  @doc "Disables DSEx application logging without changing host Logger configuration."
  def disable_logging do
    :persistent_term.put(@logging_key, false)
    :ok
  end

  @doc "Returns whether DSEx-scoped logging is enabled."
  def logging_enabled?, do: :persistent_term.get(@logging_key, true)

  @doc "Emits a redacted DSEx log entry when DSEx-scoped logging is enabled."
  def log(level, message, metadata \\ []) when is_binary(message) do
    if logging_enabled?() do
      metadata = metadata |> Map.new() |> DSEx.Redaction.redact() |> Map.to_list()
      Logger.log(level, message, metadata)
    end

    :ok
  end
end

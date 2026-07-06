defmodule DSEx.Test.TelemetryHelpers do
  @moduledoc false

  def attach(event_names, opts \\ [])

  def attach(event_names, opts) when is_list(event_names) do
    ref = make_ref()
    pid = Keyword.get(opts, :pid, self())
    id = "dsex-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(id, event_names, &__MODULE__.handle_event/4, {ref, pid})

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  def attach(event_name, opts) do
    attach([event_name], opts)
  end

  def handle_event(event, measurements, metadata, {ref, pid}) do
    send(pid, {ref, event, measurements, metadata})
  end
end

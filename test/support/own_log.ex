defmodule Imp.Test.OwnLog do
  @moduledoc """
  Log capture limited to the calling process.

  `ExUnit.CaptureLog.capture_log/2` returns every log event emitted anywhere in
  the VM while its function runs. Under `async: true` that includes events from
  whichever tests happen to run at the same moment, so `refute log =~ ...` fails
  when a concurrent test logs the same words, and `assert log =~ ...` can pass
  on another test's output. `capture/1` returns only the events the calling
  process and the Tasks it started emitted, and still keeps the whole window
  off the console.
  """

  @doc "Runs `fun` and returns the formatted log events of the calling process and its Tasks."
  def capture(fun) when is_function(fun, 0) do
    ref = make_ref()
    id = :"imp_own_log_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{owner: self(), ref: ref}})

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      :logger.remove_handler(id)
    end

    collect(ref, [])
  end

  # A :logger handler runs in the process that logs, so it can read that
  # process's `$callers`: an event counts when the owner emitted it or is among
  # the callers of the process that did (a Task the owner started, at any
  # depth). Each event is sent before the logging call returns, so the owner's
  # and its awaited children's events are in its mailbox when `fun` returns.
  @doc false
  def log(%{meta: meta} = event, %{config: %{owner: owner, ref: ref}}) do
    if meta[:pid] == owner or owner in Process.get(:"$callers", []) do
      send(owner, {ref, :logger_formatter.format(event, %{single_line: false, template: [:msg]})})
    end

    :ok
  end

  defp collect(ref, acc) do
    receive do
      {^ref, chardata} -> collect(ref, [acc, chardata, ?\n])
    after
      0 -> IO.chardata_to_string(acc)
    end
  end
end

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

  One `:logger` handler, installed once by `install/0` before the tests start,
  serves every capture; a capture only registers itself in a table. A handler
  per capture would be added and removed while other tests log, and OTP's
  `logger_server` reads the handler list for a removal before it runs and
  writes that list back afterwards, so a handler added in between is dropped
  from the list and its capture sees nothing.
  """

  @handler :imp_own_log
  @table :imp_own_log_captures

  @doc "Creates the capture table and installs the handler. Called once, from test_helper.exs."
  def install do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    :ok = :logger.add_handler(@handler, __MODULE__, %{})
  end

  @doc "Runs `fun` and returns the formatted log events of the calling process and its Tasks."
  def capture(fun) when is_function(fun, 0) do
    ref = make_ref()
    true = :ets.insert(@table, {self(), ref})

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      :ets.delete_object(@table, {self(), ref})
    end

    collect(ref, [])
  end

  # A :logger handler runs in the process that logs, so it can read that
  # process's `$callers`: an event counts for a capture when its owner emitted
  # it or is among the callers of the process that did (a Task the owner
  # started, at any depth). Each event is sent before the logging call returns,
  # so the owner's and its awaited children's events are in its mailbox when
  # `fun` returns.
  @doc false
  def log(%{meta: meta} = event, _config) do
    captures =
      [meta[:pid] | Process.get(:"$callers", [])]
      |> Enum.uniq()
      |> Enum.flat_map(&:ets.lookup(@table, &1))

    if captures != [] do
      text = :logger_formatter.format(event, %{single_line: false, template: [:msg]})
      Enum.each(captures, fn {owner, ref} -> send(owner, {ref, text}) end)
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

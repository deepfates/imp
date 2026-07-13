defmodule DSEx.BenchmarkTruth.ParitySidecar do
  @moduledoc false

  @termination_grace_ms 500

  @type result :: {:ok, binary(), non_neg_integer()} | {:error, :timeout, binary()}

  @spec run(binary(), [binary()], keyword()) :: result()
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    caller = self()
    ref = make_ref()
    timeout = validate_timeout!(Keyword.get(opts, :timeout, :infinity))
    executable = resolve_executable!(executable)

    {:ok, worker} =
      Task.Supervisor.start_child(DSEx.UnlinkedTaskSupervisor, fn ->
        port_owner(caller, ref, executable, args, timeout)
      end)

    await_result(ref, worker)
  end

  defp await_result(ref, pid) do
    monitor_ref = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        raise "DSPy sidecar owner exited before returning a result: #{inspect(reason)}"
    end
  end

  defp port_owner(caller, ref, executable, args, timeout) do
    caller_ref = Process.monitor(caller)

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:args, args},
          {:env, [{~c"DSEX_BEAM_PORT_OWNER", ~c"1"}]}
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    timer = start_timer(timeout)
    collect(port, os_pid, caller, caller_ref, ref, timer, [])
  end

  defp collect(port, os_pid, caller, caller_ref, ref, timer, output) do
    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, caller, caller_ref, ref, timer, [data | output])

      {^port, {:exit_status, status}} ->
        cancel_timer(timer)
        Process.demonitor(caller_ref, [:flush])
        send(caller, {ref, {:ok, output(output), status}})

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        terminate(port, os_pid, output)

      :sidecar_timeout ->
        output = terminate(port, os_pid, output)
        Process.demonitor(caller_ref, [:flush])
        send(caller, {ref, {:error, :timeout, output(output)}})
    end
  end

  defp terminate(port, os_pid, output) do
    signal_process_group(os_pid, "TERM")
    deadline = System.monotonic_time(:millisecond) + @termination_grace_ms

    case drain(port, output, deadline) do
      {:exited, output} ->
        output

      {:running, output} ->
        signal_process_group(os_pid, "KILL")
        close_port(port)
        output
    end
  end

  defp drain(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> drain(port, [data | output], deadline)
      {^port, {:exit_status, _status}} -> {:exited, output}
    after
      remaining -> {:running, output}
    end
  end

  defp signal_process_group(os_pid, signal) do
    kill = System.find_executable("kill") || "/bin/kill"

    port =
      Port.open(
        {:spawn_executable, kill},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:args, ["-#{signal}", "-#{os_pid}"]}
        ]
      )

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @termination_grace_ms -> close_port(port)
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp resolve_executable!(executable) do
    cond do
      Path.type(executable) == :absolute and File.regular?(executable) -> executable
      resolved = System.find_executable(executable) -> resolved
      true -> raise ArgumentError, "executable not found: #{executable}"
    end
  end

  defp output(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp start_timer(:infinity), do: nil
  defp start_timer(timeout), do: Process.send_after(self(), :sidecar_timeout, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)

  defp validate_timeout!(:infinity), do: :infinity
  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout!(timeout) do
    raise ArgumentError,
          "sidecar timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
  end
end

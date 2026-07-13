defmodule DSEx.BenchmarkTruth.ParitySidecar do
  @moduledoc false

  @termination_grace_ms 500
  @kill_grace_ms 500
  @process_group_probe_ms 20
  @signal_command_timeout_ms 500
  @default_output_limit_bytes 256 * 1024
  @signal_output_limit_bytes 4 * 1024
  @redacted "[REDACTED]"

  defmodule Output do
    @moduledoc false

    @enforce_keys [:text, :truncated, :total_bytes, :captured_bytes, :limit_bytes]
    defstruct [:text, :truncated, :total_bytes, :captured_bytes, :limit_bytes]

    @type t :: %__MODULE__{
            text: binary(),
            truncated: boolean(),
            total_bytes: non_neg_integer(),
            captured_bytes: non_neg_integer(),
            limit_bytes: pos_integer()
          }
  end

  @type result :: {:ok, Output.t(), non_neg_integer()} | {:error, :timeout, Output.t()}

  @spec run(binary(), [binary()], keyword()) :: result()
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    caller = self()
    ref = make_ref()
    timeout = validate_timeout!(Keyword.get(opts, :timeout, :infinity))

    output_limit =
      validate_output_limit!(Keyword.get(opts, :max_output_bytes, @default_output_limit_bytes))

    secrets = validate_secrets!(Keyword.get(opts, :secrets, []))
    executable = resolve_executable!(executable)

    {:ok, worker} =
      Task.Supervisor.start_child(DSEx.UnlinkedTaskSupervisor, fn ->
        port_owner(caller, ref, executable, args, timeout, output_limit, secrets)
      end)

    await_result(ref, worker)
  end

  @doc false
  @spec diagnostic(Output.t()) :: binary()
  def diagnostic(%Output{} = output) do
    if output.truncated do
      "[sidecar output truncated: captured tail #{output.captured_bytes} of " <>
        "#{output.total_bytes} bytes; limit #{output.limit_bytes} bytes]\n#{output.text}"
    else
      output.text
    end
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

  defp port_owner(caller, ref, executable, args, timeout, output_limit, secrets) do
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
    collect(port, os_pid, caller, caller_ref, ref, timer, new_capture(output_limit), secrets)
  end

  defp collect(port, os_pid, caller, caller_ref, ref, timer, capture, secrets) do
    receive do
      {^port, {:data, data}} ->
        collect(
          port,
          os_pid,
          caller,
          caller_ref,
          ref,
          timer,
          capture(capture, data),
          secrets
        )

      {^port, {:exit_status, status}} ->
        cancel_timer(timer)
        Process.demonitor(caller_ref, [:flush])
        send(caller, {ref, {:ok, output(capture, secrets), status}})

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        _capture = terminate(port, os_pid, capture)
        :ok

      :sidecar_timeout ->
        capture = terminate(port, os_pid, capture)
        Process.demonitor(caller_ref, [:flush])
        send(caller, {ref, {:error, :timeout, output(capture, secrets)}})
    end
  end

  defp terminate(port, os_pid, capture) do
    if process_group_alive?(os_pid), do: signal_process_group!(os_pid, "TERM")

    term_deadline = System.monotonic_time(:millisecond) + @termination_grace_ms

    {capture, port_exited, group_alive} =
      await_cleanup(port, os_pid, capture, false, term_deadline)

    {capture, port_exited, group_alive} =
      if group_alive do
        signal_process_group!(os_pid, "KILL")
        kill_deadline = System.monotonic_time(:millisecond) + @kill_grace_ms
        await_cleanup(port, os_pid, capture, port_exited, kill_deadline)
      else
        {capture, port_exited, group_alive}
      end

    if group_alive do
      close_port(port)
      raise "process group #{os_pid} survived checked KILL past the cleanup deadline"
    end

    unless port_exited, do: close_port(port)
    capture
  end

  defp await_cleanup(port, os_pid, capture, port_exited, deadline) do
    group_alive = process_group_alive?(os_pid)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      not group_alive and port_exited ->
        {capture, true, false}

      remaining == 0 ->
        {capture, port_exited, group_alive}

      true ->
        receive do
          {^port, {:data, data}} ->
            await_cleanup(port, os_pid, capture(capture, data), port_exited, deadline)

          {^port, {:exit_status, _status}} ->
            await_cleanup(port, os_pid, capture, true, deadline)
        after
          min(remaining, @process_group_probe_ms) ->
            await_cleanup(port, os_pid, capture, port_exited, deadline)
        end
    end
  end

  defp process_group_alive?(os_pid) do
    case run_signal_command("0", os_pid) do
      {_output, 0} -> true
      {_output, 1} -> false
      {output, status} -> raise_signal_error("probe", os_pid, status, output)
    end
  end

  defp signal_process_group!(os_pid, signal) do
    case run_signal_command(signal, os_pid) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if process_group_alive?(os_pid) do
          raise_signal_error(signal, os_pid, status, output)
        else
          :gone
        end
    end
  end

  defp run_signal_command(signal, os_pid) do
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

    deadline = System.monotonic_time(:millisecond) + @signal_command_timeout_ms
    await_signal_command(port, new_capture(@signal_output_limit_bytes), deadline)
  end

  defp await_signal_command(port, capture, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        await_signal_command(port, capture(capture, data), deadline)

      {^port, {:exit_status, status}} ->
        {capture.tail, status}
    after
      remaining ->
        close_port(port)
        raise "process-group signal command exceeded #{@signal_command_timeout_ms}ms"
    end
  end

  defp raise_signal_error(signal, os_pid, status, output) do
    detail = output |> String.replace_invalid("?") |> String.trim()
    suffix = if detail == "", do: "", else: ": #{detail}"

    raise "process-group #{signal} for #{os_pid} failed with status #{status}#{suffix}"
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

  defp new_capture(limit), do: %{tail: "", total_bytes: 0, limit_bytes: limit}

  defp capture(capture, data) do
    data_bytes = byte_size(data)
    limit = capture.limit_bytes

    tail =
      cond do
        data_bytes >= limit ->
          data
          |> binary_part(data_bytes - limit, limit)
          |> :binary.copy()

        byte_size(capture.tail) + data_bytes <= limit ->
          capture.tail <> data

        true ->
          retained_bytes = limit - data_bytes
          offset = byte_size(capture.tail) - retained_bytes
          binary_part(capture.tail, offset, retained_bytes) <> data
      end

    %{capture | tail: tail, total_bytes: capture.total_bytes + data_bytes}
  end

  defp output(capture, secrets) do
    text = capture.tail |> String.replace_invalid("?") |> redact_diagnostic(secrets)
    captured_bytes = byte_size(capture.tail)

    %Output{
      text: text,
      truncated: capture.total_bytes > captured_bytes,
      total_bytes: capture.total_bytes,
      captured_bytes: captured_bytes,
      limit_bytes: capture.limit_bytes
    }
  end

  defp redact_diagnostic(text, secrets) do
    text
    |> redact_exact_secrets(secrets)
    |> String.replace(~r/\bsk-[A-Za-z0-9_-]{8,}\b/, @redacted)
    |> String.replace(
      ~r/\bBearer\s+[A-Za-z0-9._~+\/=\-]{12,}\b/i,
      "Bearer #{@redacted}"
    )
  end

  defp redact_exact_secrets(text, secrets) do
    secrets
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(text, fn secret, redacted -> String.replace(redacted, secret, @redacted) end)
  end

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

  defp validate_output_limit!(limit) when is_integer(limit) and limit > 0, do: limit

  defp validate_output_limit!(limit) do
    raise ArgumentError,
          "sidecar output limit must be a positive integer, got: #{inspect(limit)}"
  end

  defp validate_secrets!(secrets) when is_list(secrets) do
    secrets
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      secret when is_binary(secret) and secret != "" ->
        secret

      invalid ->
        raise ArgumentError, "sidecar secrets must be non-empty strings: #{inspect(invalid)}"
    end)
    |> Enum.uniq()
  end

  defp validate_secrets!(secrets) do
    raise ArgumentError, "sidecar secrets must be a list, got: #{inspect(secrets)}"
  end
end

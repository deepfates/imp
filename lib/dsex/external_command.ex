defmodule DSEx.ExternalCommand.Handle do
  @moduledoc "A supervised external process group managed by `DSEx.ExternalCommand`."
  @enforce_keys [:owner, :os_pid, :ref]
  defstruct [:owner, :os_pid, :ref]

  @type t :: %__MODULE__{owner: pid(), os_pid: pos_integer() | nil, ref: reference()}
end

defmodule DSEx.ExternalCommand.Lifecycle do
  @moduledoc false

  @default_timeout 60_000
  @default_kill_grace 1_000
  @default_max_output 32_768
  @group_probe_ms 20
  @signal_timeout_ms 500
  @signal_output_bytes 4_096

  defmodule Capture do
    @moduledoc false
    @enforce_keys [:text, :truncated, :total_bytes, :captured_bytes, :limit_bytes]
    defstruct [:text, :truncated, :total_bytes, :captured_bytes, :limit_bytes, :duration_ms]

    @type t :: %__MODULE__{
            text: binary(),
            truncated: boolean(),
            total_bytes: non_neg_integer(),
            captured_bytes: non_neg_integer(),
            limit_bytes: pos_integer(),
            duration_ms: non_neg_integer()
          }
  end

  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, Capture.t(), non_neg_integer()}
          | {:error, :timeout, Capture.t()}
          | {:error, term()}
  def run(executable, argv, opts \\ []) do
    with {:ok, handle} <- start_owner(executable, argv, opts, false) do
      await_result(handle.ref, handle.owner)
    end
  end

  @spec start(String.t(), [String.t()], keyword()) ::
          {:ok, DSEx.ExternalCommand.Handle.t()} | {:error, term()}
  def start(executable, argv, opts \\ []) do
    start_owner(executable, argv, opts, true)
  end

  @spec stop(DSEx.ExternalCommand.Handle.t(), timeout()) :: :ok | {:error, term()}
  def stop(%DSEx.ExternalCommand.Handle{} = handle, timeout \\ 10_000) do
    if Process.alive?(handle.owner) do
      stop_ref = make_ref()
      monitor_ref = Process.monitor(handle.owner)
      send(handle.owner, {:stop, self(), stop_ref})

      receive do
        {^stop_ref, :stopped} ->
          receive do
            {:DOWN, ^monitor_ref, :process, _, _} -> :ok
          after
            timeout -> {:error, :command_stop_timeout}
          end

        {:DOWN, ^monitor_ref, :process, _, _} ->
          if process_group_alive?(handle.os_pid),
            do: {:error, :command_owner_exited_before_cleanup},
            else: :ok
      after
        timeout ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, :command_stop_timeout}
      end
    else
      if process_group_alive?(handle.os_pid),
        do: {:error, :command_owner_missing_with_live_process_group},
        else: :ok
    end
  end

  defp start_owner(executable, argv, opts, require_os_pid?) do
    with :ok <- validate_command(executable, argv),
         {:ok, executable_path} <- resolve_executable(executable),
         {:ok, config} <- validate_opts(opts) do
      caller = self()
      ref = make_ref()
      started_at = System.monotonic_time(:millisecond)

      case Task.Supervisor.start_child(DSEx.UnlinkedTaskSupervisor, fn ->
             port_owner(
               caller,
               ref,
               executable_path,
               argv,
               config,
               started_at,
               require_os_pid?
             )
           end) do
        {:ok, owner} -> await_started(ref, owner)
        {:error, reason} -> {:error, {:command_owner_start_failed, reason}}
      end
    end
  end

  defp await_started(ref, owner) do
    monitor_ref = Process.monitor(owner)

    receive do
      {^ref, {:started, os_pid}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, %DSEx.ExternalCommand.Handle{owner: owner, os_pid: os_pid, ref: ref}}

      {^ref, {:error, _reason} = error} ->
        Process.demonitor(monitor_ref, [:flush])
        error

      {:DOWN, ^monitor_ref, :process, ^owner, reason} ->
        {:error, {:command_owner_failed, DSEx.Redaction.redact(inspect(reason))}}
    end
  end

  defp await_result(ref, owner) do
    monitor_ref = Process.monitor(owner)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^owner, reason} ->
        {:error, {:command_owner_failed, DSEx.Redaction.redact(inspect(reason))}}
    end
  end

  defp port_owner(caller, ref, executable, argv, config, started_at, require_os_pid?) do
    caller_ref = Process.monitor(caller)

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        {:args, argv}
      ]
      |> maybe_put_port_option(:cd, config.cd)
      |> maybe_put_port_option(:env, encode_env(config.env))

    port = Port.open({:spawn_executable, executable}, port_opts)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    if require_os_pid? and not valid_os_pid?(os_pid) do
      close_port(port)
      Process.demonitor(caller_ref, [:flush])
      send(caller, {ref, {:error, :command_os_pid_unavailable}})
    else
      send(caller, {ref, {:started, os_pid}})

      timer = start_timer(config.timeout, started_at)
      capture = new_capture(config.max_output_bytes)

      collect(port, os_pid, caller, caller_ref, ref, timer, config, started_at, capture)
    end
  rescue
    error ->
      send(caller, {
        ref,
        {:error, {:command_start_failed, DSEx.Redaction.redact(Exception.message(error))}}
      })
  end

  defp collect(port, os_pid, caller, caller_ref, ref, timer, config, started_at, capture) do
    receive do
      {^port, {:data, data}} ->
        collect(
          port,
          os_pid,
          caller,
          caller_ref,
          ref,
          timer,
          config,
          started_at,
          capture(capture, data)
        )

      {^port, {:exit_status, status}} ->
        cancel_timer(timer)
        Process.demonitor(caller_ref, [:flush])
        capture = terminate_group(port, os_pid, capture, config.kill_grace_ms, true)
        send(caller, {ref, {:ok, captured_output(capture, config.secrets, started_at), status}})

      {:stop, reply_to, stop_ref} ->
        cancel_timer(timer)
        Process.demonitor(caller_ref, [:flush])
        _capture = terminate_group(port, os_pid, capture, config.kill_grace_ms, false)
        send(reply_to, {stop_ref, :stopped})
        :ok

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        _capture = terminate_group(port, os_pid, capture, config.kill_grace_ms, false)
        :ok

      :command_timeout ->
        capture = terminate_group(port, os_pid, capture, config.kill_grace_ms, false)
        Process.demonitor(caller_ref, [:flush])

        send(caller, {
          ref,
          {:error, :timeout, captured_output(capture, config.secrets, started_at)}
        })
    end
  end

  defp terminate_group(port, nil, capture, _grace_ms, port_exited?) do
    unless port_exited?, do: close_port(port)
    capture
  end

  defp terminate_group(port, os_pid, capture, grace_ms, port_exited?) do
    if process_group_alive?(os_pid), do: signal_process_group(os_pid, "TERM")
    term_deadline = System.monotonic_time(:millisecond) + grace_ms

    {capture, port_exited?, group_alive?} =
      await_cleanup(port, os_pid, capture, port_exited?, term_deadline)

    {capture, port_exited?, group_alive?} =
      if group_alive? do
        signal_process_group(os_pid, "KILL")
        kill_deadline = System.monotonic_time(:millisecond) + grace_ms
        await_cleanup(port, os_pid, capture, port_exited?, kill_deadline)
      else
        {capture, port_exited?, false}
      end

    if group_alive? do
      close_port(port)
      raise "process group #{os_pid} survived KILL past the cleanup deadline"
    end

    unless port_exited?, do: close_port(port)
    capture
  end

  defp await_cleanup(port, os_pid, capture, port_exited?, deadline) do
    group_alive? = process_group_alive?(os_pid)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      not group_alive? and port_exited? ->
        {capture, true, false}

      remaining == 0 ->
        {capture, port_exited?, group_alive?}

      true ->
        receive do
          {^port, {:data, data}} ->
            await_cleanup(port, os_pid, capture(capture, data), port_exited?, deadline)

          {^port, {:exit_status, _status}} ->
            await_cleanup(port, os_pid, capture, true, deadline)
        after
          min(remaining, @group_probe_ms) ->
            await_cleanup(port, os_pid, capture, port_exited?, deadline)
        end
    end
  end

  defp process_group_alive?(nil), do: false

  defp process_group_alive?(os_pid) do
    case run_signal_command("0", os_pid) do
      {_output, 0} -> true
      {_output, 1} -> false
      {output, status} -> raise_signal_error("probe", os_pid, status, output)
    end
  end

  defp signal_process_group(os_pid, signal) do
    case run_signal_command(signal, os_pid) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if process_group_alive?(os_pid),
          do: raise_signal_error(signal, os_pid, status, output),
          else: :gone
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

    deadline = System.monotonic_time(:millisecond) + @signal_timeout_ms
    await_signal_command(port, new_capture(@signal_output_bytes), deadline)
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
        raise "process-group signal command exceeded #{@signal_timeout_ms}ms"
    end
  end

  defp raise_signal_error(signal, os_pid, status, output) do
    detail = output |> String.replace_invalid("?") |> String.trim()
    suffix = if detail == "", do: "", else: ": #{detail}"
    raise "process-group #{signal} for #{os_pid} failed with status #{status}#{suffix}"
  end

  defp new_capture(limit), do: %{tail: <<>>, total_bytes: 0, limit_bytes: limit}

  defp capture(capture, data) do
    data_bytes = byte_size(data)
    limit = capture.limit_bytes

    tail =
      cond do
        data_bytes >= limit ->
          binary_part(data, data_bytes - limit, limit)

        byte_size(capture.tail) + data_bytes <= limit ->
          capture.tail <> data

        true ->
          retained_bytes = limit - data_bytes
          offset = byte_size(capture.tail) - retained_bytes
          binary_part(capture.tail, offset, retained_bytes) <> data
      end

    %{capture | tail: tail, total_bytes: capture.total_bytes + data_bytes}
  end

  defp captured_output(capture, secrets, started_at) do
    text =
      capture.tail
      |> String.replace_invalid("?")
      |> redact_exact_secrets(secrets)
      |> String.replace(~r/\bsk-[A-Za-z0-9_-]{8,}\b/, "[REDACTED]")
      |> String.replace(
        ~r/\bBearer\s+[A-Za-z0-9._~+\/=\-]{12,}\b/i,
        "Bearer [REDACTED]"
      )

    %Capture{
      text: text,
      truncated: capture.total_bytes > byte_size(capture.tail),
      total_bytes: capture.total_bytes,
      captured_bytes: byte_size(capture.tail),
      limit_bytes: capture.limit_bytes,
      duration_ms: max(System.monotonic_time(:millisecond) - started_at, 0)
    }
  end

  defp redact_exact_secrets(text, secrets) do
    secrets
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(text, fn secret, redacted -> String.replace(redacted, secret, "[REDACTED]") end)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp validate_command(executable, argv) when is_binary(executable) and is_list(argv) do
    cond do
      executable == "" or String.contains?(executable, <<0>>) -> {:error, :invalid_executable}
      Enum.all?(argv, &(is_binary(&1) and not String.contains?(&1, <<0>>))) -> :ok
      true -> {:error, :invalid_argv}
    end
  end

  defp validate_command(_executable, _argv), do: {:error, :invalid_command}

  defp resolve_executable(executable) do
    resolved =
      if Path.type(executable) == :absolute,
        do: executable,
        else: System.find_executable(executable)

    if is_binary(resolved) and File.regular?(resolved),
      do: {:ok, resolved},
      else: {:error, {:executable_not_found, executable}}
  end

  defp validate_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      grace = Keyword.get(opts, :kill_grace_ms, @default_kill_grace)
      max_output = Keyword.get(opts, :max_output_bytes, @default_max_output)
      cd = Keyword.get(opts, :cd)
      env = Keyword.get(opts, :env, [])
      secrets = Keyword.get(opts, :secrets, [])

      cond do
        not (timeout == :infinity or (is_integer(timeout) and timeout > 0)) ->
          {:error, :invalid_timeout}

        not (is_integer(grace) and grace > 0) ->
          {:error, :invalid_kill_grace}

        not (is_integer(max_output) and max_output > 0) ->
          {:error, :invalid_max_output_bytes}

        not (is_nil(cd) or is_binary(cd)) ->
          {:error, :invalid_command_cd}

        not valid_env?(env) ->
          {:error, :invalid_command_env}

        not valid_secrets?(secrets) ->
          {:error, :invalid_command_secrets}

        true ->
          {:ok,
           %{
             timeout: timeout,
             kill_grace_ms: grace,
             max_output_bytes: max_output,
             cd: cd,
             env: env,
             secrets: Enum.reject(secrets, &is_nil/1) |> Enum.uniq()
           }}
      end
    else
      {:error, :invalid_command_options}
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_command_options}

  defp valid_env?(env) when is_list(env),
    do:
      Enum.all?(env, fn {key, value} -> is_binary(key) and (is_binary(value) or is_nil(value)) end)

  defp valid_env?(_env), do: false

  defp valid_secrets?(secrets) when is_list(secrets),
    do: Enum.all?(secrets, &(is_nil(&1) or (is_binary(&1) and &1 != "")))

  defp valid_secrets?(_secrets), do: false

  defp valid_os_pid?(os_pid), do: is_integer(os_pid) and os_pid > 0

  defp encode_env(env) do
    encoded =
      Enum.map(env, fn {key, value} ->
        {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
      end)

    [{~c"DSEX_BEAM_PORT_OWNER", ~c"1"} | encoded]
  end

  defp start_timer(:infinity, _started_at), do: nil

  defp start_timer(timeout, started_at) do
    remaining = max(started_at + timeout - System.monotonic_time(:millisecond), 0)
    Process.send_after(self(), :command_timeout, remaining)
  end

  defp maybe_put_port_option(options, _key, nil), do: options
  defp maybe_put_port_option(options, key, value), do: [{key, value} | options]
end

defmodule DSEx.ExternalCommand do
  @moduledoc """
  Runs an executable with argv through DSEx's shared process-group lifecycle.

  The wrapper normalizes exit results and applies bounded redaction. It does not
  invoke a shell or implement a second process-management path.
  """

  alias DSEx.ExternalCommand.Lifecycle
  alias DSEx.ExternalCommand.Lifecycle.Capture

  @type result :: %{
          exit_status: non_neg_integer() | :timeout,
          output: String.t(),
          duration_ms: non_neg_integer()
        }

  @doc "Starts a managed process group and returns after its OS group identity is known."
  @spec start(String.t(), [String.t()], keyword()) ::
          {:ok, DSEx.ExternalCommand.Handle.t()} | {:error, term()}
  def start(executable, argv, opts \\ []), do: Lifecycle.start(executable, argv, opts)

  @doc "Synchronously stops a managed process group and verifies that the group is gone."
  @spec stop(DSEx.ExternalCommand.Handle.t(), timeout()) :: :ok | {:error, term()}
  def stop(%DSEx.ExternalCommand.Handle{} = handle, timeout \\ 10_000),
    do: Lifecycle.stop(handle, timeout)

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(executable, argv, opts \\ []) do
    case Lifecycle.run(executable, argv, opts) do
      {:ok, %Capture{} = capture, 0} ->
        {:ok, normalize(capture, 0)}

      {:ok, %Capture{} = capture, status} ->
        result = normalize(capture, status)
        {:error, {:exit_status, status, result}}

      {:error, :timeout, %Capture{} = capture} ->
        {:error, {:timeout, normalize(capture, :timeout)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize(capture, status) do
    output = capture.text |> DSEx.Redaction.redact() |> bounded(capture)

    %{
      exit_status: status,
      output: output,
      duration_ms: capture.duration_ms
    }
  end

  defp bounded(output, %Capture{truncated: false}), do: output

  defp bounded(output, %Capture{limit_bytes: limit}) do
    marker = "[output truncated]\n"
    marker = binary_part(marker, 0, min(byte_size(marker), limit))
    tail_bytes = max(limit - byte_size(marker), 0)

    tail =
      binary_part(
        output,
        max(byte_size(output) - tail_bytes, 0),
        min(byte_size(output), tail_bytes)
      )

    marker <> tail
  end
end

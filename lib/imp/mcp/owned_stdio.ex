defmodule Imp.MCP.OwnedStdio do
  @moduledoc false

  # The stdio transport Imp gives `ExMCP.Client` for a local MCP server: one
  # operating-system process group per connection, owned by the client that
  # opened it and gone when that client is.
  #
  # ExMCP's own stdio transport opens the server with `Port.open/2`. The server
  # then shares the BEAM's process group, and closing it signals only the one
  # process the port started. A server that ignores stdin EOF and SIGTERM, or
  # that has started children of its own, outlives the connection: an ReAct run
  # cancelled mid tool call left the server's child running
  # (`test/mcp_stdio_lifecycle_test.exs`). Here erlexec starts the server as
  # the leader of a new process group (`{:group, 0}`), and stopping it signals
  # the whole group (`:kill_group`): SIGTERM, then SIGKILL after
  # `@kill_timeout_seconds`. The process below is started by the client, so OTP
  # ends it with the client; erlexec's link to it then stops the group, so a
  # client that dies without closing takes the server with it. A descendant
  # that leaves the group on purpose (`setsid`) is not reached, and when the
  # server exits on its own erlexec sends the rest of its group SIGTERM only,
  # so a child that ignores SIGTERM outlives it. This retires if
  # ExMCP's stdio transport owns the process group itself.
  #
  # The server's environment is built here as well, because the process is
  # started here: see `child_environment/1`.

  @behaviour ExMCP.Transport

  use GenServer

  # One second is the grace a server gets to exit on SIGTERM before SIGKILL.
  # A close runs on the caller's path (a run being cancelled, a session ending),
  # and MCP servers keep no state a hard stop would corrupt.
  @kill_timeout_seconds 1
  @default_max_frame_bytes 1_048_576

  # Variables a server keeps from the host environment; everything else is the
  # descriptor's own `env`. The server should not inherit the host's secrets.
  @inherited ~w(
    HOME LANG LOGNAME NIX_SSL_CERT_FILE PATH SHELL SSL_CERT_DIR SSL_CERT_FILE
    TEMP TMP TMPDIR TZ USER
  )

  defstruct [:server, :os_pid, :max_frame_bytes]

  @type t :: %__MODULE__{server: pid(), os_pid: pos_integer(), max_frame_bytes: pos_integer()}

  # -- ExMCP.Transport ---------------------------------------------------------

  @impl ExMCP.Transport
  def connect(opts) do
    with {:ok, _started} <- Application.ensure_all_started(:erlexec),
         {:ok, server} <- GenServer.start_link(__MODULE__, opts) do
      {:ok,
       %__MODULE__{
         server: server,
         os_pid: GenServer.call(server, :os_pid),
         max_frame_bytes: max_frame_bytes(opts)
       }}
    else
      {:error, reason} -> {:error, {:connection_error, {:spawn_failed, reason}}}
    end
  end

  @impl ExMCP.Transport
  def send_message(message, %__MODULE__{} = state) when is_binary(message) do
    cond do
      byte_size(message) > state.max_frame_bytes ->
        {:error, :frame_too_large}

      String.contains?(message, "\n") ->
        {:error, {:validation_error, {:embedded_newline, "a stdio frame is one line"}}}

      true ->
        case call(state, {:send, message <> "\n"}) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, {:transport_error, {:send_failed, reason}}}
        end
    end
  end

  @impl ExMCP.Transport
  def receive_message(%__MODULE__{} = state), do: receive_message(state, :infinity)

  @doc """
  Waits up to `timeout` for the next complete JSON line. ExMCP calls this in
  the client process during the handshake, before it subscribes.
  """
  @spec receive_message(t(), timeout()) :: {:ok, binary(), t()} | {:error, term()}
  def receive_message(%__MODULE__{} = state, timeout) do
    call_timeout = if timeout == :infinity, do: :infinity, else: timeout + 5_000

    case call(state, {:receive, timeout}, call_timeout) do
      {:ok, line} -> {:ok, line, state}
      {:error, _reason} = error -> error
    end
  end

  @impl ExMCP.Transport
  def subscribe(pid, %__MODULE__{} = state) when is_pid(pid) do
    case call(state, {:subscribe, pid}) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  @impl ExMCP.Transport
  def close(%__MODULE__{server: server}) do
    GenServer.call(server, :close, (@kill_timeout_seconds + 5) * 1_000)
  catch
    :exit, _gone -> :ok
  end

  @impl ExMCP.Transport
  def connected?(%__MODULE__{server: server}) do
    GenServer.call(server, :connected?)
  catch
    :exit, _gone -> false
  end

  @impl ExMCP.Transport
  def capabilities(%__MODULE__{}), do: [:push]

  defp call(state, request, timeout \\ 5_000) do
    GenServer.call(state.server, request, timeout)
  catch
    :exit, _gone -> {:error, :closed}
  end

  # -- environment -------------------------------------------------------------

  @doc """
  The complete environment a server starts with: the inherited variables above,
  the host's `LC_*` locale settings, then the descriptor's own `env` on top.

  An OTP release puts its own `erts-*/bin` and `bin` directories at the front
  of `PATH` and names its root in `RELEASE_ROOT`. A server that is itself an
  Elixir or Erlang program (`mix run`, `elixir`, an escript) would then find
  the release's `erl`, which looks for the release's boot file and fails to
  start. Entries under `RELEASE_ROOT` are removed from the inherited `PATH`, so
  a server sees the host's `PATH` whether or not Imp runs inside a release. An
  explicit `PATH` in the descriptor's `env` is used as given.
  """
  @spec child_environment([{String.t(), String.t() | false}]) :: [{String.t(), String.t()}]
  def child_environment(explicit) do
    host = System.get_env()

    inherited =
      host
      |> Map.filter(fn {name, _value} ->
        name in @inherited or String.starts_with?(name, "LC_")
      end)
      |> Map.update("PATH", nil, &without_release(&1, host["RELEASE_ROOT"]))
      |> Map.reject(fn {_name, value} -> is_nil(value) end)

    explicit
    |> Enum.reduce(inherited, fn
      {name, false}, env -> Map.delete(env, to_string(name))
      {name, value}, env -> Map.put(env, to_string(name), to_string(value))
    end)
    |> Enum.sort()
  end

  defp without_release(path, root) when is_binary(root) and root != "" do
    root = Path.expand(root)

    path
    |> String.split(":")
    |> Enum.reject(fn entry ->
      entry != "" and Path.type(entry) == :absolute and
        (Path.expand(entry) == root or String.starts_with?(Path.expand(entry), root <> "/"))
    end)
    |> Enum.join(":")
  end

  defp without_release(path, _no_release), do: path

  # -- the owning process ------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # The server's exit arrives as a message and becomes `{:transport_closed,
    # {:process_exited, status}}` for the client, instead of ending this process.
    Process.flag(:trap_exit, true)

    [command | args] = Keyword.fetch!(opts, :command)
    env = child_environment(Keyword.get(opts, :env, []))
    executable = resolve(command, List.keyfind(env, "PATH", 0))

    exec_opts = [
      :stdin,
      {:stdout, self()},
      {:group, 0},
      :kill_group,
      {:kill_timeout, @kill_timeout_seconds},
      {:env, [:clear | env]}
      | cd(opts)
    ]

    case :exec.run_link([executable | args], exec_opts) do
      {:ok, exec_pid, os_pid} ->
        {:ok,
         %{
           exec_pid: exec_pid,
           os_pid: os_pid,
           buffer: "",
           lines: :queue.new(),
           waiting: nil,
           subscriber: nil,
           exited: nil,
           max_frame_bytes: max_frame_bytes(opts)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  def handle_call(:connected?, _from, state), do: {:reply, is_nil(state.exited), state}

  def handle_call({:send, _data}, _from, %{exited: status} = state) when not is_nil(status),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:send, data}, _from, state),
    do: {:reply, :exec.send(state.os_pid, data), state}

  def handle_call({:receive, timeout}, from, state) do
    case :queue.out(state.lines) do
      {{:value, line}, lines} ->
        {:reply, {:ok, line}, %{state | lines: lines}}

      {:empty, _lines} when not is_nil(state.exited) ->
        {:reply, exited_error(state.exited), state}

      {:empty, _lines} ->
        timer =
          if timeout == :infinity, do: nil, else: Process.send_after(self(), :timeout, timeout)

        {:noreply, %{state | waiting: {from, timer}}}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Enum.each(:queue.to_list(state.lines), &push(pid, &1))
    if state.exited, do: send(pid, {:transport_closed, exited_reason(state.exited)})
    {:reply, :ok, %{state | subscriber: pid, lines: :queue.new()}}
  end

  def handle_call(:close, _from, state) do
    stop_group(state)
    {:stop, :normal, :ok, %{state | exec_pid: nil}}
  end

  @impl GenServer
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > state.max_frame_bytes and not String.contains?(buffer, "\n") do
      state = deliver_exit(%{state | buffer: ""}, :frame_too_large)
      stop_group(state)
      {:noreply, %{state | exec_pid: nil}}
    else
      {lines, rest} = split_lines(buffer)
      {:noreply, Enum.reduce(lines, %{state | buffer: rest}, &deliver_line(&2, &1))}
    end
  end

  def handle_info(:timeout, %{waiting: {from, _timer}} = state) do
    GenServer.reply(from, {:error, :handshake_timeout})
    {:noreply, %{state | waiting: nil}}
  end

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    {:noreply, %{deliver_exit(state, exit_status(reason)) | exec_pid: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- lines -------------------------------------------------------------------

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)

    lines =
      complete
      |> Enum.map(&String.trim/1)
      # A server may print a banner or log line on stdout before it speaks
      # JSON-RPC; only lines that can be JSON are frames.
      |> Enum.filter(&(String.starts_with?(&1, "{") or String.starts_with?(&1, "[")))

    {lines, rest}
  end

  defp deliver_line(%{subscriber: pid} = state, line) when is_pid(pid) do
    push(pid, line)
    state
  end

  defp deliver_line(%{waiting: {from, timer}} = state, line) do
    if timer, do: Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, line})
    %{state | waiting: nil}
  end

  defp deliver_line(state, line), do: %{state | lines: :queue.in(line, state.lines)}

  defp push(pid, line) do
    case Jason.decode(line) do
      {:ok, message} -> send(pid, {:transport_event, message})
      {:error, _invalid} -> :ok
    end
  end

  defp deliver_exit(state, status) do
    cond do
      is_pid(state.subscriber) ->
        send(state.subscriber, {:transport_closed, exited_reason(status)})

      state.waiting ->
        {from, timer} = state.waiting
        if timer, do: Process.cancel_timer(timer)
        GenServer.reply(from, exited_error(status))

      true ->
        :ok
    end

    %{state | exited: status, waiting: nil}
  end

  defp exited_reason(:frame_too_large), do: :frame_too_large
  defp exited_reason(status), do: {:process_exited, status}

  defp exited_error(status), do: {:error, {:connection_error, exited_reason(status)}}

  # -- process group -----------------------------------------------------------

  # `:exec.stop/1` signals the group and returns before it is gone; waiting for
  # the linked erlexec process to exit is what makes a close mean "stopped".
  defp stop_group(%{exec_pid: exec_pid}) when is_pid(exec_pid) do
    _ = :exec.stop(exec_pid)

    receive do
      {:EXIT, ^exec_pid, _reason} -> :ok
    after
      (@kill_timeout_seconds + 2) * 1_000 -> :ok
    end
  catch
    :exit, _no_manager -> :ok
  end

  defp stop_group(_state), do: :ok

  defp exit_status(:normal), do: 0

  defp exit_status({:exit_status, status}) when is_integer(status) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, signal, _core?} when is_integer(signal) -> 128 + signal
      {:signal, _signal, _core?} -> 1
    end
  end

  defp exit_status(_reason), do: 1

  # -- options -----------------------------------------------------------------

  defp resolve(command, path) do
    cond do
      Path.type(command) == :absolute ->
        command

      String.contains?(command, "/") ->
        Path.expand(command)

      true ->
        search = if path, do: elem(path, 1), else: System.get_env("PATH", "")

        search
        |> String.split(":", trim: true)
        |> Enum.map(&Path.join(&1, command))
        |> Enum.find(command, &executable?/1)
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp cd(opts) do
    case Keyword.get(opts, :cd) do
      nil -> []
      dir -> [{:cd, to_string(dir)}]
    end
  end

  defp max_frame_bytes(opts) do
    case Keyword.get(opts, :max_frame_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _default -> @default_max_frame_bytes
    end
  end
end

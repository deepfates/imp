defmodule Imp.ACP.Local do
  @moduledoc """
  Local ACP attachment to a long-running application over a private UNIX socket.

  Each accepted connection gets its own ordinary `Imp.ACP` adapter. A resident
  application supplies a program factory that attaches to its own runtime;
  closing the connection closes the adapter, not that independently owned runtime.
  `relay/2` exposes this socket as standard ACP stdio to an ordinary client.

  Existing socket paths are always refused, including stale paths. Remove a
  stale socket only after independently establishing that its owner is gone.
  The parent directory must be private (0700); an absent directory is created.
  """
  use GenServer
  import Bitwise

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = opts |> Keyword.fetch!(:socket_path) |> Path.expand()
    limit = Keyword.get(opts, :max_frame_bytes, 1_048_576)
    agent_opts = Keyword.get(opts, :agent_options, [])

    with {:ok, _} <- Application.ensure_all_started(:ex_mcp),
         :ok <- validate_limit(limit),
         :ok <- private_directory(Path.dirname(path)),
         :ok <- unused_path(path),
         {:ok, socket} <- :gen_tcp.listen(0, socket_options(path, limit)) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, stat} = File.lstat(path)
          {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
          acceptor = spawn_link(fn -> accept(socket, supervisor, agent_opts, limit) end)

          {:ok,
           %{
             socket: socket,
             path: path,
             inode: stat.inode,
             supervisor: supervisor,
             acceptor: acceptor
           }}

        {:error, reason} ->
          :gen_tcp.close(socket)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state),
    do: {:stop, {:acceptor_exit, reason}, state}

  def handle_info({:EXIT, pid, reason}, %{supervisor: pid} = state),
    do: {:stop, {:sessions_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    :gen_tcp.close(state.socket)
    Process.exit(state.acceptor, :kill)
    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor)

    case File.lstat(state.path) do
      {:ok, %{inode: inode}} when inode == state.inode -> File.rm(state.path)
      _ -> :ok
    end

    :ok
  end

  defp accept(listener, supervisor, opts, limit) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        agent_opts =
          Keyword.merge(opts,
            transport_mod: Imp.ACP.Local.Transport,
            socket: socket,
            max_frame_bytes: limit
          )

        child = %{
          id: make_ref(),
          start: {Imp.ACP, :start_link, [agent_opts]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(supervisor, child) do
          {:ok, agent} ->
            case :gen_tcp.controlling_process(socket, agent) do
              :ok -> :ok
              {:error, _} -> DynamicSupervisor.terminate_child(supervisor, agent)
            end

          {:error, _} ->
            :gen_tcp.close(socket)
        end

        accept(listener, supervisor, opts, limit)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end

  defp socket_options(path, limit),
    do: [
      :binary,
      active: false,
      packet: :line,
      packet_size: limit + 1,
      ip: {:local, String.to_charlist(path)},
      send_timeout: 5_000,
      send_timeout_close: true
    ]

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp validate_limit(_), do: {:error, :invalid_max_frame_bytes}

  defp unused_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :socket_path_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp private_directory(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)

      {:ok, %{type: :directory, mode: mode}} when (mode &&& 0o077) == 0 ->
        :ok

      {:ok, _} ->
        {:error, :socket_directory_not_private}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Relays bounded ACP frames between standard streams and a local service socket."
  def relay(path, opts \\ []) do
    limit = Keyword.get(opts, :max_frame_bytes, 1_048_576)

    with :ok <- validate_limit(limit),
         {:ok, stdio} <-
           ExMCP.ACP.Agent.Transport.Stdio.connect(Keyword.put(opts, :max_frame_bytes, limit)),
         {:ok, remote} <-
           Imp.ACP.Local.Transport.connect(socket_path: path, max_frame_bytes: limit) do
      parent = self()

      {input, input_ref} =
        spawn_monitor(fn ->
          send(
            parent,
            {:relay_done, self(),
             pump(ExMCP.ACP.Agent.Transport.Stdio, stdio, Imp.ACP.Local.Transport, remote)}
          )
        end)

      {output, output_ref} =
        spawn_monitor(fn ->
          send(
            parent,
            {:relay_done, self(),
             pump(Imp.ACP.Local.Transport, remote, ExMCP.ACP.Agent.Transport.Stdio, stdio)}
          )
        end)

      result =
        receive do
          {:relay_done, _, result} -> result
          {:DOWN, _, :process, _, reason} -> {:error, reason}
        end

      Imp.ACP.Local.Transport.close(remote)
      Process.exit(input, :kill)
      Process.exit(output, :kill)
      Process.demonitor(input_ref, [:flush])
      Process.demonitor(output_ref, [:flush])
      result
    end
  end

  defp pump(source, input, target, output) do
    case source.receive_message(input) do
      {:ok, frame, input} ->
        case target.send_message(frame, output) do
          {:ok, output} -> pump(source, input, target, output)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} when reason in [:closed, :eof] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Imp.ACP.Local.Transport do
  @moduledoc "Bounded ACP NDJSON transport over a local UNIX stream socket."
  @behaviour ExMCP.Transport
  defstruct [:socket, :max_frame_bytes]

  def connect(opts) do
    limit = Keyword.get(opts, :max_frame_bytes, 1_048_576)

    case Keyword.fetch(opts, :socket) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket, max_frame_bytes: limit}}

      :error ->
        path = opts |> Keyword.fetch!(:socket_path) |> Path.expand() |> String.to_charlist()

        case :gen_tcp.connect(
               {:local, path},
               0,
               [
                 :binary,
                 active: false,
                 packet: :line,
                 packet_size: limit + 1,
                 send_timeout: 5000,
                 send_timeout_close: true
               ],
               5000
             ) do
          {:ok, socket} -> {:ok, %__MODULE__{socket: socket, max_frame_bytes: limit}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def send_message(message, state) when byte_size(message) > state.max_frame_bytes,
    do: {:error, :frame_too_large}

  def send_message(message, state) do
    case :gen_tcp.send(state.socket, [message, "\n"]) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  def receive_message(state) do
    case :gen_tcp.recv(state.socket, 0) do
      {:ok, line} when byte_size(line) <= state.max_frame_bytes + 1 ->
        {:ok, String.trim_trailing(line, "\n"), state}

      {:ok, _} ->
        {:error, :frame_too_large}

      {:error, :emsgsize} ->
        {:error, :frame_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def close(state), do: :gen_tcp.close(state.socket)
  def connected?(state), do: match?({:ok, _}, :inet.peername(state.socket))
end

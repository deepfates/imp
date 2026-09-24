defmodule Imp.MCP.Clients do
  @moduledoc false

  # Owns live ExMCP client processes for one ACP session (or other long-lived
  # owner). Started without linking to the importer; monitors the owner so
  # session death disconnects tools, while a transient import helper can exit
  # without taking clients down. Traps exits so a single bad client cannot
  # kill the bridge or the session.
  #
  # It also lends them. One ExMCP client sends one HTTP request at a time, so a
  # server with several clients (`pool_size:`) takes several calls at once only
  # if each call has a client to itself. A tool call borrows an idle client of
  # its server (`checkout/3`), makes the call and gives it back (`checkin/2`); a
  # call that finds none idle waits in line, and one still waiting at its
  # timeout is answered `{:error, :no_idle_connection}` without anything having
  # been sent. A borrower that dies gives its client back.

  use GenServer

  @type client_entry :: {map(), pid()}

  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) when is_list(opts) do
    owner = Keyword.fetch!(opts, :owner)

    unless is_pid(owner) do
      raise ArgumentError, ":owner must be a pid"
    end

    GenServer.start(__MODULE__, opts)
  end

  @spec adopt(pid(), [client_entry()]) :: :ok
  def adopt(bridge, clients) when is_pid(bridge) and is_list(clients) do
    GenServer.call(bridge, {:adopt, clients})
  end

  @doc false
  @spec checkout(pid(), term(), timeout()) :: {:ok, pid()} | {:error, term()}
  def checkout(bridge, server, timeout) do
    ref = make_ref()

    try do
      GenServer.call(bridge, {:checkout, server, ref}, timeout)
    catch
      :exit, {:timeout, _call} ->
        # The line may have reached us after all; whatever was lent under this
        # request goes back rather than staying lent to nobody.
        GenServer.cast(bridge, {:withdraw, ref})
        {:error, :no_idle_connection}

      :exit, _reason ->
        {:error, :not_connected}
    end
  end

  @doc false
  @spec checkin(pid(), pid()) :: :ok
  def checkin(bridge, client), do: GenServer.cast(bridge, {:checkin, client})

  @spec client_pids(pid()) :: [pid()]
  def client_pids(bridge) when is_pid(bridge) do
    GenServer.call(bridge, :client_pids)
  end

  @spec stop(pid()) :: :ok
  def stop(bridge) when is_pid(bridge) do
    if Process.alive?(bridge) do
      try do
        GenServer.stop(bridge, :normal, 5_000)
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    owner_ref = Process.monitor(owner)

    {:ok,
     %{
       owner: owner,
       owner_ref: owner_ref,
       clients: [],
       idle: %{},
       lent: %{},
       waiting: %{}
     }}
  end

  @impl true
  def handle_call({:adopt, clients}, _from, state) do
    Enum.each(clients, fn {_server, client} ->
      true = Process.link(client)
    end)

    idle =
      Enum.reduce(clients, state.idle, fn {server, client}, idle ->
        Map.update(idle, server, [client], &(&1 ++ [client]))
      end)

    {:reply, :ok, %{state | clients: state.clients ++ clients, idle: idle}}
  end

  def handle_call({:checkout, server, ref}, {pid, _tag} = from, state) do
    case Map.get(state.idle, server, []) do
      [client | rest] ->
        {:reply, {:ok, client},
         lend(%{state | idle: Map.put(state.idle, server, rest)}, client, pid, ref)}

      [] ->
        if Enum.any?(state.clients, fn {key, _client} -> key == server end) do
          line = Map.get(state.waiting, server, :queue.new())
          waiting = Map.put(state.waiting, server, :queue.in({from, ref}, line))
          {:noreply, %{state | waiting: waiting}}
        else
          {:reply, {:error, :not_connected}, state}
        end
    end
  end

  def handle_call(:client_pids, _from, state) do
    pids = Enum.map(state.clients, fn {_server, client} -> client end)
    {:reply, pids, state}
  end

  @impl true
  def handle_cast({:checkin, client}, state), do: {:noreply, give_back(state, client)}

  def handle_cast({:withdraw, ref}, state) do
    waiting =
      Map.new(state.waiting, fn {server, line} ->
        {server, :queue.filter(fn {_from, waiting_ref} -> waiting_ref != ref end, line)}
      end)

    state = %{state | waiting: waiting}

    case Enum.find(state.lent, fn {_client, lease} -> lease.ref == ref end) do
      {client, _lease} -> {:noreply, give_back(state, client)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: owner_ref} = state)
      when ref == owner_ref do
    disconnect_all(state.clients)
    {:stop, :normal, %{state | clients: []}}
  end

  # A borrower that died gives back what it held.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.lent, fn {_client, lease} -> lease.monitor == monitor end) do
      {client, _lease} -> {:noreply, give_back(state, client)}
      nil -> {:noreply, state}
    end
  end

  # A client that exited is neither lent nor idle again. A server left with no
  # client at all answers its waiting calls that it is not connected.
  def handle_info({:EXIT, pid, _reason}, state) do
    {gone, clients} = Enum.split_with(state.clients, fn {_server, client} -> client == pid end)

    state = %{
      state
      | clients: clients,
        idle: Map.new(state.idle, fn {server, idle} -> {server, List.delete(idle, pid)} end)
    }

    state =
      case Map.pop(state.lent, pid) do
        {nil, _} ->
          state

        {lease, lent} ->
          Process.demonitor(lease.monitor, [:flush])
          %{state | lent: lent}
      end

    state =
      Enum.reduce(gone, state, fn {server, _client}, acc ->
        if Enum.any?(acc.clients, fn {key, _client} -> key == server end) do
          acc
        else
          {line, waiting} = Map.pop(acc.waiting, server, :queue.new())

          Enum.each(:queue.to_list(line), fn {from, _ref} ->
            GenServer.reply(from, {:error, :not_connected})
          end)

          %{acc | waiting: waiting}
        end
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp lend(state, client, borrower, ref),
    do: %{
      state
      | lent: Map.put(state.lent, client, %{monitor: Process.monitor(borrower), ref: ref})
    }

  # A client given back goes to the first call waiting for its server, or back
  # to the idle ones.
  defp give_back(state, client) do
    case Map.pop(state.lent, client) do
      {nil, _} ->
        state

      {lease, lent} ->
        Process.demonitor(lease.monitor, [:flush])
        state = %{state | lent: lent}
        server = Enum.find_value(state.clients, fn {key, pid} -> if pid == client, do: key end)
        next_in_line(state, server, client)
    end
  end

  defp next_in_line(state, nil, _client), do: state

  defp next_in_line(state, server, client) do
    case :queue.out(Map.get(state.waiting, server, :queue.new())) do
      {{:value, {{pid, _tag} = from, ref}}, line} ->
        state = %{state | waiting: Map.put(state.waiting, server, line)}

        if Process.alive?(pid) do
          GenServer.reply(from, {:ok, client})
          lend(state, client, pid, ref)
        else
          next_in_line(state, server, client)
        end

      {:empty, _line} ->
        %{state | idle: Map.update(state.idle, server, [client], &(&1 ++ [client]))}
    end
  end

  @impl true
  def terminate(_reason, state) do
    disconnect_all(state.clients)
    :ok
  end

  defp disconnect_all(clients) do
    Enum.each(clients, fn {_server, client} ->
      if is_pid(client) and Process.alive?(client), do: safe_disconnect(client)
    end)

    :ok
  end

  defp safe_disconnect(client) do
    try do
      _ = ExMCP.Client.disconnect(client)
    catch
      :exit, _reason -> :ok
    end

    try do
      if Process.alive?(client), do: ExMCP.Client.stop(client)
    catch
      :exit, _reason -> :ok
    end

    if Process.alive?(client), do: Process.exit(client, :kill)
    :ok
  end
end

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
  # been sent.
  #
  # A client whose call timed out, or whose borrower died during the call, may
  # still be waiting on that request: ExMCP's client makes the request inside
  # its own process. Lent again, it would hold the next call behind that one.
  # Such a client is retired instead (`retire/2`): closed once that request is
  # done, and a replacement dialed in the background by the function the
  # import gave for its server. Calls wait for the replacement. One that cannot be dialed leaves the server
  # a connection fewer, and a server left with none answers its calls
  # `:not_connected`.

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

  # How a server's retired connection is replaced, and how long it is given to
  # finish the request it is inside before it is killed.
  @type replacement ::
          {((-> term()) -> {:ok, pid()} | {:error, term()}), grace :: non_neg_integer()}

  @spec adopt(pid(), [client_entry()], %{optional(term()) => replacement()}) :: :ok
  def adopt(bridge, clients, replacements \\ %{})
      when is_pid(bridge) and is_list(clients) and is_map(replacements) do
    GenServer.call(bridge, {:adopt, clients, replacements})
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

  @doc false
  @spec retire(pid(), pid()) :: :ok
  def retire(bridge, client), do: GenServer.cast(bridge, {:retire, client})

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
       waiting: %{},
       replacements: %{},
       replacing: %{}
     }}
  end

  @impl true
  def handle_call({:adopt, clients, replacements}, _from, state) do
    Enum.each(clients, fn {_server, client} ->
      true = Process.link(client)
    end)

    idle =
      Enum.reduce(clients, state.idle, fn {server, client}, idle ->
        Map.update(idle, server, [client], &(&1 ++ [client]))
      end)

    {:reply, :ok,
     %{
       state
       | clients: state.clients ++ clients,
         idle: idle,
         replacements: Map.merge(state.replacements, replacements)
     }}
  end

  def handle_call({:checkout, server, ref}, {pid, _tag} = from, state) do
    case Map.get(state.idle, server, []) do
      [client | rest] ->
        {:reply, {:ok, client},
         lend(%{state | idle: Map.put(state.idle, server, rest)}, client, pid, ref)}

      [] ->
        if connected?(state, server) do
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

  def handle_cast({:retire, client}, state) do
    case Map.pop(state.lent, client) do
      {nil, _lent} ->
        {:noreply, state}

      {lease, lent} ->
        Process.demonitor(lease.monitor, [:flush])
        {:noreply, replace(%{state | lent: lent}, client)}
    end
  end

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

  # A borrower that died may have left its call out on the client it held.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.lent, fn {_client, lease} -> lease.monitor == monitor end) do
      {client, _lease} ->
        {:noreply, replace(%{state | lent: Map.delete(state.lent, client)}, client)}

      nil ->
        {:noreply, state}
    end
  end

  # A replacement dialer answers with the new client, still linked to it; the
  # bridge links it before the dialer lets go.
  def handle_info({:replacement, dialer, server, outcome}, state) do
    state = %{state | replacing: Map.delete(state.replacing, dialer)}

    state =
      case outcome do
        {:ok, client} ->
          Process.link(client)
          send(dialer, {:replacement_taken, client})
          state = %{state | clients: state.clients ++ [{server, client}]}
          next_in_line(state, server, client)

        {:error, _reason} ->
          answer_if_gone(state, server)
      end

    {:noreply, state}
  end

  # A dialer that died without answering replaced nothing.
  def handle_info({:EXIT, pid, _reason}, state) when is_map_key(state.replacing, pid) do
    {server, replacing} = Map.pop(state.replacing, pid)
    {:noreply, answer_if_gone(%{state | replacing: replacing}, server)}
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

    state = Enum.reduce(gone, state, fn {server, _client}, acc -> answer_if_gone(acc, server) end)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connected?(state, server) do
    Enum.any?(state.clients, fn {key, _client} -> key == server end) or
      Enum.any?(state.replacing, fn {_dialer, key} -> key == server end)
  end

  # A server with no client and none being dialed answers its waiting calls
  # that it is not connected.
  defp answer_if_gone(state, server) do
    if connected?(state, server) do
      state
    else
      {line, waiting} = Map.pop(state.waiting, server, :queue.new())

      Enum.each(:queue.to_list(line), fn {from, _ref} ->
        GenServer.reply(from, {:error, :not_connected})
      end)

      %{state | waiting: waiting}
    end
  end

  # The retired client may be inside a request. It is closed once that request
  # is done (`close_after_request/1`), not killed: closing its socket mid-request
  # ends an ExMCP (Cowboy) server's handler with it, so a write that would have
  # finished is left half done. Its replacement is dialed by a linked
  # process of the bridge's, which traps exits so that a dial abandoned at its
  # deadline does not take it down.
  defp replace(state, client) do
    server = Enum.find_value(state.clients, fn {key, pid} -> if pid == client, do: key end)
    Process.unlink(client)
    clients = Enum.reject(state.clients, fn {_key, pid} -> pid == client end)
    state = %{state | clients: clients}

    case {server, Map.fetch(state.replacements, server)} do
      # A client that is no longer the bridge's, or of a server whose calls
      # are not lent (only HTTP ones are), has no known bound on its request.
      {nil, _} ->
        Process.exit(client, :kill)
        state

      {_server, :error} ->
        Process.exit(client, :kill)
        answer_if_gone(state, server)

      {server, {:ok, {redial, grace}}} ->
        bridge = self()

        dialer =
          spawn_link(fn ->
            Process.flag(:trap_exit, true)
            dial_replacement(bridge, server, client, redial, grace)
          end)

        %{state | replacing: Map.put(state.replacing, dialer, server)}
    end
  end

  defp dial_replacement(bridge, server, retired, redial, grace) do
    # The replacement function takes the server's origin into the trusted
    # origins for this process before it calls back to close the retired
    # client, which held it until then.
    close = fn ->
      unless Process.get(:retired_closed) do
        Process.put(:retired_closed, true)
        close_after_request(retired, grace)
      end
    end

    outcome =
      try do
        redial.(close)
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    # Close the retired client whatever the dial did.
    close.()
    send(bridge, {:replacement, self(), server, outcome})

    with {:ok, client} <- outcome do
      receive do
        {:replacement_taken, ^client} -> Process.unlink(client)
        {:EXIT, ^bridge, _reason} -> Process.exit(client, :kill)
      end
    end
  end

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

  # Closes the client once the request it is inside, if any, is done: the
  # client handles the disconnect after its current callback returns. A
  # disconnect rather than a bare stop, because it closes the transport, and an
  # HTTP+SSE client's GET stream is a process of its own that a stop leaves
  # running. A request an HTTP+SSE client posts from a process of its own is
  # not waited for, and is not ended by the close either; it ends within the
  # same bounds. A client still busy after `grace`, which the import sets
  # longer than its request can take, is killed.
  defp close_after_request(client, grace) do
    spawn(fn ->
      try do
        GenServer.call(client, :disconnect, grace)
        GenServer.stop(client, :normal, grace)
      catch
        :exit, _reason -> Process.exit(client, :kill)
      end
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

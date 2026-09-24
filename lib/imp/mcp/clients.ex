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

  require Logger

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
       replacing: %{},
       streams: %{},
       dead: MapSet.new()
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

    state = %{
      state
      | clients: state.clients ++ clients,
        idle: idle,
        replacements: Map.merge(state.replacements, replacements)
    }

    {:reply, :ok,
     Enum.reduce(clients, state, fn {_server, client}, acc -> watch(acc, client) end)}
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

  # A client's event stream ended. ExMCP does not reopen it, and a request the
  # client posts then is answered on no stream, or not sent. An idle client is
  # replaced now; a lent one when it is given back.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when is_map_key(state.streams, monitor) do
    {client, streams} = Map.pop(state.streams, monitor)
    state = %{state | streams: streams}
    server = Enum.find_value(state.idle, fn {key, idle} -> if client in idle, do: key end)

    cond do
      server != nil ->
        idle = Map.update!(state.idle, server, &List.delete(&1, client))
        {:noreply, replace(%{state | idle: idle}, client)}

      Map.has_key?(state.lent, client) ->
        {:noreply, %{state | dead: MapSet.put(state.dead, client)}}

      true ->
        {:noreply, state}
    end
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
          state = watch(%{state | clients: state.clients ++ [{server, client}]}, client)
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
        idle: Map.new(state.idle, fn {server, idle} -> {server, List.delete(idle, pid)} end),
        dead: MapSet.delete(state.dead, pid)
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
    state = %{state | dead: MapSet.delete(state.dead, client)}
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

        if MapSet.member?(state.dead, client) do
          replace(state, client)
        else
          server = Enum.find_value(state.clients, fn {key, pid} -> if pid == client, do: key end)
          next_in_line(state, server, client)
        end
    end
  end

  # An HTTP+SSE client's event stream is a process of its own, and when it
  # ends (nothing arrived for ExMCP's idle timeout, or the server closed it)
  # the client stays up without it. ExMCP exposes no call for the stream, so
  # its pid is read from the client's state, as `requests_out/1` reads the
  # requests. This retires when ExMCP reopens an ended stream or ends the
  # client with it.
  defp watch(state, client) do
    case stream_of(client) do
      stream when is_pid(stream) ->
        %{state | streams: Map.put(state.streams, Process.monitor(stream), client)}

      nil ->
        state
    end
  end

  defp stream_of(client) do
    case :sys.get_state(client, 1_000) do
      %{transport_state: %{sse_pid: stream}} when is_pid(stream) -> stream
      _state -> nil
    end
  catch
    :exit, _reason -> nil
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

  # Closes the client once the requests it has out are done. A disconnect
  # rather than a bare stop, because it closes the transport, and a client's
  # GET stream is a process of its own that a stop leaves running. But the
  # disconnect also ends the HTTP session (a DELETE, or the close of an
  # HTTP+SSE event stream) and cancels the client's request streams, and a
  # server may end the requests in flight on them (the Python SDK's does on
  # the DELETE; ExMCP's ends a streamed request whose stream closes). A plain
  # request is made inside the client's own callback, so a disconnect waits for
  # it. A request posted from a process of the client's own is not: one that
  # asked for progress and has a stream of its own, and any post of a
  # Streamable HTTP client that keeps a standing GET stream (Imp opens none,
  # but ExMCP keeps those in the state read below). The client is free while
  # such a request is out, so the close first waits until it has none out.
  #
  # ExMCP exposes no call to ask, so the client's state is read: a request is
  # out from the moment the client takes the call (`pending_requests`, written
  # in the same callback that starts the post) until its post has ended
  # (`async_post_tasks`, and the transport's `modern_streams`). A state without
  # those fields is not read as idle: the close then waits the whole grace
  # before the disconnect. This reading retires when ExMCP's disconnect waits
  # for its own requests. Each step is given `grace`, which the import sets
  # longer than one request can take, and a client still busy after it is
  # killed.
  defp close_after_request(client, grace) do
    spawn(fn ->
      try do
        await_requests(client, System.monotonic_time(:millisecond) + grace)
        # The disconnect's own DELETE is a request too, and gets its own grace.
        GenServer.call(client, :disconnect, grace)
        GenServer.stop(client, :normal, grace)
      catch
        :exit, _reason -> Process.exit(client, :kill)
      end
    end)

    :ok
  end

  defp await_requests(client, deadline) do
    case client |> :sys.get_state(remaining(deadline)) |> requests_out() do
      0 ->
        :ok

      count when is_integer(count) ->
        if remaining(deadline) == 0, do: exit(:timeout)
        Process.sleep(50)
        await_requests(client, deadline)

      :unknown ->
        Logger.warning(
          "an MCP client's state does not say which requests it has out; " <>
            "it is closed after its whole grace"
        )

        Process.sleep(remaining(deadline))
    end
  end

  @doc false
  # The requests an `ExMCP.Client` state has out, or `:unknown` for a state
  # this does not know how to read.
  def requests_out(%{pending_requests: pending, async_post_tasks: posts} = state)
      when is_map(pending) and is_map(posts) do
    streams =
      case Map.get(state, :transport_state) do
        %{modern_streams: streams} when is_map(streams) -> map_size(streams)
        _other -> 0
      end

    map_size(pending) + map_size(posts) + streams
  end

  def requests_out(_state), do: :unknown

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

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

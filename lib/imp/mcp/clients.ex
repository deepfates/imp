defmodule Imp.MCP.Clients do
  @moduledoc false

  # Owns live ExMCP client processes for one ACP session (or other long-lived
  # owner). Started without linking to the importer; monitors the owner so
  # session death disconnects tools, while a transient import helper can exit
  # without taking clients down. Traps exits so a single bad client cannot
  # kill the bridge or the session.

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

    {:ok, %{owner: owner, owner_ref: owner_ref, clients: []}}
  end

  @impl true
  def handle_call({:adopt, clients}, _from, state) do
    Enum.each(clients, fn {_server, client} ->
      true = Process.link(client)
    end)

    {:reply, :ok, %{state | clients: state.clients ++ clients}}
  end

  def handle_call(:client_pids, _from, state) do
    pids = Enum.map(state.clients, fn {_server, client} -> client end)
    {:reply, pids, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: owner_ref} = state)
      when ref == owner_ref do
    disconnect_all(state.clients)
    {:stop, :normal, %{state | clients: []}}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    clients = Enum.reject(state.clients, fn {_server, client} -> client == pid end)
    {:noreply, %{state | clients: clients}}
  end

  def handle_info(_message, state), do: {:noreply, state}

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

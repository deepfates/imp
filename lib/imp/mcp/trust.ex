defmodule Imp.MCP.Trust do
  @moduledoc false

  # Keeps the exact origin of every open, authorized remote MCP connection in
  # ExMCP's trusted origins, and takes it out again when the last connection to
  # it ends.
  #
  # ExMCP checks every outbound HTTP request against one VM-wide policy,
  # `config :ex_mcp, :security`. An origin that is not trusted has its
  # credential headers removed and then needs consent, and the default consent
  # handler denies: an authorized server that needs an Authorization header is
  # refused before it is reached. ExMCP accepts a per-connection `security:`
  # option but does not consult it for this check, so the trust has to be in
  # the VM-wide policy while the connection is open.
  #
  # What that means: while a connection to `https://mcp.example.com:443` is
  # open, any ExMCP HTTP client in this VM, not only Imp's, may send credential
  # headers to that exact origin without consent. Nothing else is trusted: not
  # another port, scheme or host, and not an origin a server names in a
  # redirect or an SSE endpoint event, which is what the check exists to catch.
  # Imp decides which descriptors to dial before any of this (`:authorize` and
  # `:trusted_servers` in `Imp.MCP.Connections`); this only keeps ExMCP from
  # refusing the ones Imp already authorized. Origins the host configured
  # itself are left alone. This retires if ExMCP passes the per-connection
  # `security:` option to its request check.
  #
  # All changes go through this one process, so two connections opening at
  # once cannot lose each other's origin. If it crashes, its restart removes
  # every origin it had added (see `init/1`). A host that rewrites
  # `:ex_mcp, :security` itself while connections are open can remove an
  # origin this process added.

  use GenServer

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Trusts `origin` for as long as `holder` is alive. The origin is a
  `scheme://host:port` string.
  """
  @spec hold(String.t(), pid()) :: :ok
  def hold(origin, holder) when is_binary(origin) and is_pid(holder),
    do: GenServer.call(__MODULE__, {:hold, origin, holder})

  # The origins this process added are also kept outside it, so a restart after
  # a crash can take them back out. The connections that held them are not
  # known any more, so their trust ends too: a request on one of them is then
  # refused by ExMCP's check rather than trusted with nothing holding it.
  @added_key {__MODULE__, :added}

  @impl true
  def init(_opts) do
    case :persistent_term.get(@added_key, []) do
      [] -> :ok
      leftover -> put_origins(configured_origins() -- leftover)
    end

    record_added(MapSet.new())
    {:ok, %{holders: %{}, monitors: %{}, added: MapSet.new()}}
  end

  defp record_added(added) do
    list = added |> MapSet.to_list() |> Enum.sort()
    if :persistent_term.get(@added_key, nil) != list, do: :persistent_term.put(@added_key, list)
    added
  end

  @impl true
  def handle_call({:hold, origin, holder}, _from, state) do
    state =
      if Map.has_key?(state.monitors, holder),
        do: state,
        else: put_in(state.monitors[holder], Process.monitor(holder))

    state =
      update_in(
        state.holders,
        &Map.update(&1, origin, MapSet.new([holder]), fn held -> MapSet.put(held, holder) end)
      )

    added =
      if origin in configured_origins() do
        state.added
      else
        put_origins([origin | configured_origins()])
        MapSet.put(state.added, origin)
      end

    {:reply, :ok, %{state | added: record_added(added)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, holder, _reason}, state) do
    holders =
      state.holders
      |> Map.new(fn {origin, held} -> {origin, MapSet.delete(held, holder)} end)
      |> Map.reject(fn {_origin, held} -> MapSet.size(held) == 0 end)

    released = Enum.reject(state.added, &Map.has_key?(holders, &1))

    if released != [] do
      put_origins(configured_origins() -- released)
    end

    {:noreply,
     %{
       state
       | holders: holders,
         monitors: Map.delete(state.monitors, holder),
         added: record_added(MapSet.difference(state.added, MapSet.new(released)))
     }}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp configured_origins do
    case Application.get_env(:ex_mcp, :security) do
      security when is_list(security) -> Keyword.get(security, :trusted_origins, [])
      security when is_map(security) -> Map.get(security, :trusted_origins, [])
      _unset -> []
    end
  end

  defp put_origins(origins) do
    origins = Enum.uniq(origins)

    security =
      case Application.get_env(:ex_mcp, :security) do
        security when is_list(security) -> Keyword.put(security, :trusted_origins, origins)
        security when is_map(security) -> Map.put(security, :trusted_origins, origins)
        _unset -> [trusted_origins: origins]
      end

    Application.put_env(:ex_mcp, :security, security)
  end
end

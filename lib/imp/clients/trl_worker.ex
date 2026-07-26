defmodule Imp.Clients.TRLWorker do
  @moduledoc false
  use GenServer

  @registry Imp.Clients.TRLWorker.Registry
  @supervisor Imp.Clients.TRLWorker.Supervisor

  def start(config) when is_map(config) do
    key = Map.get(config, :registry_key, Map.fetch!(config, :session_id))

    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(@supervisor, {__MODULE__, config})
    end
  end

  def request(pid, request, timeout), do: GenServer.call(pid, {:request, request}, timeout)
  def stop(pid, timeout \\ 5_000), do: GenServer.call(pid, :stop, timeout)

  def child_spec(config) do
    %{
      id: {__MODULE__, Map.get(config, :registry_key, Map.fetch!(config, :session_id))},
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary
    }
  end

  def start_link(config) do
    key = Map.get(config, :registry_key, Map.fetch!(config, :session_id))
    GenServer.start_link(__MODULE__, config, name: {:via, Registry, {@registry, key}})
  end

  @impl true
  def init(config) do
    executable = config |> Map.fetch!(:python) |> Path.expand()
    script = config |> Map.fetch!(:worker_script) |> Path.expand()

    unless File.regular?(executable), do: raise(ArgumentError, "TRL Python is not a regular file")

    unless File.regular?(script),
      do: raise(ArgumentError, "TRL worker script is not a regular file")

    args = [
      script,
      "--root",
      config |> Map.fetch!(:root) |> Path.expand(),
      "--model",
      config |> Map.fetch!(:model_path) |> Path.expand(),
      "--contract",
      config |> Map.fetch!(:contract_path) |> Path.expand()
    ]

    safe_env =
      [
        {"PYTHONNOUSERSITE", "1"},
        {"PYTHONDONTWRITEBYTECODE", "1"},
        {"PYTORCH_ENABLE_MPS_FALLBACK", "0"},
        {"HF_HUB_OFFLINE", "1"},
        {"TRANSFORMERS_OFFLINE", "1"},
        {"HF_HUB_DISABLE_TELEMETRY", "1"},
        {"DISABLE_TELEMETRY", "1"},
        {"WANDB_DISABLED", "true"},
        {"TOKENIZERS_PARALLELISM", "false"}
      ]

    credential_names =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(fn name ->
        normalized = String.upcase(name)

        normalized != "TOKENIZERS_PARALLELISM" and
          Enum.any?(~w(TOKEN API_KEY PASSWORD SECRET), &String.contains?(normalized, &1))
      end)

    env =
      safe_env
      |> Kernel.++(Enum.map(credential_names, &{&1, false}))
      |> Enum.map(fn
        {name, false} -> {String.to_charlist(name), false}
        {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
      end)

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, {:packet, 4}, :exit_status, args: args, env: env]
      )

    {:ok, %{port: port}}
  end

  @impl true
  def handle_call({:request, _request}, _from, %{pending: _pending} = state) do
    {:reply, {:error, :trl_worker_request_in_flight}, state}
  end

  def handle_call({:request, request}, from, state) do
    true = Port.command(state.port, Jason.encode!(request))
    {:noreply, Map.put(state, :pending, from)}
  rescue
    error -> {:reply, {:error, {:trl_worker_write_failed, Exception.message(error)}}, state}
  end

  def handle_call(:stop, _from, state) do
    if Port.info(state.port), do: Port.close(state.port)
    {:stop, :normal, :ok, Map.delete(state, :pending)}
  end

  @impl true
  def handle_info({port, {:data, encoded}}, %{port: port, pending: from} = state) do
    reply =
      case Jason.decode(encoded) do
        {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
        {:ok, %{"ok" => false, "error" => error}} -> {:error, {:trl_worker, error}}
        {:ok, other} -> {:error, {:invalid_trl_worker_response, other}}
        {:error, error} -> {:error, {:invalid_trl_worker_json, Exception.message(error)}}
      end

    GenServer.reply(from, reply)
    {:noreply, Map.delete(state, :pending)}
  end

  def handle_info({port, {:data, _encoded}}, %{port: port} = state) do
    {:stop, :trl_worker_unsolicited_response, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if from = Map.get(state, :pending) do
      GenServer.reply(from, {:error, {:trl_worker_exit, status}})
    end

    {:stop, {:trl_worker_exit, status}, Map.delete(state, :pending)}
  end

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end

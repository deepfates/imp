defmodule DSEx.Tracking.WandB.Backend do
  @moduledoc "W&B tracking backend with serialized, mutable run state."

  @behaviour DSEx.Tracking.Backend

  alias DSEx.Tracking.WandB

  @impl true
  def start(opts) when is_list(opts) do
    constructor_opts =
      Keyword.take(opts, [:transport, :api_key, :bearer_token, :status_mode, :request_opts])

    init_opts = Keyword.get(opts, :init, %{})

    case WandB.new(constructor_opts) |> WandB.init(init_opts) do
      {:ok, client} -> Agent.start(fn -> client end)
      {:error, _reason} = error -> error
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_wandb_config, Exception.message(error)}}
  end

  @impl true
  def log(store, event) when is_pid(store) do
    update(store, fn client -> log_event(client, event) end)
  end

  @impl true
  def finish(store, status) when is_pid(store) do
    update(store, &WandB.finish(&1, status))
  after
    stop(store)
  end

  defp log_event(client, {:config, config}) when is_map(config),
    do: WandB.merge_summary(client, %{"dsex_config" => config})

  defp log_event(client, {:metrics, metrics}) when is_map(metrics),
    do: WandB.log(client, metrics)

  defp log_event(client, {:metrics, metrics, opts}) when is_map(metrics) and is_list(opts),
    do: WandB.log(client, metrics, Keyword.take(opts, [:step]))

  defp log_event(client, {:summary, summary}) when is_map(summary),
    do: WandB.merge_summary(client, summary)

  defp log_event(_client, event), do: {:error, {:unsupported_tracking_event, event}}

  defp update(store, operation) do
    Agent.get_and_update(store, fn client ->
      case operation.(client) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {{:error, reason}, client}
      end
    end)
  catch
    :exit, reason -> {:error, {:wandb_backend_exit, reason}}
  end

  defp stop(store) do
    if Process.alive?(store), do: Agent.stop(store, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end
end

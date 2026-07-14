defmodule Imp.Optimize.Anything.Tracking do
  @moduledoc false

  @behaviour Imp.Optimizer.GEPA.Callback

  alias Imp.Optimize.Anything.Config
  alias Imp.Optimizer.Report
  alias Imp.Tracking.{MLflow, Session}
  alias Imp.Tracking.WandB.Backend, as: WandBBackend

  @spec open(Config.Tracking.t()) :: {Imp.Optimizer.GEPA.Callback.callback(), Session.t()}
  def open(%Config.Tracking{} = config) do
    case Session.start(backend_specs(config)) do
      {:ok, session} ->
        {{__MODULE__, session}, session}

      {:error, reason} ->
        raise RuntimeError,
              "Optimize Anything tracking could not start: " <>
                inspect(Imp.Redaction.redact(reason))
    end
  end

  @spec close(Session.t(), Imp.Tracking.Backend.status()) :: :ok | {:error, term()}
  def close(%Session{} = session, status), do: Session.finish(session, status)

  @impl true
  def on_optimization_start(event, session) do
    Session.log(session, {:config, Report.json_safe(event.config)})
  end

  @impl true
  def on_valset_evaluated(event, session) do
    Session.log(
      session,
      {:metrics,
       %{
         validation_score: event.average_score,
         examples_evaluated: event.num_examples_evaluated,
         candidate_index: event.candidate_idx
       }, step: event.candidate_idx}
    )
  end

  @impl true
  def on_optimization_end(event, session) do
    Session.log(session, {
      :summary,
      %{
        best_candidate_index: event.best_candidate_idx,
        total_iterations: event.total_iterations,
        total_metric_calls: event.total_metric_calls
      }
    })
  end

  defp backend_specs(config) do
    []
    |> maybe_add_wandb(config)
    |> maybe_add_mlflow(config)
  end

  defp maybe_add_wandb(specs, %{use_wandb: false}), do: specs

  defp maybe_add_wandb(specs, config) do
    api_key = config.wandb_api_key || System.get_env("WANDB_API_KEY")
    init = default_wandb_project(config.wandb_init_kwargs || %{})

    specs ++
      [
        {WandBBackend,
         [
           api_key: api_key,
           transport: Imp.Tracking.Transport.Req,
           status_mode: :accurate,
           init: init
         ]}
      ]
  end

  defp maybe_add_mlflow(specs, %{use_mlflow: false}), do: specs

  defp maybe_add_mlflow(specs, config) do
    tracking_uri = config.mlflow_tracking_uri || System.get_env("MLFLOW_TRACKING_URI")

    specs ++
      [
        {MLflow,
         [
           tracking_uri: tracking_uri,
           experiment_name: config.mlflow_experiment_name || "Default",
           token: System.get_env("MLFLOW_TRACKING_TOKEN"),
           username: System.get_env("MLFLOW_TRACKING_USERNAME"),
           password: System.get_env("MLFLOW_TRACKING_PASSWORD")
         ]}
      ]
  end

  defp default_wandb_project(init) do
    if Map.has_key?(init, :project) or Map.has_key?(init, "project"),
      do: init,
      else: Map.put(init, :project, "imp-optimize-anything")
  end
end

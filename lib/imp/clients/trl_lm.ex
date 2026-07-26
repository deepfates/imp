defmodule Imp.Clients.TRLLM do
  @moduledoc """
  Local causal-LM view of the model owned by a running `TRLTrainer` session.

  It exists so Imp's ordinary program rollouts and the subsequent TRL update
  use the same pinned policy process. It cannot start a worker or download a
  model on its own.
  """

  @behaviour Imp.LM

  defstruct [
    :model,
    :worker_key,
    :artifact_sha256,
    response_field: :route,
    rollout_source: :model_generated,
    generation_mode: :sample,
    timeout: 120_000
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          worker_key: term(),
          artifact_sha256: String.t() | nil,
          response_field: atom(),
          rollout_source: :model_generated | :controlled_external,
          generation_mode: :sample | :greedy,
          timeout: pos_integer()
        }

  def generate(%__MODULE__{} = lm, messages, opts) do
    with :ok <- validate_rollout_source(lm),
         :ok <- validate_generation_mode(lm),
         [{worker, _value}] <-
           Registry.lookup(Imp.Clients.TRLWorker.Registry, lm.worker_key),
         {:ok, result} <-
           Imp.Clients.TRLWorker.request(worker, rollout_request(lm, messages, opts), lm.timeout),
         :ok <- validate_artifact_identity(lm, result),
         :ok <- validate_generation_identity(lm, result),
         completion when is_binary(completion) <- result["completion"] do
      {:ok, completion_output(lm, completion)}
    else
      [] -> {:error, :trl_worker_not_running}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_trl_generation, other}}
    end
  end

  defp validate_rollout_source(%__MODULE__{rollout_source: source})
       when source in [:model_generated, :controlled_external],
       do: :ok

  defp validate_rollout_source(%__MODULE__{rollout_source: source}),
    do: {:error, {:invalid_trl_rollout_source, source}}

  defp validate_generation_mode(%__MODULE__{generation_mode: mode})
       when mode in [:sample, :greedy],
       do: :ok

  defp validate_generation_mode(%__MODULE__{generation_mode: mode}),
    do: {:error, {:invalid_trl_generation_mode, mode}}

  defp validate_generation_identity(
         %__MODULE__{rollout_source: :model_generated, generation_mode: :sample},
         %{"generation_mode" => "sample"}
       ),
       do: :ok

  defp validate_generation_identity(
         %__MODULE__{rollout_source: :model_generated, generation_mode: :greedy},
         %{"generation_mode" => "greedy"}
       ),
       do: :ok

  defp validate_generation_identity(%__MODULE__{rollout_source: :model_generated}, result),
    do: {:error, {:trl_generation_mode_mismatch, result}}

  defp validate_generation_identity(%__MODULE__{rollout_source: :controlled_external}, _result),
    do: :ok

  defp validate_artifact_identity(%__MODULE__{artifact_sha256: nil}, _result), do: :ok

  defp validate_artifact_identity(
         %__MODULE__{model: model, artifact_sha256: expected},
         %{"model" => model, "artifact_sha256" => expected}
       )
       when is_binary(model) and is_binary(expected),
       do: :ok

  defp validate_artifact_identity(%__MODULE__{}, result),
    do: {:error, {:trl_deployment_artifact_identity_mismatch, result}}

  # Model generation is raw adapter output and must pass through the program's
  # configured parser. A controlled external rollout is explicitly a semantic
  # output-field value and remains wrapped for the deterministic conformance
  # path that supplied it.
  defp completion_output(%__MODULE__{rollout_source: :model_generated}, completion),
    do: completion

  defp completion_output(
         %__MODULE__{rollout_source: :controlled_external, response_field: field},
         completion
       ),
       do: %{field => String.trim(completion)}

  @impl true
  def generate(messages, opts) do
    case Imp.Settings.fetch!(:lm) do
      %__MODULE__{} = lm -> generate(lm, messages, opts)
      _other -> {:error, :trl_lm_not_configured}
    end
  end

  defp rollout_request(
         %__MODULE__{rollout_source: :model_generated, generation_mode: mode},
         messages,
         opts
       ) do
    %{
      "op" => "generate",
      "messages" => normalize_messages(messages),
      "rollout_id" => Keyword.get(opts, :rollout_id, 0),
      "generation_mode" => Atom.to_string(mode)
    }
  end

  defp rollout_request(%__MODULE__{rollout_source: :controlled_external}, messages, opts) do
    %{
      "op" => "controlled_completion",
      "messages" => normalize_messages(messages),
      "rollout_id" => Keyword.get(opts, :rollout_id, 0)
    }
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        "role" => message |> Map.get(:role, Map.get(message, "role")) |> to_string(),
        "content" => Map.get(message, :content, Map.get(message, "content", ""))
      }
    end)
  end
end

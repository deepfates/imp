defmodule Imp.Clients.TRLLM do
  @moduledoc """
  Local causal-LM view of the model owned by a running `TRLTrainer` session.

  It exists so Imp's ordinary program rollouts and the subsequent TRL update
  use the same pinned policy process. It cannot start a worker or download a
  model on its own.
  """

  @behaviour Imp.LM

  defstruct [:model, :worker_key, response_field: :route, timeout: 120_000]

  def generate(%__MODULE__{} = lm, messages, opts) do
    with [{worker, _value}] <-
           Registry.lookup(Imp.Clients.TRLWorker.Registry, lm.worker_key),
         {:ok, result} <-
           Imp.Clients.TRLWorker.request(
             worker,
             %{
               "op" => "generate",
               "messages" => normalize_messages(messages),
               "rollout_id" => Keyword.get(opts, :rollout_id, 0)
             },
             lm.timeout
           ),
         completion when is_binary(completion) <- result["completion"] do
      {:ok, %{lm.response_field => String.trim(completion)}}
    else
      [] -> {:error, :trl_worker_not_running}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_trl_generation, other}}
    end
  end

  @impl true
  def generate(messages, opts) do
    case Imp.Settings.fetch!(:lm) do
      %__MODULE__{} = lm -> generate(lm, messages, opts)
      _other -> {:error, :trl_lm_not_configured}
    end
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

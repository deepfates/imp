defmodule Imp.Clients.TRLLM do
  @moduledoc """
  Local causal-LM view of the model owned by a running `TRLTrainer` session.

  It exists so Imp's ordinary program rollouts and the subsequent TRL update
  use the same pinned policy process. It cannot start a worker or download a
  model on its own. Training LMs sample by default; artifact deployments are
  constructed in greedy mode. A capable single-field enum adapter may bind an
  exact finite choice set during greedy deployment, which the causal policy
  scores and selects using its own logits rather than post-hoc output repair.
  Sampled training rejects that constraint because a choice-normalized policy
  requires a different objective than TRL's ordinary token-policy GRPO.
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

  @doc false
  def response_format_capability(%__MODULE__{generation_mode: :greedy}),
    do: %Imp.LM.Capability{choice_values: true}

  def response_format_capability(%__MODULE__{}), do: Imp.LM.Capability.none()

  def generate(%__MODULE__{} = lm, messages, opts) do
    with :ok <- validate_rollout_source(lm),
         :ok <- validate_generation_mode(lm),
         :ok <- validate_choice_mode(lm, opts),
         [{worker, _value}] <-
           Registry.lookup(Imp.Clients.TRLWorker.Registry, lm.worker_key),
         {:ok, result} <-
           Imp.Clients.TRLWorker.request(worker, rollout_request(lm, messages, opts), lm.timeout),
         :ok <- validate_artifact_identity(lm, result),
         :ok <- validate_generation_identity(lm, result),
         :ok <- validate_choice_identity(opts, result),
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

  defp validate_choice_mode(%__MODULE__{generation_mode: :greedy}, _opts), do: :ok

  defp validate_choice_mode(%__MODULE__{}, opts) do
    if Keyword.has_key?(opts, :allowed_values),
      do: {:error, :trl_sampled_choice_values_unsupported},
      else: :ok
  end

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

  defp validate_choice_identity(opts, result) do
    case Keyword.get(opts, :allowed_values) do
      nil ->
        :ok

      values ->
        expected = Imp.Clients.TRLProtocol.digest(%{"allowed_values" => values})

        if result["generation_constraint"] == "allowed_values" and
             result["allowed_values_sha256"] == expected,
           do: :ok,
           else: {:error, {:trl_allowed_values_identity_mismatch, result}}
    end
  end

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
    request = %{
      "op" => "generate",
      "messages" => normalize_messages(messages),
      "rollout_id" => Keyword.get(opts, :rollout_id, 0),
      "generation_mode" => Atom.to_string(mode)
    }

    case Keyword.get(opts, :allowed_values) do
      nil ->
        request

      values ->
        validate_allowed_values!(values)

        request
        |> Map.put("allowed_values", values)
        |> Map.put(
          "allowed_values_sha256",
          Imp.Clients.TRLProtocol.digest(%{"allowed_values" => values})
        )
    end
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

  defp validate_allowed_values!(values)
       when is_list(values) and values != [] and length(values) <= 128 do
    if Enum.all?(values, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 256)) and
         Enum.uniq(values) == values do
      :ok
    else
      raise ArgumentError,
            "TRL allowed values must be unique non-empty strings of at most 256 bytes"
    end
  end

  defp validate_allowed_values!(_values) do
    raise ArgumentError, "TRL allowed values must contain between 1 and 128 choices"
  end
end

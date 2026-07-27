defmodule Imp.Clients.TrainingHTTP do
  @moduledoc false

  @retryable_statuses [408, 409, 425, 429]

  def request(transport, url, headers, body, opts, max_attempts, retry_backoff_ms)
      when is_integer(max_attempts) and max_attempts > 0 and is_integer(retry_backoff_ms) and
             retry_backoff_ms >= 0 do
    request(transport, :post, url, headers, body, opts, max_attempts, retry_backoff_ms)
  end

  def request(transport, method, url, headers, body, opts, max_attempts, retry_backoff_ms)
      when method in [:get, :post, :put, :patch, :delete] and is_integer(max_attempts) and
             max_attempts > 0 and is_integer(retry_backoff_ms) and retry_backoff_ms >= 0 do
    do_request(
      transport,
      method,
      url,
      headers,
      body,
      opts,
      max_attempts,
      retry_backoff_ms,
      1
    )
  end

  def idempotency_key(provider, model, body, nil) do
    [to_string(provider), to_string(model), IO.iodata_to_binary(body)]
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&{:ok, "imp:" <> chunk_key(&1)})
  end

  def idempotency_key(_provider, _model, _body, key) when is_binary(key) do
    if String.trim(key) == "", do: {:error, :invalid_training_idempotency_key}, else: {:ok, key}
  end

  def idempotency_key(_provider, _model, _body, _key),
    do: {:error, :invalid_training_idempotency_key}

  def put_header(headers, name, value) do
    normalized_name = String.downcase(name)

    [
      {name, value}
      | Enum.reject(headers, fn {key, _value} ->
          String.downcase(to_string(key)) == normalized_name
        end)
    ]
  end

  def redact_response(response) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> decoded |> Imp.Redaction.redact() |> Jason.encode!()
      {:error, _reason} -> Imp.Redaction.redact(response)
    end
  end

  def redact_response(response), do: Imp.Redaction.redact(response)

  defp do_request(
         transport,
         method,
         url,
         headers,
         body,
         opts,
         max_attempts,
         backoff,
         attempt
       ) do
    response = Imp.HTTP.request(transport, method, url, headers, body, opts)

    if attempt < max_attempts and retryable?(response) do
      Process.sleep(backoff * attempt)

      do_request(
        transport,
        method,
        url,
        headers,
        body,
        opts,
        max_attempts,
        backoff,
        attempt + 1
      )
    else
      response
    end
  end

  defp retryable?({:ok, %{status: status}}) when status in @retryable_statuses, do: true
  defp retryable?({:ok, %{status: status}}) when status >= 500 and status <= 599, do: true
  defp retryable?({:error, _reason}), do: true
  defp retryable?(_response), do: false

  defp chunk_key(key) do
    key
    |> String.graphemes()
    |> Enum.chunk_every(8)
    |> Enum.map_join(":", &Enum.join/1)
  end
end

defmodule Imp.Clients.TrainingJob do
  @moduledoc "Provider-neutral finetuning or reinforcement-training job."

  @active_statuses [:created, :submitted, :pending, :running]
  @terminal_statuses [:succeeded, :failed, :cancelled, :artifact_missing]

  @mlx_rebind_option_keys [
    :temperature,
    :seed,
    :max_tokens,
    :top_p,
    :stop,
    :response_format,
    :tools,
    :tool_choice,
    :parallel_tool_calls,
    :openai_parallel_tool_calls,
    :stream,
    :json_retries,
    :json_fallback,
    :timeout,
    :retries,
    :num_retries,
    :retry_backoff_ms,
    :max_retries,
    :max_completion_tokens,
    :receive_timeout,
    :cache,
    :rollout_id,
    :native_json_schema,
    :request_id,
    :req_http_options
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          model: String.t() | nil,
          status: atom() | {:unknown, String.t()},
          training_data: list(),
          result_model: String.t() | nil,
          transport: module() | function() | nil,
          status_url: String.t() | nil,
          cancel_url: String.t() | nil,
          status_method: Imp.HTTP.method(),
          cancel_method: Imp.HTTP.method(),
          status_body: :job_id | :empty,
          cancel_body: :job_id | :empty,
          api_key: String.t() | nil,
          idempotency_key: String.t() | nil,
          max_attempts: pos_integer(),
          retry_backoff_ms: non_neg_integer(),
          metadata: map()
        }

  defstruct [
    :id,
    :provider,
    :model,
    :status,
    :training_data,
    :result_model,
    :transport,
    :status_url,
    :cancel_url,
    :api_key,
    :idempotency_key,
    status_method: :post,
    cancel_method: :post,
    status_body: :job_id,
    cancel_body: :job_id,
    max_attempts: 3,
    retry_backoff_ms: 100,
    metadata: %{}
  ]

  @doc """
  Builds a provider-neutral training job.

  Status values are normalized at the boundary: common provider strings such as
  `"succeeded"`, `"completed"`, `"queued"`, and `"running"` become Imp atoms,
  while unknown external statuses remain visible as `{:unknown, value}`.

  Attributes may be an atom-key map, string-key map, or keyword list. String-key
  support is intentional because provider callbacks often start from decoded
  JSON payloads.
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = normalize_attrs!(attrs)

    job = %__MODULE__{
      id:
        fetch_attr(attrs, :id) ||
          "train-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      provider: fetch_attr(attrs, :provider, :local),
      model: fetch_attr(attrs, :model),
      status: normalize_status(fetch_attr(attrs, :status, :created)),
      training_data: fetch_attr(attrs, :training_data, []),
      result_model: fetch_attr(attrs, :result_model),
      transport: fetch_attr(attrs, :transport),
      status_url: fetch_attr(attrs, :status_url),
      cancel_url: fetch_attr(attrs, :cancel_url),
      status_method: normalize_method(fetch_attr(attrs, :status_method, :post)),
      cancel_method: normalize_method(fetch_attr(attrs, :cancel_method, :post)),
      status_body: normalize_body_mode(fetch_attr(attrs, :status_body, :job_id)),
      cancel_body: normalize_body_mode(fetch_attr(attrs, :cancel_body, :job_id)),
      api_key: fetch_attr(attrs, :api_key),
      idempotency_key: fetch_attr(attrs, :idempotency_key),
      max_attempts: fetch_attr(attrs, :max_attempts, 3),
      retry_backoff_ms: fetch_attr(attrs, :retry_backoff_ms, 100),
      metadata: fetch_attr(attrs, :metadata, %{}) |> Imp.Redaction.redact()
    }

    job
    |> validate_request_policy!()
    |> enforce_artifact()
  end

  def new(attrs) do
    raise ArgumentError,
          "Imp.Clients.TrainingJob.new/1 expects a map or keyword list; got: #{inspect(attrs)}"
  end

  def refresh(%__MODULE__{status_url: nil} = job), do: {:ok, job}

  def refresh(%__MODULE__{} = job) do
    Imp.Telemetry.span(
      [:imp, :training, :refresh],
      %{provider: job.provider, job_id: job.id},
      fn ->
        refresh_status(job)
      end
    )
  end

  @doc "Cancels a provider training job when its trainer supplied a cancellation URL."
  def cancel(%__MODULE__{cancel_url: nil}), do: {:error, :training_cancel_not_supported}

  def cancel(%__MODULE__{} = job) do
    Imp.Telemetry.span(
      [:imp, :training, :cancel],
      %{provider: job.provider, job_id: job.id},
      fn -> change_status(job, job.cancel_url, :cancel) end
    )
  end

  @doc "Returns a JSON-safe, credential-free training job checkpoint."
  def dump(%__MODULE__{} = job) do
    %{
      "type" => "imp_training_job",
      "schema_version" => 1,
      "id" => job.id,
      "provider" => job.provider,
      "model" => job.model,
      "status" => dump_status(job.status),
      "training_data" => Imp.Redaction.redact(job.training_data),
      "result_model" => job.result_model,
      "status_url" => job.status_url,
      "cancel_url" => job.cancel_url,
      "status_method" => Atom.to_string(job.status_method),
      "cancel_method" => Atom.to_string(job.cancel_method),
      "status_body" => Atom.to_string(job.status_body),
      "cancel_body" => Atom.to_string(job.cancel_body),
      "idempotency_key" => Imp.Redaction.redact(job.idempotency_key),
      "max_attempts" => job.max_attempts,
      "retry_backoff_ms" => job.retry_backoff_ms,
      "metadata" => Imp.Redaction.redact(job.metadata)
    }
    |> json_normalize!()
  end

  @doc "Restores a training job checkpoint, with transport and credentials supplied explicitly."
  def load(state, opts \\ [])

  def load(%{"type" => "imp_training_job", "schema_version" => 1} = state, opts) do
    opts = validate_load_opts!(opts)

    new(%{
      id: Map.fetch!(state, "id"),
      provider: load_provider(Map.fetch!(state, "provider")),
      model: state["model"],
      status: load_status(Map.fetch!(state, "status")),
      training_data: Map.get(state, "training_data", []),
      result_model: state["result_model"],
      transport: Keyword.get(opts, :transport),
      status_url: state["status_url"],
      cancel_url: state["cancel_url"],
      status_method: Map.get(state, "status_method", "post"),
      cancel_method: Map.get(state, "cancel_method", "post"),
      status_body: Map.get(state, "status_body", "job_id"),
      cancel_body: Map.get(state, "cancel_body", "job_id"),
      api_key: Keyword.get(opts, :api_key),
      idempotency_key: state["idempotency_key"],
      max_attempts: Map.get(state, "max_attempts", 3),
      retry_backoff_ms: Map.get(state, "retry_backoff_ms", 100),
      metadata: Map.get(state, "metadata", %{})
    })
  end

  def load(state, _opts) do
    raise ArgumentError, "invalid Imp training job checkpoint: #{inspect(state)}"
  end

  @doc "Atomically persists a credential-free training job checkpoint."
  def save!(%__MODULE__{} = job, path) when is_binary(path) do
    payload = dump(job)

    artifact = %{
      "artifact_type" => "imp_training_job_checkpoint",
      "schema_version" => 1,
      "payload_sha256" => payload_checksum(payload),
      "payload" => payload
    }

    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(artifact, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  @doc "Loads and verifies a training job checkpoint from disk."
  def load!(path, opts \\ []) when is_binary(path) do
    case path |> File.read!() |> Jason.decode!() do
      %{
        "artifact_type" => "imp_training_job_checkpoint",
        "schema_version" => 1,
        "payload_sha256" => checksum,
        "payload" => payload
      } ->
        unless is_binary(checksum) and :crypto.hash_equals(checksum, payload_checksum(payload)) do
          raise ArgumentError, "saved Imp training job checkpoint checksum mismatch"
        end

        load(payload, opts)

      state ->
        load(state, opts)
    end
  end

  @doc "Rebinds a program to the provider model artifact and optionally persists it."
  def rebind(%__MODULE__{} = job, program, opts \\ []) do
    with :ok <- validate_rebind_opts(opts),
         :ok <- validate_provider_rebind_opts(job, opts),
         :ok <- require_artifact(job),
         {:ok, lm} <- deployment_lm(job, program, opts) do
      rebound =
        program
        |> Imp.ProgramAccess.put_lm(lm)
        |> Imp.ProgramAccess.put_metadata(:training_artifact, training_artifact_metadata(job))

      case Keyword.get(opts, :path) do
        nil ->
          {:ok, rebound}

        path when is_binary(path) ->
          :ok = Imp.Saving.save!(rebound, path)
          {:ok, rebound}
      end
    end
  rescue
    error -> {:error, {:training_rebind_failed, Imp.Redaction.redact(Exception.message(error))}}
  end

  def complete(%__MODULE__{} = job, result_model),
    do: enforce_artifact(%{job | status: :succeeded, result_model: result_model})

  def fail(%__MODULE__{} = job, reason),
    do: %{
      job
      | status: :failed,
        metadata: Map.put(job.metadata, :error, Imp.Redaction.redact(reason))
    }

  @doc false
  def validate_terminal(%__MODULE__{} = job), do: enforce_artifact(job)

  @doc """
  Normalizes external provider status names into Imp job lifecycle atoms.

      iex> Imp.Clients.TrainingJob.normalize_status("completed")
      :succeeded
      iex> Imp.Clients.TrainingJob.normalize_status("queued")
      :pending
      iex> Imp.Clients.TrainingJob.normalize_status("validating_files")
      :pending
      iex> Imp.Clients.TrainingJob.normalize_status("provider-paused")
      {:unknown, "provider-paused"}
  """
  def normalize_status({:unknown, status}) when is_binary(status), do: {:unknown, status}

  def normalize_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> normalize_status()

  def normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      normalized when normalized in ["succeeded", "completed", "success"] -> :succeeded
      normalized when normalized in ["failed", "error"] -> :failed
      normalized when normalized in ["cancelled", "canceled"] -> :cancelled
      normalized when normalized in ["running", "in_progress"] -> :running
      normalized when normalized in ["pending", "queued", "validating_files"] -> :pending
      "artifact_missing" -> :artifact_missing
      "created" -> :created
      "submitted" -> :submitted
      _other -> {:unknown, status}
    end
  end

  def normalize_status(other), do: {:unknown, to_string(other)}

  @doc "Returns whether a provider status is a known nonterminal lifecycle state."
  def active_status?(status), do: normalize_status(status) in @active_statuses

  @doc "Returns whether a provider status is a known terminal lifecycle state."
  def terminal_status?(status), do: normalize_status(status) in @terminal_statuses

  defp normalize_attrs!(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        {key, value}

      invalid ->
        raise ArgumentError,
              "Imp.Clients.TrainingJob.new/1 expects attrs as atom or string keyed pairs; got entry: #{inspect(invalid)}"
    end)
  end

  defp fetch_attr(attrs, key, default \\ nil) when is_atom(key),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp refresh_status(%__MODULE__{} = job) do
    change_status(job, job.status_url, :refresh)
  end

  defp change_status(%__MODULE__{} = job, url, operation) do
    method = operation_method(job, operation)
    body = operation_body(job, operation)

    {:ok, idempotency_key} =
      Imp.Clients.TrainingHTTP.idempotency_key(
        job.provider,
        job.id,
        body,
        operation_idempotency_key(job, operation)
      )

    headers =
      if method == :get do
        auth_headers(job.api_key)
      else
        ([{"content-type", "application/json"}] ++ auth_headers(job.api_key))
        |> Imp.Clients.TrainingHTTP.put_header("idempotency-key", idempotency_key)
      end

    case Imp.Clients.TrainingHTTP.request(
           job.transport || Imp.HTTP.Hackneyless,
           method,
           url,
           headers,
           body,
           [],
           job.max_attempts,
           job.retry_backoff_ms
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        decode_status_response(job, response, operation)

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, Imp.Clients.TrainingHTTP.redact_response(response)}}

      {:error, {:http_transport_failed, _transport, reason}} ->
        {:error, {operation_failure(operation), Imp.Redaction.redact(reason)}}

      {:error, reason} ->
        {:error, Imp.Redaction.redact(reason)}

      other ->
        {:error, {invalid_operation_response(operation), other}}
    end
  rescue
    error -> {:error, {operation_failure(operation), Exception.message(error)}}
  catch
    kind, reason -> {:error, {operation_failure(operation), inspect({kind, reason})}}
  end

  defp decode_status_response(job, response, operation) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> then(&merge_status(job, &1))
        |> operation_status_result(operation)

      {:ok, decoded} ->
        {:error, {invalid_operation_response(operation), decoded}}

      {:error, reason} ->
        {:error, {invalid_operation_response(operation), Exception.message(reason)}}
    end
  end

  defp operation_status_result(%__MODULE__{status: :cancelled} = job, :cancel),
    do: {:ok, job}

  defp operation_status_result(%__MODULE__{} = job, :cancel),
    do: {:error, {:training_cancel_incomplete, job.status, job.metadata}}

  defp operation_status_result(%__MODULE__{} = job, _operation), do: {:ok, job}

  defp merge_status(job, decoded) do
    enforce_artifact(%{
      job
      | status: __MODULE__.normalize_status(decoded["status"] || decoded["state"] || job.status),
        result_model:
          decoded["fine_tuned_model"] || decoded["result_model"] || decoded["model_output"] ||
            job.result_model,
        metadata:
          Map.merge(job.metadata, %{"last_status_response" => Imp.Redaction.redact(decoded)})
    })
  end

  defp enforce_artifact(%__MODULE__{status: :succeeded, result_model: result_model} = job)
       when not is_binary(result_model) do
    %{
      job
      | status: :artifact_missing,
        metadata: Map.put(job.metadata, :error, :training_artifact_missing)
    }
  end

  defp enforce_artifact(%__MODULE__{status: :succeeded, result_model: result_model} = job) do
    if String.trim(result_model) == "" do
      %{
        job
        | status: :artifact_missing,
          metadata: Map.put(job.metadata, :error, :training_artifact_missing)
      }
    else
      job
    end
  end

  defp enforce_artifact(job), do: job

  defp require_artifact(%__MODULE__{status: :succeeded, result_model: model})
       when is_binary(model) and model != "",
       do: :ok

  defp require_artifact(%__MODULE__{status: :artifact_missing}),
    do: {:error, :training_artifact_missing}

  defp require_artifact(%__MODULE__{status: status}),
    do: {:error, {:training_not_succeeded, status}}

  defp rebound_lm(%Imp.Clients.ReqLLM{} = lm, provider, model),
    do: {:ok, %{lm | model: provider_model_spec(provider, model)}}

  defp rebound_lm(%{model: _} = lm, _provider, model), do: {:ok, Map.put(lm, :model, model)}
  defp rebound_lm(nil, _provider, _model), do: {:error, :training_program_lm_required}

  defp rebound_lm(_lm, _provider, _model),
    do: {:error, :training_program_lm_not_rebindable}

  defp provider_model_spec(:openai, "openai:" <> _model = spec), do: spec
  defp provider_model_spec(:openai, model), do: "openai:" <> model
  defp provider_model_spec(_provider, model), do: model

  defp deployment_lm(job, program, opts) do
    case Keyword.fetch(opts, :lm) do
      {:ok, lm} when not is_nil(lm) ->
        with {:ok, lm} <- validate_deployment_lm(lm),
             :ok <- validate_provider_deployment_lm(job, lm) do
          if job.provider == :mlx_lm do
            automatic_deployment_lm(job, Imp.ProgramAccess.put_lm(program, lm), opts)
          else
            {:ok, lm}
          end
        end

      _missing_or_nil ->
        automatic_deployment_lm(job, program, opts)
    end
  end

  defp automatic_deployment_lm(%__MODULE__{provider: :mlx_lm} = job, program, _opts) do
    source_lm = Imp.ProgramAccess.lm(program)

    with {:ok, manifest} <- Imp.Clients.MLXLMTrainer.verify_job(job),
         :ok <- validate_mlx_source_lm(job, source_lm, manifest),
         {:ok, lm_opts} <- mlx_runtime_options(source_lm),
         {:ok, deployment} <-
           Imp.Clients.MLXLMDeployment.start(job,
             lm_opts: lm_opts,
             req_module: Elixir.ReqLLM
           ) do
      {:ok, deployment.lm}
    end
  end

  defp automatic_deployment_lm(%__MODULE__{provider: :trl} = job, _program, opts) do
    case Keyword.fetch(opts, :trainer) do
      {:ok, %Imp.Clients.TRLTrainer{} = trainer} ->
        with {:ok, deployment} <- Imp.Clients.TRLDeployment.start(job, trainer) do
          {:ok, deployment.lm}
        end

      _missing_or_invalid ->
        {:error, :trl_rebind_requires_trusted_trainer}
    end
  end

  defp automatic_deployment_lm(job, program, _opts),
    do: rebound_lm(Imp.ProgramAccess.lm(program), job.provider, job.result_model)

  defp validate_deployment_lm(lm) do
    case Imp.LM.validate_lm(lm) do
      {:ok, lm} -> {:ok, lm}
      {:error, message} -> {:error, {:invalid_training_deployment_lm, message}}
    end
  end

  defp validate_provider_deployment_lm(%__MODULE__{provider: :mlx_lm} = job, lm) do
    with {:ok, _manifest} <- Imp.Clients.MLXLMTrainer.verify_job(job),
         {:ok, path} <- mlx_lm_model_path(lm),
         true <- Path.expand(path) == Path.expand(job.result_model) do
      :ok
    else
      false -> {:error, :mlx_lm_deployment_model_identity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_provider_deployment_lm(%__MODULE__{provider: :trl} = job, lm) do
    with {:ok, _manifest} <- Imp.Clients.TRLArtifact.verify_job(job),
         %Imp.Clients.TRLLM{artifact_sha256: artifact_sha256, worker_key: worker_key} <- lm,
         {:ok, path} <- trl_model_path(lm),
         true <- Path.expand(path) == Path.expand(job.result_model),
         true <-
           artifact_sha256 ==
             (job.metadata[:artifact_sha256] || job.metadata["artifact_sha256"]),
         [{worker, _}] when is_pid(worker) <-
           Registry.lookup(Imp.Clients.TRLWorker.Registry, worker_key) do
      :ok
    else
      false -> {:error, :trl_deployment_model_identity_mismatch}
      [] -> {:error, :trl_deployment_worker_not_running}
      %{} -> {:error, :trl_deployment_requires_artifact_bound_lm}
      {:error, _reason} = error -> error
      _other -> {:error, :trl_deployment_requires_artifact_bound_lm}
    end
  end

  defp validate_provider_deployment_lm(_job, _lm), do: :ok

  defp mlx_lm_model_path(%Imp.Clients.ReqLLM{model: model}) when is_binary(model),
    do: {:ok, model}

  defp mlx_lm_model_path(%Imp.Clients.ReqLLM{model: model}) when is_map(model) do
    case Map.get(model, :id) || Map.get(model, "id") || Map.get(model, :model) ||
           Map.get(model, "model") do
      path when is_binary(path) -> {:ok, path}
      _missing -> {:error, :mlx_lm_deployment_model_identity_missing}
    end
  end

  defp mlx_lm_model_path(_lm), do: {:error, :mlx_lm_deployment_requires_req_llm}

  defp trl_model_path(%Imp.Clients.ReqLLM{model: model}) when is_binary(model), do: {:ok, model}
  defp trl_model_path(%{model: model}) when is_binary(model), do: {:ok, model}
  defp trl_model_path(_lm), do: {:error, :trl_deployment_model_identity_missing}

  defp validate_mlx_source_lm(
         %__MODULE__{} = job,
         %Imp.Clients.ReqLLM{model: model},
         manifest
       ) do
    spec = manifest["spec"] || %{}

    allowed =
      [
        job.model,
        job.result_model,
        spec["model"],
        model_with_revision(spec["model"], spec["model_revision"]),
        spec["model_path"]
      ]
      |> Enum.filter(&is_binary/1)

    with :ok <- validate_mlx_provider(model),
         {:ok, identity} <- mlx_lm_model_path(%Imp.Clients.ReqLLM{model: model}),
         true <- Enum.any?(allowed, &same_model_identity?(identity, &1)) do
      :ok
    else
      false -> {:error, {:mlx_lm_rebind_source_model_mismatch, allowed, model}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_mlx_source_lm(_job, lm, _manifest) do
    case Imp.LM.validate_lm(lm) do
      {:ok, _lm} -> :ok
      {:error, _message} -> {:error, :mlx_lm_rebind_source_lm_invalid}
    end
  end

  defp validate_mlx_provider(%{provider: provider}) when provider in [:openai, "openai"], do: :ok

  defp validate_mlx_provider(%{"provider" => provider}) when provider in [:openai, "openai"],
    do: :ok

  defp validate_mlx_provider("openai:" <> _model), do: :ok

  defp validate_mlx_provider(model) when is_binary(model) do
    if Path.type(model) == :absolute,
      do: :ok,
      else: {:error, {:mlx_lm_rebind_provider_conflict, model}}
  end

  defp validate_mlx_provider(model), do: {:error, {:mlx_lm_rebind_provider_conflict, model}}

  defp mlx_runtime_options(%Imp.Clients.ReqLLM{opts: opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      unsupported = keys -- (@mlx_rebind_option_keys ++ [:api_key])

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :mlx_lm_rebind_duplicate_options}

        unsupported != [] ->
          {:error, {:mlx_lm_rebind_unsupported_options, unsupported}}

        Keyword.has_key?(opts, :api_key) and opts[:api_key] != "local" ->
          {:error, :mlx_lm_rebind_credential_conflict}

        true ->
          with :ok <- validate_mlx_runtime_values(opts) do
            {:ok, Keyword.take(opts, @mlx_rebind_option_keys)}
          end
      end
    else
      {:error, :mlx_lm_rebind_options_must_be_keyword_list}
    end
  end

  defp mlx_runtime_options(_lm), do: {:ok, []}

  defp validate_mlx_runtime_values(opts) do
    with :ok <- optional_boolean(opts, :cache),
         :ok <- optional_positive_integer(opts, :seed),
         :ok <- optional_non_negative_integer(opts, :max_retries),
         :ok <- optional_non_negative_integer(opts, :retries),
         :ok <- optional_non_negative_integer(opts, :num_retries),
         :ok <- optional_non_negative_integer(opts, :retry_backoff_ms),
         :ok <- validate_req_http_options(Keyword.get(opts, :req_http_options)) do
      :ok
    end
  end

  defp optional_boolean(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, value} -> {:error, {:mlx_lm_rebind_invalid_option, key, value}}
    end
  end

  defp optional_non_negative_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, value} -> {:error, {:mlx_lm_rebind_invalid_option, key, value}}
    end
  end

  defp optional_positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, value} -> {:error, {:mlx_lm_rebind_invalid_option, key, value}}
    end
  end

  defp validate_req_http_options(nil), do: :ok

  defp validate_req_http_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :mlx_lm_rebind_duplicate_req_http_options}

        keys -- [:retry, :max_retries] != [] ->
          {:error, {:mlx_lm_rebind_unsupported_req_http_options, keys -- [:retry, :max_retries]}}

        Keyword.has_key?(opts, :retry) and not is_boolean(opts[:retry]) ->
          {:error, {:mlx_lm_rebind_invalid_req_http_option, :retry, opts[:retry]}}

        Keyword.has_key?(opts, :max_retries) and
            (not is_integer(opts[:max_retries]) or opts[:max_retries] < 0) ->
          {:error, {:mlx_lm_rebind_invalid_req_http_option, :max_retries, opts[:max_retries]}}

        true ->
          :ok
      end
    else
      {:error, :mlx_lm_rebind_req_http_options_must_be_keyword_list}
    end
  end

  defp validate_req_http_options(value),
    do: {:error, {:mlx_lm_rebind_invalid_req_http_options, value}}

  defp model_with_revision(model, revision) when is_binary(model) and is_binary(revision),
    do: model <> "@" <> revision

  defp model_with_revision(_model, _revision), do: nil

  defp same_model_identity?(left, right) when left == right, do: true

  defp same_model_identity?(left, right) when is_binary(left) and is_binary(right) do
    Path.type(left) == :absolute and Path.type(right) == :absolute and
      Path.expand(left) == Path.expand(right)
  end

  defp same_model_identity?(_left, _right), do: false

  defp training_artifact_metadata(job) do
    metadata = %{
      provider: job.provider,
      job_id: job.id,
      base_model: job.model,
      result_model: job.result_model
    }

    case job.metadata[:artifact_sha256] || job.metadata["artifact_sha256"] do
      digest when is_binary(digest) -> Map.put(metadata, :artifact_sha256, digest)
      _missing -> metadata
    end
  end

  defp validate_rebind_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:path, :lm, :trainer])) and
         (is_nil(opts[:path]) or is_binary(opts[:path])) do
      :ok
    else
      {:error, :invalid_training_rebind_options}
    end
  end

  defp validate_rebind_opts(_opts), do: {:error, :invalid_training_rebind_options}

  # A live TRL LM is intentionally not serialized: its trusted executable and
  # worker binding must be reconstructed in the destination process. Persist
  # the portable source program and TrainingJob separately, then rebind there.
  defp validate_provider_rebind_opts(%__MODULE__{provider: :trl}, opts) do
    cond do
      Keyword.has_key?(opts, :path) ->
        {:error, :trl_deployment_program_not_portable}

      Keyword.has_key?(opts, :lm) and Keyword.has_key?(opts, :trainer) ->
        {:error, :trl_deployment_runtime_conflict}

      true ->
        :ok
    end
  end

  defp validate_provider_rebind_opts(%__MODULE__{}, _opts), do: :ok

  defp validate_request_policy!(%__MODULE__{} = job) do
    unless is_integer(job.max_attempts) and job.max_attempts > 0 do
      raise ArgumentError, "training job max_attempts must be a positive integer"
    end

    unless is_integer(job.retry_backoff_ms) and job.retry_backoff_ms >= 0 do
      raise ArgumentError, "training job retry_backoff_ms must be a non-negative integer"
    end

    job
  end

  defp validate_load_opts!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) and
             Enum.all?(Keyword.keys(opts), &(&1 in [:transport, :api_key])) do
      raise ArgumentError, "training job load options must contain only :transport and :api_key"
    end

    case Keyword.get(opts, :transport) do
      nil ->
        :ok

      transport ->
        case Imp.HTTP.validate_transport(transport) do
          {:ok, _transport} -> :ok
          {:error, message} -> raise ArgumentError, "invalid training job transport: #{message}"
        end
    end

    case Keyword.get(opts, :api_key) do
      nil -> opts
      api_key when is_binary(api_key) -> opts
      _api_key -> raise ArgumentError, "training job api_key must be a string or nil"
    end
  end

  defp validate_load_opts!(_opts),
    do: raise(ArgumentError, "training job load options must be a keyword list")

  defp dump_status({:unknown, status}), do: %{"unknown" => status}
  defp dump_status(status) when is_atom(status), do: Atom.to_string(status)

  defp load_status(%{"unknown" => status}) when is_binary(status), do: {:unknown, status}
  defp load_status(status), do: status

  defp load_provider("openai"), do: :openai
  defp load_provider("databricks"), do: :databricks
  defp load_provider("mlx_lm"), do: :mlx_lm
  defp load_provider("trl"), do: :trl
  defp load_provider("local"), do: :local
  defp load_provider(provider), do: provider

  defp operation_idempotency_key(%__MODULE__{idempotency_key: nil}, _operation), do: nil

  defp operation_idempotency_key(%__MODULE__{idempotency_key: key}, operation),
    do: key <> ":" <> Atom.to_string(operation)

  defp operation_method(job, :refresh), do: job.status_method
  defp operation_method(job, :cancel), do: job.cancel_method

  defp operation_body(job, :refresh), do: encode_operation_body(job.status_body, job.id)
  defp operation_body(job, :cancel), do: encode_operation_body(job.cancel_body, job.id)

  defp encode_operation_body(:empty, _id), do: ""
  defp encode_operation_body(:job_id, id), do: Jason.encode!(%{job_id: id})

  defp normalize_method(method) when method in [:get, :post, :put, :patch, :delete], do: method

  defp normalize_method(method) when is_binary(method) do
    case String.downcase(method) do
      "get" -> :get
      "post" -> :post
      "put" -> :put
      "patch" -> :patch
      "delete" -> :delete
      other -> raise ArgumentError, "unsupported training HTTP method #{inspect(other)}"
    end
  end

  defp normalize_method(method),
    do: raise(ArgumentError, "unsupported training HTTP method #{inspect(method)}")

  defp normalize_body_mode(mode) when mode in [:job_id, :empty], do: mode
  defp normalize_body_mode("job_id"), do: :job_id
  defp normalize_body_mode("empty"), do: :empty

  defp normalize_body_mode(mode),
    do: raise(ArgumentError, "unsupported training request body mode #{inspect(mode)}")

  defp json_normalize!(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp payload_checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp operation_failure(:refresh), do: :training_refresh_failed
  defp operation_failure(:cancel), do: :training_cancel_failed
  defp invalid_operation_response(:refresh), do: :invalid_training_refresh_response
  defp invalid_operation_response(:cancel), do: :invalid_training_cancel_response

  defp auth_headers(nil), do: []
  defp auth_headers(key), do: [{"authorization", "Bearer #{key}"}]
end

defmodule Imp.Clients.ReinforcementSession do
  @moduledoc "Provider-neutral, explicit state for an iterative reinforcement training job."

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom() | String.t(),
          model: term(),
          status: atom() | {:unknown, String.t()},
          pending_batch_ids: [term()],
          fulfilled_batch_ids: [term()],
          current_model: String.t() | nil,
          result_model: String.t() | nil,
          backend_state: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :provider,
    :model,
    :current_model,
    :result_model,
    :backend_state,
    status: :created,
    pending_batch_ids: [],
    fulfilled_batch_ids: [],
    metadata: %{}
  ]

  def new(attrs \\ [])

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      id: fetch(attrs, :id, "reinforce-#{System.unique_integer([:positive])}"),
      provider: fetch(attrs, :provider, :local),
      model: fetch(attrs, :model, nil),
      status: fetch(attrs, :status, :created) |> Imp.Clients.TrainingJob.normalize_status(),
      pending_batch_ids: fetch(attrs, :pending_batch_ids, []),
      fulfilled_batch_ids: fetch(attrs, :fulfilled_batch_ids, []),
      current_model: fetch(attrs, :current_model, nil),
      result_model: fetch(attrs, :result_model, nil),
      backend_state: fetch(attrs, :backend_state, nil),
      metadata: fetch(attrs, :metadata, %{}) |> Imp.Redaction.redact()
    }
    |> validate!()
  end

  def new(attrs) do
    raise ArgumentError,
          "Imp.Clients.ReinforcementSession.new/1 expects a map or keyword list; got: #{inspect(attrs)}"
  end

  def merge_status(%__MODULE__{}, %__MODULE__{} = updated), do: validate!(updated)

  def merge_status(%__MODULE__{} = session, status) when is_map(status) or is_list(status) do
    status = Map.new(status)

    %{
      session
      | status:
          fetch(status, :status, session.status)
          |> Imp.Clients.TrainingJob.normalize_status(),
        pending_batch_ids: fetch(status, :pending_batch_ids, session.pending_batch_ids),
        current_model: fetch(status, :current_model, session.current_model),
        result_model: fetch(status, :result_model, session.result_model),
        backend_state: fetch(status, :backend_state, session.backend_state),
        metadata:
          Map.merge(session.metadata, fetch(status, :metadata, %{}) |> Imp.Redaction.redact())
    }
    |> validate!()
  end

  def merge_status(_session, status),
    do: raise(ArgumentError, "invalid reinforcement status: #{inspect(status)}")

  def fulfill(%__MODULE__{} = session, batch_ids) when is_list(batch_ids) do
    %{
      session
      | fulfilled_batch_ids: Enum.uniq(session.fulfilled_batch_ids ++ batch_ids),
        pending_batch_ids: Enum.reject(session.pending_batch_ids, &(&1 in batch_ids))
    }
  end

  defp validate!(%__MODULE__{} = session) do
    unless is_binary(session.id) and session.id != "",
      do: raise(ArgumentError, "reinforcement session id must be a non-empty string")

    unless is_list(session.pending_batch_ids),
      do: raise(ArgumentError, "reinforcement pending_batch_ids must be a list")

    unless is_list(session.fulfilled_batch_ids),
      do: raise(ArgumentError, "reinforcement fulfilled_batch_ids must be a list")

    unless is_map(session.metadata),
      do: raise(ArgumentError, "reinforcement session metadata must be a map")

    session
  end

  defp fetch(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end

defmodule Imp.Clients.Trainer do
  @moduledoc """
  Behaviour for provider-specific training backends.

  A mutating `reinforcement_step` error has an unknown remote outcome by default.
  A backend may return `{:error, {:reinforcement_step_not_accepted, reason}}` only
  when it can guarantee that the provider did not accept or apply the step.
  """

  @callback supported_methods() :: [atom()]
  @callback supported_methods(term()) :: [atom()]

  @callback finetune(
              term(),
              list(Imp.Example.t()),
              keyword()
            ) ::
              {:ok, Imp.Clients.TrainingJob.t()} | {:error, term()}

  @callback reconcile_finetune(String.t()) ::
              {:ok, Imp.Clients.TrainingJob.t()} | {:error, term()}
  @callback reconcile_finetune(term(), String.t()) ::
              {:ok, Imp.Clients.TrainingJob.t()} | {:error, term()}
  @callback finetune(
              term(),
              term(),
              list(Imp.Example.t()),
              keyword()
            ) ::
              {:ok, Imp.Clients.TrainingJob.t()} | {:error, term()}

  @callback start_reinforcement(term(), keyword()) ::
              {:ok, Imp.Clients.ReinforcementSession.t()} | {:error, term()}
  @callback start_reinforcement(term(), term(), keyword()) ::
              {:ok, Imp.Clients.ReinforcementSession.t()} | {:error, term()}
  @callback reconcile_reinforcement(String.t()) ::
              {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback reconcile_reinforcement(term(), String.t()) ::
              {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback reinforcement_status(Imp.Clients.ReinforcementSession.t()) ::
              {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback reinforcement_status(term(), Imp.Clients.ReinforcementSession.t()) ::
              {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback reinforcement_step(Imp.Clients.ReinforcementSession.t(), list(), keyword()) ::
              {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback reinforcement_step(
              term(),
              Imp.Clients.ReinforcementSession.t(),
              list(),
              keyword()
            ) :: {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback terminate_reinforcement(Imp.Clients.ReinforcementSession.t()) ::
              {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback terminate_reinforcement(term(), Imp.Clients.ReinforcementSession.t()) ::
              {:ok, Imp.Clients.ReinforcementSession.t() | map()} | {:error, term()}
  @callback final_model_artifact(Imp.Clients.ReinforcementSession.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback final_model_artifact(term(), Imp.Clients.ReinforcementSession.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback reinforcement_artifact(Imp.Clients.ReinforcementSession.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback reinforcement_artifact(term(), Imp.Clients.ReinforcementSession.t(), map()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks finetune: 3,
                      finetune: 4,
                      reconcile_finetune: 1,
                      reconcile_finetune: 2,
                      supported_methods: 0,
                      supported_methods: 1,
                      start_reinforcement: 2,
                      start_reinforcement: 3,
                      reconcile_reinforcement: 1,
                      reconcile_reinforcement: 2,
                      reinforcement_status: 1,
                      reinforcement_status: 2,
                      reinforcement_step: 3,
                      reinforcement_step: 4,
                      terminate_reinforcement: 1,
                      terminate_reinforcement: 2,
                      final_model_artifact: 1,
                      final_model_artifact: 2,
                      reinforcement_artifact: 2,
                      reinforcement_artifact: 3

  def finetune(provider, lm, examples, opts \\ [])

  def finetune(provider, lm, examples, opts) do
    opts = validate_opts!(opts)
    examples = validate_examples!(examples)

    case Keyword.pop(opts, :dispatch_journal_path) do
      {nil, provider_opts} ->
        finetune_direct(provider, lm, examples, provider_opts)

      {path, provider_opts} when is_binary(path) and path != "" ->
        Imp.Clients.TrainingDispatch.run(provider, lm, examples, provider_opts, path)

      {path, _provider_opts} ->
        {:error, {:invalid_training_dispatch_journal_path, path}}
    end
  end

  @doc false
  def finetune_direct(provider, lm, examples, opts) do
    with :ok <- supports_method(provider, Keyword.get(opts, :method, :sft)) do
      do_finetune(provider, lm, examples, opts)
    end
  end

  @doc "Reconciles a durable finetuning dispatch identifier to its provider job."
  def reconcile_finetune(provider, dispatch_id) when is_binary(dispatch_id) do
    case dispatch_training(provider, :reconcile_finetune, [dispatch_id]) do
      {:ok, %Imp.Clients.TrainingJob{} = job} ->
        {:ok, Imp.Clients.TrainingJob.validate_terminal(job)}

      {:ok, other} ->
        {:error, {:invalid_training_reconciliation_result, other}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Checks whether a trainer explicitly supports a training method."
  def supports_method(provider, method) when is_atom(method) do
    if method in supported_methods(provider) do
      :ok
    else
      {:error, {:unsupported_training_method, method}}
    end
  end

  def supports_method(_provider, method), do: {:error, {:unsupported_training_method, method}}

  def start_reinforcement(provider, lm, opts \\ []) do
    opts = validate_opts!(opts)

    with :ok <- supports_method(provider, :grpo),
         {:ok, session} <- dispatch(provider, :start_reinforcement, [lm, opts]),
         {:ok, session} <- normalize_session(session) do
      {:ok, session}
    end
  end

  def reinforcement_status(provider, %Imp.Clients.ReinforcementSession{} = session) do
    with {:ok, status} <- dispatch(provider, :reinforcement_status, [session]) do
      normalize_session_update(session, status)
    end
  end

  @doc "Reconciles a durable reinforcement dispatch identifier to its provider session."
  def reconcile_reinforcement(provider, dispatch_id) when is_binary(dispatch_id) do
    with {:ok, session} <- dispatch(provider, :reconcile_reinforcement, [dispatch_id]),
         {:ok, session} <- normalize_session(session) do
      {:ok, session}
    end
  end

  def reinforcement_step(
        provider,
        %Imp.Clients.ReinforcementSession{} = session,
        groups,
        opts \\ []
      ) do
    opts = validate_opts!(opts)

    with :ok <- validate_groups(groups),
         {:ok, update} <- dispatch(provider, :reinforcement_step, [session, groups, opts]),
         {:ok, updated} <- normalize_session_update(session, update) do
      ids = Enum.map(groups, &Map.get(&1, :batch_id, Map.get(&1, "batch_id")))
      {:ok, Imp.Clients.ReinforcementSession.fulfill(updated, ids)}
    end
  end

  def terminate_reinforcement(provider, %Imp.Clients.ReinforcementSession{} = session) do
    with {:ok, update} <- dispatch(provider, :terminate_reinforcement, [session]) do
      normalize_session_update(session, update)
    end
  end

  def final_model_artifact(provider, %Imp.Clients.ReinforcementSession{} = session) do
    with {:ok, artifact} <- dispatch(provider, :final_model_artifact, [session]),
         true <- is_binary(artifact) and String.trim(artifact) != "" do
      {:ok, artifact}
    else
      false -> {:error, :reinforcement_artifact_missing}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_reinforcement_artifact, other}}
    end
  end

  @doc "Resolves and verifies a retained reinforcement checkpoint for deployment."
  def reinforcement_artifact(provider, %Imp.Clients.ReinforcementSession{} = session, selection)
      when is_map(selection) do
    with {:ok, artifact} <- dispatch(provider, :reinforcement_artifact, [session, selection]),
         %{path: path, artifact_sha256: sha256} <- artifact,
         true <- is_binary(path) and path != "" and is_binary(sha256) do
      {:ok, artifact}
    else
      false -> {:error, :reinforcement_artifact_invalid}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_reinforcement_artifact, other}}
    end
  end

  @doc false
  def supports_reinforcement_artifact?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :reinforcement_artifact, 3)
  end

  def supports_reinforcement_artifact?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :reinforcement_artifact, 2)
  end

  def supports_reinforcement_artifact?(_provider), do: false

  def validate_provider(nil), do: {:ok, nil}
  def validate_provider(provider) when is_atom(provider), do: {:ok, provider}
  def validate_provider(provider) when is_function(provider, 3), do: {:ok, provider}
  def validate_provider(%_{} = provider), do: {:ok, provider}

  def validate_provider(_provider) do
    {:error, "expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback"}
  end

  defp supported_methods(%module{} = trainer) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :supported_methods, 1) ->
        module.supported_methods(trainer)

      true ->
        [:sft]
    end
  end

  defp supported_methods(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :supported_methods, 0) do
      module.supported_methods()
    else
      [:sft]
    end
  end

  defp supported_methods(fun) when is_function(fun, 3), do: [:sft]
  defp supported_methods(_provider), do: []

  defp do_finetune(module, lm, examples, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :finetune, 3) do
      call_trainer(fn -> module.finetune(lm, examples, opts) end, module)
    else
      {:error, {:not_a_trainer, module}}
    end
  end

  defp do_finetune(%module{} = trainer, lm, examples, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :finetune, 4) do
      call_trainer(fn -> module.finetune(trainer, lm, examples, opts) end, module)
    else
      {:error, {:not_a_trainer, module}}
    end
  end

  defp do_finetune(fun, lm, examples, opts) when is_function(fun, 3) do
    call_trainer(fn -> fun.(lm, examples, opts) end, fun)
  end

  defp do_finetune(provider, _lm, _examples, _opts), do: {:error, {:not_a_trainer, provider}}

  defp dispatch_training(module, callback, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, callback, length(args)) do
      call_trainer(fn -> apply(module, callback, args) end, module)
    else
      {:error, {:training_callback_not_supported, callback}}
    end
  end

  defp dispatch_training(%module{} = trainer, callback, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, callback, length(args) + 1) do
      call_trainer(fn -> apply(module, callback, [trainer | args]) end, module)
    else
      {:error, {:training_callback_not_supported, callback}}
    end
  end

  defp dispatch_training(_provider, callback, _args),
    do: {:error, {:training_callback_not_supported, callback}}

  defp dispatch(module, callback, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, callback, length(args)) do
      call_reinforcement(fn -> apply(module, callback, args) end, module, callback)
    else
      {:error, {:reinforcement_callback_not_supported, callback}}
    end
  end

  defp dispatch(%module{} = trainer, callback, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, callback, length(args) + 1) do
      call_reinforcement(fn -> apply(module, callback, [trainer | args]) end, module, callback)
    else
      {:error, {:reinforcement_callback_not_supported, callback}}
    end
  end

  defp dispatch(_provider, callback, _args),
    do: {:error, {:reinforcement_callback_not_supported, callback}}

  defp call_reinforcement(fun, trainer, callback) do
    case fun.() do
      {:ok, _value} = result -> result
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_reinforcement_result, callback, other}}
    end
  rescue
    error -> {:error, {:trainer_failed, trainer_name(trainer), error_message(error)}}
  catch
    kind, reason ->
      {:error, {:trainer_failed, trainer_name(trainer), error_message({kind, reason})}}
  end

  defp normalize_session(%Imp.Clients.ReinforcementSession{} = session), do: {:ok, session}

  defp normalize_session(attrs) when is_map(attrs) or is_list(attrs),
    do: {:ok, Imp.Clients.ReinforcementSession.new(attrs)}

  defp normalize_session(other), do: {:error, {:invalid_reinforcement_session, other}}

  defp normalize_session_update(session, update) do
    {:ok, Imp.Clients.ReinforcementSession.merge_status(session, update)}
  rescue
    error -> {:error, {:invalid_reinforcement_status, Exception.message(error)}}
  end

  defp validate_groups(groups) when is_list(groups) and groups != [] do
    if Enum.all?(groups, &valid_group?/1),
      do: :ok,
      else: {:error, :invalid_reinforcement_groups}
  end

  defp validate_groups(_groups), do: {:error, :invalid_reinforcement_groups}

  defp valid_group?(group) when is_map(group) do
    batch_id = Map.get(group, :batch_id, Map.get(group, "batch_id"))
    completions = Map.get(group, :group, Map.get(group, "group"))

    not is_nil(batch_id) and is_list(completions) and completions != [] and
      Enum.all?(completions, &valid_completion?/1)
  end

  defp valid_group?(_group), do: false

  defp valid_completion?(completion) when is_map(completion) do
    messages = Map.get(completion, :messages, Map.get(completion, "messages"))
    response = Map.get(completion, :completion, Map.get(completion, "completion"))
    reward = Map.get(completion, :reward, Map.get(completion, "reward"))

    (is_list(messages) and is_map(response) and finite_number?(reward)) or
      valid_token_trajectory?(completion, reward)
  end

  defp valid_completion?(_completion), do: false

  defp valid_token_trajectory?(trajectory, reward) do
    token_ids = field(trajectory, :response_token_ids)
    mask = field(trajectory, :response_mask)
    logprobs = field(trajectory, :behavior_logprobs)
    advantage = field(trajectory, :advantage)
    policy_id = field(trajectory, :behavior_policy_id)

    finite_number?(reward) and finite_number?(advantage) and is_binary(policy_id) and
      policy_id != "" and is_list(token_ids) and token_ids != [] and
      Enum.all?(token_ids, &(is_integer(&1) and &1 >= 0)) and is_list(mask) and
      length(mask) == length(token_ids) and Enum.all?(mask, &(&1 in [0, 1])) and
      is_list(logprobs) and length(logprobs) == length(token_ids) and
      Enum.all?(logprobs, &finite_number?/1)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(value) when is_float(value), do: abs(value) < 1.0e308
  defp finite_number?(_value), do: false

  defp validate_opts!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)}.finetune/4 expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.finetune/4 expects keyword options, got: #{inspect(opts)}"
  end

  defp validate_examples!(examples) when is_list(examples) do
    case Enum.find(examples, &(not match?(%Imp.Example{}, &1))) do
      nil ->
        examples

      invalid ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.finetune/4 expects examples as Imp.Example structs, got entry: #{inspect(invalid)}"
    end
  end

  defp validate_examples!(examples) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.finetune/4 expects a list of examples, got: #{inspect(examples)}"
  end

  defp call_trainer(fun, trainer) do
    case fun.() do
      {:ok, %Imp.Clients.TrainingJob{} = job} ->
        {:ok, Imp.Clients.TrainingJob.validate_terminal(job)}

      {:error, _reason} = error ->
        error

      {:ok, other} ->
        {:error, {:invalid_trainer_result, other}}

      other ->
        {:error, {:invalid_trainer_result, other}}
    end
  rescue
    error -> {:error, {:trainer_failed, trainer_name(trainer), error_message(error)}}
  catch
    kind, reason ->
      {:error, {:trainer_failed, trainer_name(trainer), error_message({kind, reason})}}
  end

  defp trainer_name(trainer) when is_atom(trainer), do: trainer
  defp trainer_name(fun) when is_function(fun), do: :anonymous_trainer
  defp trainer_name(%module{}), do: module
  defp trainer_name(other), do: other

  defp error_message(%_{} = exception),
    do: exception |> Exception.message() |> Imp.Redaction.redact()

  defp error_message(error), do: error |> inspect() |> Imp.Redaction.redact()
end

defmodule Imp.Clients.HTTPTrainer do
  @moduledoc "Provider trainer that submits finetuning data to HTTP APIs."

  @behaviour Imp.Clients.Trainer

  defstruct [
    :provider,
    :submit_url,
    :status_url,
    :cancel_url,
    :api_key,
    transport: Imp.HTTP.Hackneyless,
    status_method: :post,
    cancel_method: :post,
    status_body: :job_id,
    cancel_body: :job_id,
    supported_methods: [:sft],
    headers: [],
    submission_preparer: nil,
    payload_builder: nil,
    response_mapper: nil,
    max_attempts: 3,
    retry_backoff_ms: 100
  ]

  @option_schema [
    status_url: [type: {:or, [:string, nil]}],
    cancel_url: [type: {:or, [:string, nil]}],
    status_method: [type: {:in, [:get, :post, :put, :patch, :delete]}, default: :post],
    cancel_method: [type: {:in, [:get, :post, :put, :patch, :delete]}, default: :post],
    status_body: [type: {:in, [:job_id, :empty]}, default: :job_id],
    cancel_body: [type: {:in, [:job_id, :empty]}, default: :job_id],
    api_key: [type: {:or, [:string, nil]}],
    transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
    supported_methods: [type: {:list, :atom}],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    submission_preparer: [type: {:fun, 4}],
    payload_builder: [type: {:fun, 3}],
    response_mapper: [type: {:fun, 4}],
    max_attempts: [type: :pos_integer, default: 3],
    retry_backoff_ms: [type: :non_neg_integer, default: 100]
  ]

  def new(provider, submit_url, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/3")

    %__MODULE__{
      provider: provider,
      submit_url: submit_url,
      status_url: Keyword.get(opts, :status_url),
      cancel_url: Keyword.get(opts, :cancel_url),
      api_key: Keyword.get(opts, :api_key),
      transport: Keyword.get(opts, :transport, Imp.HTTP.Hackneyless),
      status_method: opts[:status_method],
      cancel_method: opts[:cancel_method],
      status_body: opts[:status_body],
      cancel_body: opts[:cancel_body],
      supported_methods: Keyword.get(opts, :supported_methods, [:sft]),
      headers: Keyword.get(opts, :headers, []),
      submission_preparer: Keyword.get(opts, :submission_preparer),
      payload_builder: Keyword.get(opts, :payload_builder, &default_payload/3),
      response_mapper: Keyword.get(opts, :response_mapper, &default_response/4),
      max_attempts: opts[:max_attempts],
      retry_backoff_ms: opts[:retry_backoff_ms]
    }
  end

  @impl true
  def supported_methods(%__MODULE__{supported_methods: methods}), do: methods

  @impl true
  def finetune(%__MODULE__{} = trainer, lm, examples, opts) do
    opts = validate_call_opts!(opts)
    examples = validate_examples!(examples)

    with :ok <-
           Imp.Clients.Trainer.supports_method(trainer, Keyword.get(opts, :method, :sft)) do
      Imp.Telemetry.span(
        [:imp, :training, :submit],
        %{provider: trainer.provider, model: Map.get(lm, :model)},
        fn ->
          submit(trainer, lm, examples, opts)
        end
      )
    end
  end

  def finetune(trainer, lm, examples, opts) when is_map(trainer) do
    finetune(struct(__MODULE__, trainer), lm, examples, opts)
  end

  defp validate_call_opts!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)}.finetune/4 expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_call_opts!(opts) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.finetune/4 expects keyword options, got: #{inspect(opts)}"
  end

  defp validate_examples!(examples) when is_list(examples) do
    case Enum.find(examples, &(not match?(%Imp.Example{}, &1))) do
      nil ->
        examples

      invalid ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.finetune/4 expects examples as Imp.Example structs, got entry: #{inspect(invalid)}"
    end
  end

  defp validate_examples!(examples) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.finetune/4 expects a list of examples, got: #{inspect(examples)}"
  end

  defp default_payload(lm, examples, opts) do
    %{
      model: Map.get(lm, :model),
      method: Keyword.get(opts, :method, :sft),
      training_data: Enum.map(examples, &Imp.Example.to_map/1)
    }
  end

  defp build_payload(%__MODULE__{} = trainer, lm, examples, opts) do
    case trainer.payload_builder.(lm, examples, opts) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason}
      payload when is_map(payload) -> {:ok, payload}
      other -> {:error, {:invalid_training_payload, other}}
    end
  rescue
    error -> {:error, {:invalid_training_payload, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:invalid_training_payload, inspect({kind, reason})}}
  end

  defp submit(%__MODULE__{} = trainer, lm, examples, opts) do
    with {:ok, opts} <- prepare_submission(trainer, lm, examples, opts),
         {:ok, payload} <- build_payload(trainer, lm, examples, opts),
         {:ok, body} <- encode_payload(payload),
         {:ok, request_policy} <- request_policy(trainer, lm, body, opts),
         headers <-
           ([{"content-type", "application/json"}] ++
              auth_headers(trainer.api_key) ++ trainer.headers)
           |> Imp.Clients.TrainingHTTP.put_header(
             "idempotency-key",
             request_policy.idempotency_key
           ),
         {:ok, response} <- post_training(trainer, body, headers, opts, request_policy),
         {:ok, decoded} <- decode_training_response(response),
         {:ok, job} <-
           map_training_response(
             trainer,
             lm,
             examples,
             decoded,
             request_policy
           ) do
      {:ok, job}
    end
  end

  defp prepare_submission(%__MODULE__{submission_preparer: nil}, _lm, _examples, opts),
    do: {:ok, opts}

  defp prepare_submission(%__MODULE__{} = trainer, lm, examples, opts) do
    case trainer.submission_preparer.(trainer, lm, examples, opts) do
      {:ok, prepared_opts} when is_list(prepared_opts) -> {:ok, prepared_opts}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_training_preparation, other}}
    end
  rescue
    error -> {:error, {:invalid_training_preparation, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:invalid_training_preparation, inspect({kind, reason})}}
  end

  defp encode_payload(payload) do
    {:ok, Jason.encode!(payload)}
  rescue
    error -> {:error, {:invalid_training_payload, Exception.message(error)}}
  end

  defp post_training(trainer, body, headers, opts, request_policy) do
    case Imp.Clients.TrainingHTTP.request(
           trainer.transport,
           trainer.submit_url,
           headers,
           body,
           request_opts(opts),
           request_policy.max_attempts,
           request_policy.retry_backoff_ms
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, Imp.Clients.TrainingHTTP.redact_response(response)}}

      {:error, {:http_transport_failed, _transport, reason}} ->
        {:error, {:training_transport_failed, Imp.Redaction.redact(reason)}}

      {:error, reason} ->
        {:error, Imp.Redaction.redact(reason)}

      other ->
        {:error, {:invalid_training_transport_response, other}}
    end
  rescue
    error -> {:error, {:training_transport_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:training_transport_failed, inspect({kind, reason})}}
  end

  defp decode_training_response(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:invalid_training_response, decoded}}
      {:error, reason} -> {:error, {:invalid_training_response, Exception.message(reason)}}
    end
  end

  defp map_training_response(trainer, lm, examples, decoded, request_policy) do
    case trainer.response_mapper.(trainer, lm, examples, decoded) do
      %Imp.Clients.TrainingJob{} = job ->
        {:ok,
         %{
           job
           | idempotency_key: job.idempotency_key || request_policy.idempotency_key,
             max_attempts: request_policy.max_attempts,
             retry_backoff_ms: request_policy.retry_backoff_ms
         }}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_training_job, other}}
    end
  rescue
    error -> {:error, {:invalid_training_job, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:invalid_training_job, inspect({kind, reason})}}
  end

  defp default_response(trainer, lm, examples, decoded) do
    case provider_job_id(decoded) do
      {:ok, id} ->
        Imp.Clients.TrainingJob.new(%{
          id: id,
          provider: trainer.provider,
          model: Map.get(lm, :model),
          status:
            Imp.Clients.TrainingJob.normalize_status(
              decoded["status"] || decoded["state"] || :submitted
            ),
          training_data: examples |> Enum.map(&Imp.Example.to_map/1) |> Imp.Redaction.redact(),
          result_model: decoded["fine_tuned_model"] || decoded["result_model"],
          transport: trainer.transport,
          status_url: status_url(trainer, decoded),
          cancel_url: endpoint_url(trainer.cancel_url, decoded),
          status_method: trainer.status_method,
          cancel_method: trainer.cancel_method,
          status_body: trainer.status_body,
          cancel_body: trainer.cancel_body,
          api_key: trainer.api_key,
          max_attempts: trainer.max_attempts,
          retry_backoff_ms: trainer.retry_backoff_ms,
          metadata: %{"submit_response" => Imp.Redaction.redact(decoded)}
        })

      :error ->
        {:error, :training_job_id_missing}
    end
  end

  defp provider_job_id(decoded) do
    case decoded["id"] || decoded["job_id"] do
      id when is_binary(id) -> if String.trim(id) == "", do: :error, else: {:ok, id}
      id when is_integer(id) -> {:ok, Integer.to_string(id)}
      _id -> :error
    end
  end

  defp request_policy(trainer, lm, body, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, trainer.max_attempts)
    retry_backoff_ms = Keyword.get(opts, :retry_backoff_ms, trainer.retry_backoff_ms)

    cond do
      not (is_integer(max_attempts) and max_attempts > 0) ->
        {:error, :invalid_training_max_attempts}

      not (is_integer(retry_backoff_ms) and retry_backoff_ms >= 0) ->
        {:error, :invalid_training_retry_backoff_ms}

      true ->
        with {:ok, idempotency_key} <-
               Imp.Clients.TrainingHTTP.idempotency_key(
                 trainer.provider,
                 Map.get(lm, :model),
                 body,
                 Keyword.get(opts, :idempotency_key)
               ) do
          {:ok,
           %{
             idempotency_key: idempotency_key,
             max_attempts: max_attempts,
             retry_backoff_ms: retry_backoff_ms
           }}
        end
    end
  end

  defp request_opts(opts) do
    Keyword.drop(opts, [:example_encoder, :idempotency_key, :max_attempts, :retry_backoff_ms])
  end

  defp status_url(%__MODULE__{status_url: nil}, _decoded), do: nil

  defp status_url(%__MODULE__{status_url: template}, decoded) do
    endpoint_url(template, decoded)
  end

  defp endpoint_url(nil, _decoded), do: nil

  defp endpoint_url(template, decoded) do
    String.replace(template, "{id}", to_string(decoded["id"] || decoded["job_id"]))
  end

  defp auth_headers(nil), do: []
  defp auth_headers(key), do: [{"authorization", "Bearer #{key}"}]
end

defimpl Inspect, for: Imp.Clients.HTTPTrainer do
  import Inspect.Algebra

  def inspect(trainer, opts) do
    trainer
    |> Map.from_struct()
    |> Imp.Redaction.redact()
    |> then(&concat(["#Imp.Clients.HTTPTrainer<", to_doc(&1, opts), ">"]))
  end
end

defimpl Inspect, for: Imp.Clients.TrainingJob do
  import Inspect.Algebra

  def inspect(job, opts) do
    job
    |> Map.from_struct()
    |> Imp.Redaction.redact()
    |> then(&concat(["#Imp.Clients.TrainingJob<", to_doc(&1, opts), ">"]))
  end
end

defmodule Imp.Clients.OpenAITrainer do
  @moduledoc """
  OpenAI fine-tuning job client.

  Existing `:training_file` IDs are submitted directly. Otherwise examples are
  encoded as deterministic JSONL, uploaded to the OpenAI Files API, and the
  returned file ID is used for the fine-tuning job.
  """

  @option_schema [
    base_url: [type: :string],
    api_key: [type: {:or, [:string, nil]}],
    transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
    upload_transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
    example_encoder: [type: {:fun, 1}],
    training_file: [type: :string],
    validation_file: [type: :string],
    suffix: [type: :string],
    metadata: [type: :map],
    max_attempts: [type: :pos_integer, default: 3],
    retry_backoff_ms: [type: :non_neg_integer, default: 100]
  ]

  def new(opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/1")

    base =
      Keyword.get(opts, :base_url) || System.get_env("OPENAI_BASE_URL") ||
        "https://api.openai.com/v1"

    api_key = provider_api_key(opts, "OPENAI_API_KEY")
    transport = Keyword.get(opts, :transport, Imp.HTTP.Hackneyless)

    upload_transport = Keyword.get(opts, :upload_transport, transport)

    defaults =
      Keyword.take(opts, [
        :example_encoder,
        :training_file,
        :validation_file,
        :suffix,
        :metadata
      ])

    Imp.Clients.HTTPTrainer.new(
      :openai,
      String.trim_trailing(base, "/") <> "/fine_tuning/jobs",
      api_key: api_key,
      transport: transport,
      max_attempts: opts[:max_attempts],
      retry_backoff_ms: opts[:retry_backoff_ms],
      status_url: String.trim_trailing(base, "/") <> "/fine_tuning/jobs/{id}",
      cancel_url: String.trim_trailing(base, "/") <> "/fine_tuning/jobs/{id}/cancel",
      status_method: :get,
      cancel_method: :post,
      status_body: :empty,
      cancel_body: :empty,
      supported_methods: [:sft],
      submission_preparer: fn trainer, lm, examples, call_opts ->
        prepare_training_file(
          %{trainer | transport: upload_transport},
          lm,
          examples,
          Keyword.merge(defaults, call_opts),
          String.trim_trailing(base, "/") <> "/files"
        )
      end,
      payload_builder: fn lm, examples, call_opts ->
        payload(lm, examples, Keyword.merge(defaults, call_opts))
      end
    )
  end

  defp prepare_training_file(trainer, lm, examples, opts, files_url) do
    cond do
      is_binary(Keyword.get(opts, :training_file)) ->
        {:ok, opts}

      examples == [] ->
        {:error, :openai_training_file_required}

      true ->
        with {:ok, jsonl} <- encode_jsonl(examples, Keyword.get(opts, :example_encoder)),
             digest <- :crypto.hash(:sha256, jsonl) |> Base.encode16(case: :lower),
             boundary <- "imp-" <> binary_part(digest, 0, 32),
             filename <- "imp-training-" <> binary_part(digest, 0, 16) <> ".jsonl",
             body <- multipart_body(boundary, filename, jsonl),
             headers <-
               [{"content-type", "multipart/form-data; boundary=#{boundary}"}] ++
                 auth_headers(trainer.api_key),
             {:ok, response} <-
               upload_file(
                 trainer,
                 lm,
                 files_url,
                 headers,
                 body,
                 opts
               ),
             {:ok, training_file} <- decode_file_id(response) do
          {:ok, Keyword.put(opts, :training_file, training_file)}
        end
    end
  end

  @doc false
  def encode_jsonl(examples, encoder \\ nil) do
    examples
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {example, index}, {:ok, rows} ->
      with {:ok, row} <- encode_example(example, encoder),
           {:ok, row} <- normalize_provider_row(row),
           :ok <- validate_provider_row(row) do
        {:cont, {:ok, [canonical_json(row) | rows]}}
      else
        {:error, reason} ->
          {:halt, {:error, {:invalid_openai_training_example, index, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, rows |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_example(example, nil), do: {:ok, Imp.Example.to_map(example)}

  defp encode_example(example, encoder) do
    case encoder.(example) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:example_encoder_failed, reason}}
      row when is_map(row) -> {:ok, row}
      other -> {:error, {:invalid_example_encoder_result, other}}
    end
  rescue
    error -> {:error, {:example_encoder_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:example_encoder_failed, inspect({kind, reason})}}
  end

  defp normalize_provider_row(row) do
    {:ok, row |> Jason.encode!() |> Jason.decode!()}
  rescue
    error -> {:error, {:invalid_json, Exception.message(error)}}
  end

  defp validate_provider_row(%{"messages" => messages})
       when is_list(messages) and messages != [] do
    with :ok <- validate_messages(messages),
         true <- Enum.any?(messages, &(&1["role"] == "assistant")) do
      :ok
    else
      false -> {:error, :assistant_message_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_provider_row(%{"messages" => _messages}),
    do: {:error, :messages_must_be_a_non_empty_list}

  defp validate_provider_row(_row), do: {:error, :messages_required}

  defp validate_messages(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%{"role" => role, "content" => content}, _index}, :ok
      when role in ["system", "user", "assistant"] and is_binary(content) and content != "" ->
        {:cont, :ok}

      {%{"role" => role}, index}, :ok
      when role not in ["system", "user", "assistant"] ->
        {:halt, {:error, {:invalid_message_role, index, role}}}

      {%{"content" => content}, index}, :ok when not is_binary(content) or content == "" ->
        {:halt, {:error, {:invalid_message_content, index, content}}}

      {_message, index}, :ok ->
        {:halt, {:error, {:invalid_message, index}}}
    end)
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, nested} ->
      Jason.encode!(key) <> ":" <> canonical_json(nested)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp multipart_body(boundary, filename, jsonl) do
    [
      "--",
      boundary,
      "\r\n",
      "content-disposition: form-data; name=\"purpose\"\r\n\r\n",
      "fine-tune\r\n",
      "--",
      boundary,
      "\r\n",
      "content-disposition: form-data; name=\"file\"; filename=\"",
      filename,
      "\"\r\n",
      "content-type: application/jsonl\r\n\r\n",
      jsonl,
      "\r\n--",
      boundary,
      "--\r\n"
    ]
  end

  defp upload_file(trainer, lm, files_url, headers, body, opts) do
    body = IO.iodata_to_binary(body)

    with {:ok, idempotency_key} <-
           Imp.Clients.TrainingHTTP.idempotency_key(
             :openai_file,
             Map.get(lm, :model),
             body,
             nil
           ) do
      headers =
        Imp.Clients.TrainingHTTP.put_header(headers, "idempotency-key", idempotency_key)

      case Imp.Clients.TrainingHTTP.request(
             trainer.transport,
             files_url,
             headers,
             body,
             request_opts(opts),
             Keyword.get(opts, :max_attempts, trainer.max_attempts),
             Keyword.get(opts, :retry_backoff_ms, trainer.retry_backoff_ms)
           ) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          {:ok, response}

        {:ok, %{status: status, body: response}} ->
          {:error, {:http_error, status, Imp.Clients.TrainingHTTP.redact_response(response)}}

        {:error, {:http_transport_failed, _transport, reason}} ->
          {:error, {:training_transport_failed, Imp.Redaction.redact(reason)}}

        {:error, reason} ->
          {:error, Imp.Redaction.redact(reason)}

        other ->
          {:error, {:invalid_training_transport_response, other}}
      end
    end
  end

  defp decode_file_id(response) do
    case Jason.decode(response) do
      {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, decoded} -> {:error, {:invalid_openai_file_response, decoded}}
      {:error, reason} -> {:error, {:invalid_openai_file_response, Exception.message(reason)}}
    end
  end

  defp payload(lm, _examples, opts) do
    case Keyword.fetch(opts, :training_file) do
      {:ok, training_file} ->
        {:ok,
         %{
           model: openai_model_id(Map.get(lm, :model)),
           training_file: training_file,
           method: supervised_method(Keyword.get(opts, :hyperparameters))
         }
         |> maybe_put(:validation_file, Keyword.get(opts, :validation_file))
         |> maybe_put(:suffix, Keyword.get(opts, :suffix))
         |> maybe_put(:metadata, Keyword.get(opts, :metadata))}

      :error ->
        {:error, :openai_training_file_required}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp map_or_nil(nil), do: nil
  defp map_or_nil(values), do: Map.new(values)

  defp supervised_method(nil), do: %{type: "supervised"}

  defp supervised_method(hyperparameters) do
    %{
      type: "supervised",
      supervised: %{hyperparameters: map_or_nil(hyperparameters)}
    }
  end

  defp openai_model_id("openai:" <> model), do: model
  defp openai_model_id(model), do: model

  defp request_opts(opts),
    do:
      Keyword.drop(opts, [
        :example_encoder,
        :idempotency_key,
        :max_attempts,
        :retry_backoff_ms,
        :training_file
      ])

  defp auth_headers(nil), do: []
  defp auth_headers(key), do: [{"authorization", "Bearer #{key}"}]

  defp provider_api_key(opts, env_key) do
    cond do
      Keyword.has_key?(opts, :api_key) -> Keyword.get(opts, :api_key)
      Keyword.has_key?(opts, :base_url) -> nil
      true -> System.get_env(env_key)
    end
  end
end

defmodule Imp.Clients.DatabricksTrainer do
  @moduledoc "Databricks training job contract."

  @option_schema [
    base_url: [type: :string],
    api_key: [type: {:or, [:string, nil]}],
    transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
    max_attempts: [type: :pos_integer, default: 3],
    retry_backoff_ms: [type: :non_neg_integer, default: 100]
  ]

  def new(opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/1")

    base =
      Keyword.get(opts, :base_url) || System.get_env("DATABRICKS_BASE_URL") ||
        "https://example.cloud.databricks.com"

    api_key = provider_api_key(opts, "DATABRICKS_TOKEN")

    Imp.Clients.HTTPTrainer.new(
      :databricks,
      String.trim_trailing(base, "/") <> "/api/2.0/imp/finetune",
      api_key: api_key,
      transport: Keyword.get(opts, :transport, Imp.HTTP.Hackneyless),
      max_attempts: opts[:max_attempts],
      retry_backoff_ms: opts[:retry_backoff_ms],
      status_url: String.trim_trailing(base, "/") <> "/api/2.0/imp/finetune/{id}",
      cancel_url: String.trim_trailing(base, "/") <> "/api/2.0/imp/finetune/{id}/cancel",
      supported_methods: [:sft],
      payload_builder: &payload/3
    )
  end

  defp payload(lm, examples, opts) do
    %{
      base_model: Map.get(lm, :model),
      task_type: Keyword.get(opts, :method, :sft),
      train_data: Enum.map(examples, &Imp.Example.to_map/1),
      config:
        Map.new(
          Keyword.drop(opts, [
            :method,
            :idempotency_key,
            :max_attempts,
            :retry_backoff_ms
          ])
        )
    }
  end

  defp provider_api_key(opts, env_key) do
    cond do
      Keyword.has_key?(opts, :api_key) -> Keyword.get(opts, :api_key)
      Keyword.has_key?(opts, :base_url) -> nil
      true -> System.get_env(env_key)
    end
  end
end

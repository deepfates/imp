defmodule DSEx.Clients.TrainingHTTP do
  @moduledoc false

  @retryable_statuses [408, 409, 425, 429]

  def request(transport, url, headers, body, opts, max_attempts, retry_backoff_ms)
      when is_integer(max_attempts) and max_attempts > 0 and is_integer(retry_backoff_ms) and
             retry_backoff_ms >= 0 do
    do_request(transport, url, headers, body, opts, max_attempts, retry_backoff_ms, 1)
  end

  def idempotency_key(provider, model, body, nil) do
    [to_string(provider), to_string(model), IO.iodata_to_binary(body)]
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&{:ok, "dsex:" <> chunk_key(&1)})
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
      {:ok, decoded} -> decoded |> DSEx.Redaction.redact() |> Jason.encode!()
      {:error, _reason} -> DSEx.Redaction.redact(response)
    end
  end

  def redact_response(response), do: DSEx.Redaction.redact(response)

  defp do_request(transport, url, headers, body, opts, max_attempts, backoff, attempt) do
    response = DSEx.HTTP.post(transport, url, headers, body, opts)

    if attempt < max_attempts and retryable?(response) do
      Process.sleep(backoff * attempt)
      do_request(transport, url, headers, body, opts, max_attempts, backoff, attempt + 1)
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

defmodule DSEx.Clients.TrainingJob do
  @moduledoc "Provider-neutral finetuning or reinforcement-training job."

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
    max_attempts: 3,
    retry_backoff_ms: 100,
    metadata: %{}
  ]

  @doc """
  Builds a provider-neutral training job.

  Status values are normalized at the boundary: common provider strings such as
  `"succeeded"`, `"completed"`, `"queued"`, and `"running"` become DSEx atoms,
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
      api_key: fetch_attr(attrs, :api_key),
      idempotency_key: fetch_attr(attrs, :idempotency_key),
      max_attempts: fetch_attr(attrs, :max_attempts, 3),
      retry_backoff_ms: fetch_attr(attrs, :retry_backoff_ms, 100),
      metadata: fetch_attr(attrs, :metadata, %{}) |> DSEx.Redaction.redact()
    }

    job
    |> validate_request_policy!()
    |> enforce_artifact()
  end

  def new(attrs) do
    raise ArgumentError,
          "DSEx.Clients.TrainingJob.new/1 expects a map or keyword list; got: #{inspect(attrs)}"
  end

  def refresh(%__MODULE__{status_url: nil} = job), do: {:ok, job}

  def refresh(%__MODULE__{} = job) do
    DSEx.Telemetry.span(
      [:dsex, :training, :refresh],
      %{provider: job.provider, job_id: job.id},
      fn ->
        refresh_status(job)
      end
    )
  end

  @doc "Cancels a provider training job when its trainer supplied a cancellation URL."
  def cancel(%__MODULE__{cancel_url: nil}), do: {:error, :training_cancel_not_supported}

  def cancel(%__MODULE__{} = job) do
    DSEx.Telemetry.span(
      [:dsex, :training, :cancel],
      %{provider: job.provider, job_id: job.id},
      fn -> change_status(job, job.cancel_url, :cancel) end
    )
  end

  @doc "Returns a JSON-safe, credential-free training job checkpoint."
  def dump(%__MODULE__{} = job) do
    %{
      "type" => "dsex_training_job",
      "schema_version" => 1,
      "id" => job.id,
      "provider" => job.provider,
      "model" => job.model,
      "status" => dump_status(job.status),
      "training_data" => DSEx.Redaction.redact(job.training_data),
      "result_model" => job.result_model,
      "status_url" => job.status_url,
      "cancel_url" => job.cancel_url,
      "idempotency_key" => DSEx.Redaction.redact(job.idempotency_key),
      "max_attempts" => job.max_attempts,
      "retry_backoff_ms" => job.retry_backoff_ms,
      "metadata" => DSEx.Redaction.redact(job.metadata)
    }
    |> json_normalize!()
  end

  @doc "Restores a training job checkpoint, with transport and credentials supplied explicitly."
  def load(state, opts \\ [])

  def load(%{"type" => "dsex_training_job", "schema_version" => 1} = state, opts) do
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
      api_key: Keyword.get(opts, :api_key),
      idempotency_key: state["idempotency_key"],
      max_attempts: Map.get(state, "max_attempts", 3),
      retry_backoff_ms: Map.get(state, "retry_backoff_ms", 100),
      metadata: Map.get(state, "metadata", %{})
    })
  end

  def load(state, _opts) do
    raise ArgumentError, "invalid DSEx training job checkpoint: #{inspect(state)}"
  end

  @doc "Atomically persists a credential-free training job checkpoint."
  def save!(%__MODULE__{} = job, path) when is_binary(path) do
    payload = dump(job)

    artifact = %{
      "artifact_type" => "dsex_training_job_checkpoint",
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
        "artifact_type" => "dsex_training_job_checkpoint",
        "schema_version" => 1,
        "payload_sha256" => checksum,
        "payload" => payload
      } ->
        unless is_binary(checksum) and :crypto.hash_equals(checksum, payload_checksum(payload)) do
          raise ArgumentError, "saved DSEx training job checkpoint checksum mismatch"
        end

        load(payload, opts)

      state ->
        load(state, opts)
    end
  end

  @doc "Rebinds a program to the provider model artifact and optionally persists it."
  def rebind(%__MODULE__{} = job, program, opts \\ []) do
    with :ok <- validate_rebind_opts(opts),
         :ok <- require_artifact(job),
         {:ok, lm} <- rebound_lm(DSEx.ProgramAccess.lm(program), job.result_model) do
      rebound =
        program
        |> DSEx.ProgramAccess.put_lm(lm)
        |> DSEx.ProgramAccess.put_metadata(:training_artifact, %{
          provider: job.provider,
          job_id: job.id,
          base_model: job.model,
          result_model: job.result_model
        })

      case Keyword.get(opts, :path) do
        nil ->
          {:ok, rebound}

        path when is_binary(path) ->
          :ok = DSEx.Saving.save!(rebound, path)
          {:ok, rebound}
      end
    end
  rescue
    error -> {:error, {:training_rebind_failed, DSEx.Redaction.redact(Exception.message(error))}}
  end

  def complete(%__MODULE__{} = job, result_model),
    do: enforce_artifact(%{job | status: :succeeded, result_model: result_model})

  def fail(%__MODULE__{} = job, reason),
    do: %{
      job
      | status: :failed,
        metadata: Map.put(job.metadata, :error, DSEx.Redaction.redact(reason))
    }

  @doc false
  def validate_terminal(%__MODULE__{} = job), do: enforce_artifact(job)

  @doc """
  Normalizes external provider status names into DSEx job lifecycle atoms.

      iex> DSEx.Clients.TrainingJob.normalize_status("completed")
      :succeeded
      iex> DSEx.Clients.TrainingJob.normalize_status("queued")
      :pending
      iex> DSEx.Clients.TrainingJob.normalize_status("provider-paused")
      {:unknown, "provider-paused"}
  """
  def normalize_status(status) when is_atom(status), do: status
  def normalize_status({:unknown, status}) when is_binary(status), do: {:unknown, status}

  def normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      normalized when normalized in ["succeeded", "completed", "success"] -> :succeeded
      normalized when normalized in ["failed", "error"] -> :failed
      normalized when normalized in ["cancelled", "canceled"] -> :cancelled
      normalized when normalized in ["running", "in_progress"] -> :running
      normalized when normalized in ["pending", "queued"] -> :pending
      "artifact_missing" -> :artifact_missing
      "created" -> :created
      "submitted" -> :submitted
      _other -> {:unknown, status}
    end
  end

  def normalize_status(other), do: {:unknown, to_string(other)}

  defp normalize_attrs!(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        {key, value}

      invalid ->
        raise ArgumentError,
              "DSEx.Clients.TrainingJob.new/1 expects attrs as atom or string keyed pairs; got entry: #{inspect(invalid)}"
    end)
  end

  defp fetch_attr(attrs, key, default \\ nil) when is_atom(key),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp refresh_status(%__MODULE__{} = job) do
    change_status(job, job.status_url, :refresh)
  end

  defp change_status(%__MODULE__{} = job, url, operation) do
    body = Jason.encode!(%{job_id: job.id})

    {:ok, idempotency_key} =
      DSEx.Clients.TrainingHTTP.idempotency_key(
        job.provider,
        job.id,
        body,
        operation_idempotency_key(job, operation)
      )

    headers =
      ([{"content-type", "application/json"}] ++ auth_headers(job.api_key))
      |> DSEx.Clients.TrainingHTTP.put_header("idempotency-key", idempotency_key)

    case DSEx.Clients.TrainingHTTP.request(
           job.transport || DSEx.HTTP.Hackneyless,
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
        {:error, {:http_error, status, DSEx.Clients.TrainingHTTP.redact_response(response)}}

      {:error, {:http_transport_failed, _transport, reason}} ->
        {:error, {operation_failure(operation), DSEx.Redaction.redact(reason)}}

      {:error, reason} ->
        {:error, DSEx.Redaction.redact(reason)}

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
        {:ok, merge_status(job, decoded)}

      {:ok, decoded} ->
        {:error, {invalid_operation_response(operation), decoded}}

      {:error, reason} ->
        {:error, {invalid_operation_response(operation), Exception.message(reason)}}
    end
  end

  defp merge_status(job, decoded) do
    enforce_artifact(%{
      job
      | status: __MODULE__.normalize_status(decoded["status"] || decoded["state"] || job.status),
        result_model:
          decoded["fine_tuned_model"] || decoded["result_model"] || decoded["model_output"] ||
            job.result_model,
        metadata:
          Map.merge(job.metadata, %{"last_status_response" => DSEx.Redaction.redact(decoded)})
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

  defp rebound_lm(%DSEx.Clients.ReqLLM{} = lm, model), do: {:ok, %{lm | model: model}}
  defp rebound_lm(%{model: _} = lm, model), do: {:ok, Map.put(lm, :model, model)}
  defp rebound_lm(nil, _model), do: {:error, :training_program_lm_required}
  defp rebound_lm(_lm, _model), do: {:error, :training_program_lm_not_rebindable}

  defp validate_rebind_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 == :path)) and
         (is_nil(opts[:path]) or is_binary(opts[:path])) do
      :ok
    else
      {:error, :invalid_training_rebind_options}
    end
  end

  defp validate_rebind_opts(_opts), do: {:error, :invalid_training_rebind_options}

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
        case DSEx.HTTP.validate_transport(transport) do
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
  defp load_provider("local"), do: :local
  defp load_provider(provider), do: provider

  defp operation_idempotency_key(%__MODULE__{idempotency_key: nil}, _operation), do: nil

  defp operation_idempotency_key(%__MODULE__{idempotency_key: key}, operation),
    do: key <> ":" <> Atom.to_string(operation)

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

defmodule DSEx.Clients.Trainer do
  @moduledoc "Behaviour for provider-specific training backends."

  @callback finetune(
              term(),
              list(DSEx.Example.t()),
              keyword()
            ) ::
              {:ok, DSEx.Clients.TrainingJob.t()} | {:error, term()}
  @callback finetune(
              term(),
              term(),
              list(DSEx.Example.t()),
              keyword()
            ) ::
              {:ok, DSEx.Clients.TrainingJob.t()} | {:error, term()}
  @optional_callbacks finetune: 3, finetune: 4

  def finetune(provider, lm, examples, opts \\ [])

  def finetune(provider, lm, examples, opts) do
    opts = validate_opts!(opts)
    examples = validate_examples!(examples)

    do_finetune(provider, lm, examples, opts)
  end

  def validate_provider(nil), do: {:ok, nil}
  def validate_provider(provider) when is_atom(provider), do: {:ok, provider}
  def validate_provider(provider) when is_function(provider, 3), do: {:ok, provider}
  def validate_provider(%_{} = provider), do: {:ok, provider}

  def validate_provider(_provider) do
    {:error, "expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback"}
  end

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
    case Enum.find(examples, &(not match?(%DSEx.Example{}, &1))) do
      nil ->
        examples

      invalid ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.finetune/4 expects examples as DSEx.Example structs, got entry: #{inspect(invalid)}"
    end
  end

  defp validate_examples!(examples) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.finetune/4 expects a list of examples, got: #{inspect(examples)}"
  end

  defp call_trainer(fun, trainer) do
    case fun.() do
      {:ok, %DSEx.Clients.TrainingJob{} = job} ->
        {:ok, DSEx.Clients.TrainingJob.validate_terminal(job)}

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
    do: exception |> Exception.message() |> DSEx.Redaction.redact()

  defp error_message(error), do: error |> inspect() |> DSEx.Redaction.redact()
end

defmodule DSEx.Clients.HTTPTrainer do
  @moduledoc "Provider trainer that submits finetuning data to HTTP APIs."

  @behaviour DSEx.Clients.Trainer

  defstruct [
    :provider,
    :submit_url,
    :status_url,
    :cancel_url,
    :api_key,
    transport: DSEx.HTTP.Hackneyless,
    headers: [],
    payload_builder: nil,
    response_mapper: nil,
    max_attempts: 3,
    retry_backoff_ms: 100
  ]

  @option_schema [
    status_url: [type: {:or, [:string, nil]}],
    cancel_url: [type: {:or, [:string, nil]}],
    api_key: [type: {:or, [:string, nil]}],
    transport: [type: {:custom, DSEx.HTTP, :validate_transport, []}],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    payload_builder: [type: {:fun, 3}],
    response_mapper: [type: {:fun, 4}],
    max_attempts: [type: :pos_integer, default: 3],
    retry_backoff_ms: [type: :non_neg_integer, default: 100]
  ]

  def new(provider, submit_url, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/3")

    %__MODULE__{
      provider: provider,
      submit_url: submit_url,
      status_url: Keyword.get(opts, :status_url),
      cancel_url: Keyword.get(opts, :cancel_url),
      api_key: Keyword.get(opts, :api_key),
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      payload_builder: Keyword.get(opts, :payload_builder, &default_payload/3),
      response_mapper: Keyword.get(opts, :response_mapper, &default_response/4),
      max_attempts: opts[:max_attempts],
      retry_backoff_ms: opts[:retry_backoff_ms]
    }
  end

  def finetune(%__MODULE__{} = trainer, lm, examples, opts) do
    opts = validate_call_opts!(opts)
    examples = validate_examples!(examples)

    DSEx.Telemetry.span(
      [:dsex, :training, :submit],
      %{provider: trainer.provider, model: Map.get(lm, :model)},
      fn ->
        submit(trainer, lm, examples, opts)
      end
    )
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
    case Enum.find(examples, &(not match?(%DSEx.Example{}, &1))) do
      nil ->
        examples

      invalid ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.finetune/4 expects examples as DSEx.Example structs, got entry: #{inspect(invalid)}"
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
      training_data: Enum.map(examples, &DSEx.Example.to_map/1)
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
    with {:ok, payload} <- build_payload(trainer, lm, examples, opts),
         {:ok, body} <- encode_payload(payload),
         {:ok, request_policy} <- request_policy(trainer, lm, body, opts),
         headers <-
           ([{"content-type", "application/json"}] ++
              auth_headers(trainer.api_key) ++ trainer.headers)
           |> DSEx.Clients.TrainingHTTP.put_header(
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

  defp encode_payload(payload) do
    {:ok, Jason.encode!(payload)}
  rescue
    error -> {:error, {:invalid_training_payload, Exception.message(error)}}
  end

  defp post_training(trainer, body, headers, opts, request_policy) do
    case DSEx.Clients.TrainingHTTP.request(
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
        {:error, {:http_error, status, DSEx.Clients.TrainingHTTP.redact_response(response)}}

      {:error, {:http_transport_failed, _transport, reason}} ->
        {:error, {:training_transport_failed, DSEx.Redaction.redact(reason)}}

      {:error, reason} ->
        {:error, DSEx.Redaction.redact(reason)}

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
      %DSEx.Clients.TrainingJob{} = job ->
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
        DSEx.Clients.TrainingJob.new(%{
          id: id,
          provider: trainer.provider,
          model: Map.get(lm, :model),
          status:
            DSEx.Clients.TrainingJob.normalize_status(
              decoded["status"] || decoded["state"] || :submitted
            ),
          training_data: examples |> Enum.map(&DSEx.Example.to_map/1) |> DSEx.Redaction.redact(),
          result_model: decoded["fine_tuned_model"] || decoded["result_model"],
          transport: trainer.transport,
          status_url: status_url(trainer, decoded),
          cancel_url: endpoint_url(trainer.cancel_url, decoded),
          api_key: trainer.api_key,
          max_attempts: trainer.max_attempts,
          retry_backoff_ms: trainer.retry_backoff_ms,
          metadata: %{"submit_response" => DSEx.Redaction.redact(decoded)}
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
               DSEx.Clients.TrainingHTTP.idempotency_key(
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
    Keyword.drop(opts, [:idempotency_key, :max_attempts, :retry_backoff_ms])
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

defimpl Inspect, for: DSEx.Clients.HTTPTrainer do
  import Inspect.Algebra

  def inspect(trainer, opts) do
    trainer
    |> Map.from_struct()
    |> DSEx.Redaction.redact()
    |> then(&concat(["#DSEx.Clients.HTTPTrainer<", to_doc(&1, opts), ">"]))
  end
end

defimpl Inspect, for: DSEx.Clients.TrainingJob do
  import Inspect.Algebra

  def inspect(job, opts) do
    job
    |> Map.from_struct()
    |> DSEx.Redaction.redact()
    |> then(&concat(["#DSEx.Clients.TrainingJob<", to_doc(&1, opts), ">"]))
  end
end

defmodule DSEx.Clients.OpenAITrainer do
  @moduledoc """
  OpenAI fine-tuning job client.

  This client submits an OpenAI fine-tuning job for an existing uploaded
  training file. It does not upload examples itself; callers must provide
  `:training_file` either to `new/1` or to `Trainer.finetune/4`.
  """

  @option_schema [
    base_url: [type: :string],
    api_key: [type: {:or, [:string, nil]}],
    transport: [type: {:custom, DSEx.HTTP, :validate_transport, []}],
    training_file: [type: :string],
    validation_file: [type: :string],
    suffix: [type: :string],
    metadata: [type: :map],
    max_attempts: [type: :pos_integer, default: 3],
    retry_backoff_ms: [type: :non_neg_integer, default: 100]
  ]

  def new(opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/1")

    base =
      Keyword.get(opts, :base_url) || System.get_env("OPENAI_BASE_URL") ||
        "https://api.openai.com/v1"

    api_key = provider_api_key(opts, "OPENAI_API_KEY")

    defaults = Keyword.take(opts, [:training_file, :validation_file, :suffix, :metadata])

    DSEx.Clients.HTTPTrainer.new(
      :openai,
      String.trim_trailing(base, "/") <> "/fine_tuning/jobs",
      api_key: api_key,
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      max_attempts: opts[:max_attempts],
      retry_backoff_ms: opts[:retry_backoff_ms],
      status_url: String.trim_trailing(base, "/") <> "/fine_tuning/jobs/{id}",
      cancel_url: String.trim_trailing(base, "/") <> "/fine_tuning/jobs/{id}/cancel",
      payload_builder: fn lm, examples, call_opts ->
        payload(lm, examples, Keyword.merge(defaults, call_opts))
      end
    )
  end

  defp payload(lm, _examples, opts) do
    case Keyword.fetch(opts, :training_file) do
      {:ok, training_file} ->
        {:ok,
         %{
           model: Map.get(lm, :model),
           training_file: training_file
         }
         |> maybe_put(:validation_file, Keyword.get(opts, :validation_file))
         |> maybe_put(:suffix, Keyword.get(opts, :suffix))
         |> maybe_put(:metadata, Keyword.get(opts, :metadata))
         |> maybe_put(:hyperparameters, map_or_nil(Keyword.get(opts, :hyperparameters)))}

      :error ->
        {:error, :openai_training_file_required}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp map_or_nil(nil), do: nil
  defp map_or_nil(values), do: Map.new(values)

  defp provider_api_key(opts, env_key) do
    cond do
      Keyword.has_key?(opts, :api_key) -> Keyword.get(opts, :api_key)
      Keyword.has_key?(opts, :base_url) -> nil
      true -> System.get_env(env_key)
    end
  end
end

defmodule DSEx.Clients.DatabricksTrainer do
  @moduledoc "Databricks training job contract."

  @option_schema [
    base_url: [type: :string],
    api_key: [type: {:or, [:string, nil]}],
    transport: [type: {:custom, DSEx.HTTP, :validate_transport, []}],
    max_attempts: [type: :pos_integer, default: 3],
    retry_backoff_ms: [type: :non_neg_integer, default: 100]
  ]

  def new(opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/1")

    base =
      Keyword.get(opts, :base_url) || System.get_env("DATABRICKS_BASE_URL") ||
        "https://example.cloud.databricks.com"

    api_key = provider_api_key(opts, "DATABRICKS_TOKEN")

    DSEx.Clients.HTTPTrainer.new(
      :databricks,
      String.trim_trailing(base, "/") <> "/api/2.0/dsex/finetune",
      api_key: api_key,
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      max_attempts: opts[:max_attempts],
      retry_backoff_ms: opts[:retry_backoff_ms],
      status_url: String.trim_trailing(base, "/") <> "/api/2.0/dsex/finetune/{id}",
      cancel_url: String.trim_trailing(base, "/") <> "/api/2.0/dsex/finetune/{id}/cancel",
      payload_builder: &payload/3
    )
  end

  defp payload(lm, examples, opts) do
    %{
      base_model: Map.get(lm, :model),
      task_type: Keyword.get(opts, :method, :sft),
      train_data: Enum.map(examples, &DSEx.Example.to_map/1),
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

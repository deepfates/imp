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
          api_key: String.t() | nil,
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
    :api_key,
    metadata: %{}
  ]

  def new(attrs) do
    %__MODULE__{
      id:
        Map.get(attrs, :id) ||
          "train-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      provider: Map.get(attrs, :provider, :local),
      model: Map.get(attrs, :model),
      status: Map.get(attrs, :status, :created),
      training_data: Map.get(attrs, :training_data, []),
      result_model: Map.get(attrs, :result_model),
      transport: Map.get(attrs, :transport),
      status_url: Map.get(attrs, :status_url),
      api_key: Map.get(attrs, :api_key),
      metadata: Map.get(attrs, :metadata, %{})
    }
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

  def complete(%__MODULE__{} = job, result_model),
    do: %{job | status: :succeeded, result_model: result_model}

  def fail(%__MODULE__{} = job, reason),
    do: %{job | status: :failed, metadata: Map.put(job.metadata, :error, reason)}

  defp refresh_status(%__MODULE__{} = job) do
    body = Jason.encode!(%{job_id: job.id})
    headers = [{"content-type", "application/json"}] ++ auth_headers(job.api_key)

    case DSEx.HTTP.post(
           job.transport || DSEx.HTTP.Hackneyless,
           job.status_url,
           headers,
           body,
           []
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        decode_status_response(job, response)

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, {:http_transport_failed, _transport, reason}} ->
        {:error, {:training_refresh_failed, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_training_refresh_response, other}}
    end
  rescue
    error -> {:error, {:training_refresh_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:training_refresh_failed, inspect({kind, reason})}}
  end

  defp decode_status_response(job, response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, merge_status(job, decoded)}

      {:ok, decoded} ->
        {:error, {:invalid_training_refresh_response, decoded}}

      {:error, reason} ->
        {:error, {:invalid_training_refresh_response, Exception.message(reason)}}
    end
  end

  defp merge_status(job, decoded) do
    %{
      job
      | status: normalize_status(decoded["status"] || decoded["state"] || job.status),
        result_model:
          decoded["fine_tuned_model"] || decoded["result_model"] || decoded["model_output"] ||
            job.result_model,
        metadata: Map.merge(job.metadata, %{"last_status_response" => decoded})
    }
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("succeeded"), do: :succeeded
  defp normalize_status("completed"), do: :succeeded
  defp normalize_status("success"), do: :succeeded
  defp normalize_status("failed"), do: :failed
  defp normalize_status("cancelled"), do: :cancelled
  defp normalize_status("running"), do: :running
  defp normalize_status("pending"), do: :pending
  defp normalize_status(other), do: {:unknown, to_string(other)}

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
      {:ok, %DSEx.Clients.TrainingJob{}} = success -> success
      {:error, _reason} = error -> error
      {:ok, other} -> {:error, {:invalid_trainer_result, other}}
      other -> {:error, {:invalid_trainer_result, other}}
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

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

defmodule DSEx.Clients.HTTPTrainer do
  @moduledoc "Provider trainer that submits finetuning data to HTTP APIs."

  @behaviour DSEx.Clients.Trainer

  defstruct [
    :provider,
    :submit_url,
    :status_url,
    :api_key,
    transport: DSEx.HTTP.Hackneyless,
    headers: [],
    payload_builder: nil,
    response_mapper: nil
  ]

  @option_schema [
    status_url: [type: {:or, [:string, nil]}],
    api_key: [type: {:or, [:string, nil]}],
    transport: [type: {:custom, DSEx.HTTP, :validate_transport, []}],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    payload_builder: [type: {:fun, 3}],
    response_mapper: [type: {:fun, 4}]
  ]

  def new(provider, submit_url, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/3")

    %__MODULE__{
      provider: provider,
      submit_url: submit_url,
      status_url: Keyword.get(opts, :status_url),
      api_key: Keyword.get(opts, :api_key),
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      payload_builder: Keyword.get(opts, :payload_builder, &default_payload/3),
      response_mapper: Keyword.get(opts, :response_mapper, &default_response/4)
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
         headers <-
           [{"content-type", "application/json"}] ++
             auth_headers(trainer.api_key) ++ trainer.headers,
         {:ok, response} <- post_training(trainer, body, headers, opts),
         {:ok, decoded} <- decode_training_response(response),
         {:ok, job} <- map_training_response(trainer, lm, examples, decoded) do
      {:ok, job}
    end
  end

  defp encode_payload(payload) do
    {:ok, Jason.encode!(payload)}
  rescue
    error -> {:error, {:invalid_training_payload, Exception.message(error)}}
  end

  defp post_training(trainer, body, headers, opts) do
    case DSEx.HTTP.post(trainer.transport, trainer.submit_url, headers, body, opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, {:http_transport_failed, _transport, reason}} ->
        {:error, {:training_transport_failed, reason}}

      {:error, reason} ->
        {:error, reason}

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

  defp map_training_response(trainer, lm, examples, decoded) do
    case trainer.response_mapper.(trainer, lm, examples, decoded) do
      %DSEx.Clients.TrainingJob{} = job -> {:ok, job}
      other -> {:error, {:invalid_training_job, other}}
    end
  rescue
    error -> {:error, {:invalid_training_job, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:invalid_training_job, inspect({kind, reason})}}
  end

  defp default_response(trainer, lm, examples, decoded) do
    DSEx.Clients.TrainingJob.new(%{
      id: decoded["id"] || decoded["job_id"],
      provider: trainer.provider,
      model: Map.get(lm, :model),
      status: normalize_status(decoded["status"] || decoded["state"] || :submitted),
      training_data: Enum.map(examples, &DSEx.Example.to_map/1),
      result_model: decoded["fine_tuned_model"] || decoded["result_model"],
      transport: trainer.transport,
      status_url: status_url(trainer, decoded),
      api_key: trainer.api_key,
      metadata: %{"submit_response" => decoded}
    })
  end

  defp status_url(%__MODULE__{status_url: nil}, _decoded), do: nil

  defp status_url(%__MODULE__{status_url: template}, decoded) do
    String.replace(template, "{id}", to_string(decoded["id"] || decoded["job_id"]))
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("succeeded"), do: :succeeded
  defp normalize_status("completed"), do: :succeeded
  defp normalize_status("success"), do: :succeeded
  defp normalize_status("failed"), do: :failed
  defp normalize_status("cancelled"), do: :cancelled
  defp normalize_status("running"), do: :running
  defp normalize_status("pending"), do: :pending
  defp normalize_status(other), do: {:unknown, to_string(other)}

  defp auth_headers(nil), do: []
  defp auth_headers(key), do: [{"authorization", "Bearer #{key}"}]
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
    metadata: [type: :map]
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
      status_url: String.trim_trailing(base, "/") <> "/fine_tuning/jobs/{id}",
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
    transport: [type: {:custom, DSEx.HTTP, :validate_transport, []}]
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
      status_url: String.trim_trailing(base, "/") <> "/api/2.0/dsex/finetune/{id}",
      payload_builder: &payload/3
    )
  end

  defp payload(lm, examples, opts) do
    %{
      base_model: Map.get(lm, :model),
      task_type: Keyword.get(opts, :method, :sft),
      train_data: Enum.map(examples, &DSEx.Example.to_map/1),
      config: Map.new(Keyword.drop(opts, [:method]))
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

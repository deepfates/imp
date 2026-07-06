defmodule Dachshund.Clients.TrainingJob do
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
    body = Jason.encode!(%{job_id: job.id})
    headers = [{"content-type", "application/json"}] ++ auth_headers(job.api_key)

    with {:ok, %{status: status, body: response}} when status in 200..299 <-
           Dachshund.HTTP.post(
             job.transport || Dachshund.HTTP.Hackneyless,
             job.status_url,
             headers,
             body,
             []
           ),
         {:ok, decoded} <- Jason.decode(response) do
      {:ok, merge_status(job, decoded)}
    else
      {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete(%__MODULE__{} = job, result_model),
    do: %{job | status: :succeeded, result_model: result_model}

  def fail(%__MODULE__{} = job, reason),
    do: %{job | status: :failed, metadata: Map.put(job.metadata, :error, reason)}

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

defmodule Dachshund.Clients.Trainer do
  @moduledoc "Behaviour for provider-specific training backends."

  @callback finetune(
              Dachshund.Clients.HTTPLM.t() | term(),
              list(Dachshund.Example.t()),
              keyword()
            ) ::
              {:ok, Dachshund.Clients.TrainingJob.t()} | {:error, term()}
  @callback finetune(
              term(),
              Dachshund.Clients.HTTPLM.t() | term(),
              list(Dachshund.Example.t()),
              keyword()
            ) ::
              {:ok, Dachshund.Clients.TrainingJob.t()} | {:error, term()}
  @optional_callbacks finetune: 3, finetune: 4

  def finetune(provider, lm, examples, opts \\ [])

  def finetune(module, lm, examples, opts) when is_atom(module),
    do: module.finetune(lm, examples, opts)

  def finetune(%module{} = trainer, lm, examples, opts) do
    if function_exported?(module, :finetune, 4) do
      module.finetune(trainer, lm, examples, opts)
    else
      {:error, {:not_a_trainer, module}}
    end
  end

  def finetune(fun, lm, examples, opts) when is_function(fun, 3), do: fun.(lm, examples, opts)
end

defmodule Dachshund.Clients.HTTPTrainer do
  @moduledoc "Provider trainer that submits finetuning data to HTTP APIs."

  @behaviour Dachshund.Clients.Trainer

  defstruct [
    :provider,
    :submit_url,
    :status_url,
    :api_key,
    transport: Dachshund.HTTP.Hackneyless,
    headers: [],
    payload_builder: nil,
    response_mapper: nil
  ]

  def new(provider, submit_url, opts \\ []) do
    %__MODULE__{
      provider: provider,
      submit_url: submit_url,
      status_url: Keyword.get(opts, :status_url),
      api_key: Keyword.get(opts, :api_key),
      transport: Keyword.get(opts, :transport, Dachshund.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      payload_builder: Keyword.get(opts, :payload_builder, &default_payload/3),
      response_mapper: Keyword.get(opts, :response_mapper, &default_response/4)
    }
  end

  def finetune(%__MODULE__{} = trainer, lm, examples, opts) do
    payload = trainer.payload_builder.(lm, examples, opts)
    body = Jason.encode!(payload)

    headers =
      [{"content-type", "application/json"}] ++
        auth_headers(trainer.api_key) ++ trainer.headers

    with {:ok, %{status: status, body: response}} when status in 200..299 <-
           Dachshund.HTTP.post(trainer.transport, trainer.submit_url, headers, body, opts),
         {:ok, decoded} <- Jason.decode(response) do
      {:ok, trainer.response_mapper.(trainer, lm, examples, decoded)}
    else
      {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
      {:error, reason} -> {:error, reason}
    end
  end

  def finetune(trainer, lm, examples, opts) when is_map(trainer) do
    finetune(struct(__MODULE__, trainer), lm, examples, opts)
  end

  defp default_payload(lm, examples, opts) do
    %{
      model: Map.get(lm, :model),
      method: Keyword.get(opts, :method, :sft),
      training_data: Enum.map(examples, &Dachshund.Example.to_map/1)
    }
  end

  defp default_response(trainer, lm, examples, decoded) do
    Dachshund.Clients.TrainingJob.new(%{
      id: decoded["id"] || decoded["job_id"],
      provider: trainer.provider,
      model: Map.get(lm, :model),
      status: normalize_status(decoded["status"] || decoded["state"] || :submitted),
      training_data: Enum.map(examples, &Dachshund.Example.to_map/1),
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

defmodule Dachshund.Clients.OpenAITrainer do
  @moduledoc "OpenAI fine-tuning trainer contract."

  def new(opts \\ []) do
    base =
      Keyword.get(opts, :base_url) || System.get_env("OPENAI_BASE_URL") ||
        "https://api.openai.com/v1"

    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    Dachshund.Clients.HTTPTrainer.new(
      :openai,
      String.trim_trailing(base, "/") <> "/fine_tuning/jobs",
      api_key: api_key,
      transport: Keyword.get(opts, :transport, Dachshund.HTTP.Hackneyless),
      status_url: String.trim_trailing(base, "/") <> "/fine_tuning/jobs/{id}",
      payload_builder: &payload/3
    )
  end

  defp payload(lm, examples, opts) do
    %{
      model: Map.get(lm, :model),
      training_file: Keyword.get(opts, :training_file, "inline://dachshund"),
      hyperparameters: Map.new(Keyword.get(opts, :hyperparameters, [])),
      Dachshund_training_data: Enum.map(examples, &Dachshund.Example.to_map/1)
    }
  end
end

defmodule Dachshund.Clients.DatabricksTrainer do
  @moduledoc "Databricks training job contract."

  def new(opts \\ []) do
    base =
      Keyword.get(opts, :base_url) || System.get_env("DATABRICKS_BASE_URL") ||
        "https://example.cloud.databricks.com"

    api_key = Keyword.get(opts, :api_key) || System.get_env("DATABRICKS_TOKEN")

    Dachshund.Clients.HTTPTrainer.new(
      :databricks,
      String.trim_trailing(base, "/") <> "/api/2.0/Dachshund/finetune",
      api_key: api_key,
      transport: Keyword.get(opts, :transport, Dachshund.HTTP.Hackneyless),
      status_url: String.trim_trailing(base, "/") <> "/api/2.0/Dachshund/finetune/{id}",
      payload_builder: &payload/3
    )
  end

  defp payload(lm, examples, opts) do
    %{
      base_model: Map.get(lm, :model),
      task_type: Keyword.get(opts, :method, :sft),
      train_data: Enum.map(examples, &Dachshund.Example.to_map/1),
      config: Map.new(Keyword.drop(opts, [:method]))
    }
  end
end

defmodule Dachshund.Clients.LocalTrainer do
  @moduledoc "Deterministic local trainer that records data and returns a completed job."

  @behaviour Dachshund.Clients.Trainer

  @impl true
  def finetune(lm, examples, opts) do
    suffix = Keyword.get(opts, :suffix, "finetuned")
    model = Map.get(lm, :model, "local-model")

    {:ok,
     Dachshund.Clients.TrainingJob.new(%{
       provider: :local,
       model: model,
       status: :succeeded,
       training_data: Enum.map(examples, &Dachshund.Example.to_map/1),
       result_model: "#{model}:#{suffix}"
     })}
  end
end

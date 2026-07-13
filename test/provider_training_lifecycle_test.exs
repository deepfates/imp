defmodule ProviderTrainingLifecycleTest do
  use ExUnit.Case

  defmodule OpenAITrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      if String.ends_with?(url, "/files") do
        send(self(), {:openai_file_upload, url, headers, IO.iodata_to_binary(body)})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{id: "file-uploaded-demos", purpose: "fine-tune"})
         }}
      else
        decoded = Jason.decode!(body)
        send(self(), {:openai_training_request, url, headers, decoded})

        response(url, decoded)
      end
    end

    defp response(url, decoded) do
      cond do
        String.ends_with?(url, "/chat/completions") ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body: Jason.encode!(%{choices: [%{message: %{content: "Answer: 4"}}]})
           }}

        String.ends_with?(url, "/fine_tuning/jobs") ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body: Jason.encode!(%{id: "ftjob_123", status: "running", model: decoded["model"]})
           }}

        String.ends_with?(url, "/fine_tuning/jobs/ftjob_123/cancel") ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body: Jason.encode!(%{id: "ftjob_123", status: "cancelled"})
           }}

        String.ends_with?(url, "/fine_tuning/jobs/ftjob_123") ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body:
               Jason.encode!(%{
                 id: "ftjob_123",
                 status: "succeeded",
                 fine_tuned_model: "ft:gpt-test:org:abc"
               })
           }}
      end
    end
  end

  defmodule GRPOTrainingFixture do
    @behaviour DSEx.Clients.Trainer

    defstruct []

    @impl true
    def supported_methods(%__MODULE__{}), do: [:grpo]

    @impl true
    def finetune(%__MODULE__{}, trainer_lm, enriched, opts) do
      send(self(), {:grpo_finetune, trainer_lm, enriched, opts})
      {:ok, DSEx.Clients.TrainingJob.new(%{id: "job_grpo", provider: :test})}
    end
  end

  defmodule DatabricksTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      decoded = Jason.decode!(body)
      send(self(), {:databricks_training_request, url, headers, decoded})

      response =
        cond do
          String.ends_with?(url, "/dbx_1/cancel") ->
            %{job_id: "dbx_1", state: "CANCELED"}

          String.ends_with?(url, "/dbx_1") ->
            %{job_id: "dbx_1", state: "SUCCESS", result_model: "dbx-model-output"}

          true ->
            %{job_id: "dbx_1", state: "PENDING", result_model: nil}
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(response)}}
    end
  end

  defmodule RetryTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      attempt = Process.get({__MODULE__, url}, 0) + 1
      Process.put({__MODULE__, url}, attempt)
      send(self(), {:retry_training_request, attempt, headers, Jason.decode!(body)})

      if attempt == 1 do
        {:error, :connection_closed_after_write}
      else
        {:ok,
         %{
           status: 200,
           headers: [],
           body:
             Jason.encode!(%{
               id: "retry_job",
               status: "running",
               api_key: "sk-provider-response-secret-1234567890"
             })
         }}
      end
    end
  end

  defmodule SecretErrorTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      {:ok,
       %{
         status: 400,
         headers: [],
         body: Jason.encode!(%{error: "sk-provider-error-secret-1234567890"})
       }}
    end
  end

  defmodule RetryLifecycleTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      attempt = Process.get({__MODULE__, url}, 0) + 1
      Process.put({__MODULE__, url}, attempt)
      send(self(), {:retry_lifecycle_request, url, attempt, headers})

      if attempt == 1 do
        {:ok, %{status: 503, headers: [], body: Jason.encode!(%{error: "try again"})}}
      else
        status = if String.ends_with?(url, "/cancel"), do: "cancelled", else: "succeeded"

        response =
          %{id: "retry_lifecycle_job", status: status}
          |> Map.put(:fine_tuned_model, "retry-lifecycle-model")

        assert Jason.decode!(body)["job_id"] == "retry_lifecycle_job"
        {:ok, %{status: 200, headers: [], body: Jason.encode!(response)}}
      end
    end
  end

  defmodule RaisingTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: raise("transport exploded")
  end

  defmodule InvalidJSONTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      {:ok, %{status: 200, headers: [], body: "not json"}}
    end
  end

  defmodule InvalidShapeTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: :not_an_http_response
  end

  defmodule MissingJobIdTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "running"})}}
    end
  end

  defmodule SecretRefreshTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, headers, _body, _opts) do
      assert {"authorization", "Bearer sk-test-secret-1234567890"} in headers

      {:ok,
       %{
         status: 200,
         headers: [],
         body:
           Jason.encode!(%{
             id: "job_secret",
             status: "succeeded",
             fine_tuned_model: "model-secret-fixture"
           })
       }}
    end
  end

  defp examples do
    [
      DSEx.example(question: "2+2?", answer: "4") |> DSEx.Example.with_inputs(:question)
    ]
  end

  test "OpenAI trainer submits job and refreshes lifecycle status" do
    ref =
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :training, :submit, :start],
        [:dsex, :training, :refresh, :start]
      ])

    lm = DSEx.req_llm("gpt-test")

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:ok, job} =
             DSEx.Clients.Trainer.finetune(trainer, lm, examples(),
               training_file: "file-abc",
               hyperparameters: [n_epochs: 1]
             )

    assert %DSEx.Clients.TrainingJob{id: "ftjob_123", provider: :openai, status: :running} =
             job

    assert_received {:openai_training_request, "https://api.example/v1/fine_tuning/jobs", headers,
                     payload}

    assert {"authorization", "Bearer sk-test"} in headers
    assert payload["model"] == "gpt-test"
    assert payload["training_file"] == "file-abc"
    assert payload["hyperparameters"] == %{"n_epochs" => 1}
    refute Map.has_key?(payload, "dsex_training_data")

    assert {:ok, refreshed} = DSEx.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "ft:gpt-test:org:abc"

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-trained-program-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, rebound} =
             DSEx.Clients.TrainingJob.rebind(refreshed, program, path: path)

    assert %DSEx.Clients.ReqLLM{model: "ft:gpt-test:org:abc"} =
             DSEx.ProgramAccess.lm(rebound)

    assert DSEx.ProgramAccess.get_metadata(rebound, :training_artifact) == %{
             provider: :openai,
             job_id: "ftjob_123",
             base_model: "gpt-test",
             result_model: "ft:gpt-test:org:abc"
           }

    loaded = DSEx.load!(path)
    assert %DSEx.Clients.ReqLLM{model: "ft:gpt-test:org:abc"} = DSEx.ProgramAccess.lm(loaded)

    assert_received {^ref, [:dsex, :training, :submit, :start], _, %{provider: :openai}}
    assert_received {^ref, [:dsex, :training, :refresh, :start], _, %{job_id: "ftjob_123"}}
  end

  test "training jobs normalize provider lifecycle status at construction and refresh" do
    assert %DSEx.Clients.TrainingJob{status: :succeeded} =
             DSEx.Clients.TrainingJob.new(%{status: "completed", result_model: "model-output"})

    assert %DSEx.Clients.TrainingJob{status: :pending} =
             DSEx.Clients.TrainingJob.new(%{status: "queued"})

    assert %DSEx.Clients.TrainingJob{status: :running} =
             DSEx.Clients.TrainingJob.new(%{status: "in_progress"})

    assert %DSEx.Clients.TrainingJob{status: {:unknown, "provider-paused"}} =
             DSEx.Clients.TrainingJob.new(%{status: "provider-paused"})

    assert DSEx.Clients.TrainingJob.normalize_status("canceled") == :cancelled

    unknown = DSEx.Clients.TrainingJob.new(%{status: "provider-paused"})

    assert DSEx.Clients.TrainingJob.load(DSEx.Clients.TrainingJob.dump(unknown)).status ==
             {:unknown, "provider-paused"}
  end

  test "training success without a provider artifact cannot be rebound or reported as success" do
    job = DSEx.Clients.TrainingJob.new(%{id: "job_no_artifact", status: "succeeded"})

    assert job.status == :artifact_missing
    assert job.metadata.error == :training_artifact_missing

    program = DSEx.predict("question -> answer", lm: DSEx.req_llm("gpt-test"))
    assert {:error, :training_artifact_missing} = DSEx.Clients.TrainingJob.rebind(job, program)

    whitespace = DSEx.Clients.TrainingJob.new(%{status: "succeeded", result_model: "  "})
    assert whitespace.status == :artifact_missing

    assert DSEx.Clients.TrainingJob.load(DSEx.Clients.TrainingJob.dump(whitespace)).status ==
             :artifact_missing

    raw_callback = fn _lm, _examples, _opts ->
      {:ok, %DSEx.Clients.TrainingJob{id: "raw", status: :succeeded, metadata: %{}}}
    end

    assert {:ok, callback_job} =
             DSEx.Clients.Trainer.finetune(
               raw_callback,
               DSEx.req_llm("gpt-test"),
               examples()
             )

    assert callback_job.status == :artifact_missing
  end

  test "OpenAI training jobs expose provider-shaped cancellation" do
    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport,
        training_file: "file-abc"
      )

    assert {:ok, job} =
             DSEx.Clients.Trainer.finetune(trainer, DSEx.req_llm("gpt-test"), examples())

    assert job.cancel_url == "https://api.example/v1/fine_tuning/jobs/ftjob_123/cancel"
    assert {:ok, cancelled} = DSEx.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled

    assert_received {:openai_training_request,
                     "https://api.example/v1/fine_tuning/jobs/ftjob_123/cancel", _headers,
                     %{"job_id" => "ftjob_123"}}

    unsupported = %{job | cancel_url: nil}
    assert {:error, :training_cancel_not_supported} = DSEx.Clients.TrainingJob.cancel(unsupported)
  end

  test "training jobs accept decoded provider-style attrs and reject malformed attrs clearly" do
    examples = [%{"question" => "2+2?", "answer" => "4"}]

    assert %DSEx.Clients.TrainingJob{
             id: "job_string_attrs",
             provider: "custom-provider",
             model: "model-a",
             status: :pending,
             training_data: ^examples,
             result_model: "model-b",
             status_url: "https://trainer.example/jobs/job_string_attrs",
             api_key: "sk-test",
             metadata: %{"source" => "decoded-json"}
           } =
             DSEx.Clients.TrainingJob.new(%{
               "id" => "job_string_attrs",
               "provider" => "custom-provider",
               "model" => "model-a",
               "status" => "queued",
               "training_data" => examples,
               "result_model" => "model-b",
               "status_url" => "https://trainer.example/jobs/job_string_attrs",
               "api_key" => "sk-test",
               "metadata" => %{"source" => "decoded-json"}
             })

    assert %DSEx.Clients.TrainingJob{status: :running} =
             DSEx.Clients.TrainingJob.new(status: "running")

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.TrainingJob\.new\/1 expects a map or keyword list/,
                 fn ->
                   DSEx.Clients.TrainingJob.new(:not_attrs)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.TrainingJob\.new\/1 expects attrs as atom or string keyed pairs/,
                 fn ->
                   DSEx.Clients.TrainingJob.new([{123, "bad"}])
                 end
  end

  test "training job inspect redacts refresh credentials without breaking refresh" do
    job =
      DSEx.Clients.TrainingJob.new(%{
        id: "job_secret",
        provider: :test,
        status_url: "https://trainer.example/jobs/job_secret",
        api_key: "sk-test-secret-1234567890",
        transport: SecretRefreshTransport
      })

    rendered = inspect(job)

    assert rendered =~ "#DSEx.Clients.TrainingJob<"
    assert rendered =~ "[REDACTED]"
    refute rendered =~ "sk-test-secret-1234567890"

    assert {:ok, refreshed} = DSEx.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test-secret-1234567890",
        training_file: "file-abc"
      )

    refute inspect(trainer) =~ "sk-test-secret-1234567890"
    assert inspect(trainer) =~ "[REDACTED]"
  end

  test "training job checkpoint is credential-free and resumes refresh explicitly" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-training-job-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    job =
      DSEx.Clients.TrainingJob.new(%{
        id: "job_secret",
        provider: :openai,
        model: "gpt-test",
        status: :running,
        training_data: [%{authorization: "Bearer abcdefghijklmnop"}],
        status_url: "https://trainer.example/jobs/job_secret",
        api_key: "sk-test-secret-1234567890",
        transport: SecretRefreshTransport,
        metadata: %{api_key: "sk-metadata-secret-1234567890"}
      })

    assert :ok = DSEx.Clients.TrainingJob.save!(job, path)
    persisted = File.read!(path)
    refute persisted =~ "sk-test-secret-1234567890"
    refute persisted =~ "sk-metadata-secret-1234567890"
    refute persisted =~ "abcdefghijklmnop"

    resumed =
      DSEx.Clients.TrainingJob.load!(path,
        transport: SecretRefreshTransport,
        api_key: "sk-test-secret-1234567890"
      )

    assert resumed.provider == :openai
    assert resumed.api_key == "sk-test-secret-1234567890"
    assert {:ok, completed} = DSEx.Clients.TrainingJob.refresh(resumed)
    assert completed.status == :succeeded
    assert completed.result_model == "model-secret-fixture"
  end

  test "generic HTTP trainer retries ambiguous submission with one stable idempotency key" do
    Process.delete({RetryTrainingTransport, "https://trainer.example/jobs"})

    trainer =
      DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: RetryTrainingTransport,
        max_attempts: 2,
        retry_backoff_ms: 0
      )

    assert {:ok, job} =
             DSEx.Clients.Trainer.finetune(
               trainer,
               DSEx.req_llm("gpt-test"),
               examples(),
               idempotency_key: "training-request-123"
             )

    assert job.idempotency_key == "training-request-123"
    assert job.metadata["submit_response"]["api_key"] == "[REDACTED]"

    assert_received {:retry_training_request, 1, first_headers, first_payload}
    assert_received {:retry_training_request, 2, second_headers, ^first_payload}
    assert {"idempotency-key", "training-request-123"} in first_headers
    assert {"idempotency-key", "training-request-123"} in second_headers
  end

  test "training jobs retry transient refresh and cancel failures idempotently" do
    status_url = "https://trainer.example/jobs/retry_lifecycle_job"
    cancel_url = status_url <> "/cancel"
    Process.delete({RetryLifecycleTransport, status_url})
    Process.delete({RetryLifecycleTransport, cancel_url})

    job =
      DSEx.Clients.TrainingJob.new(%{
        id: "retry_lifecycle_job",
        provider: :test,
        status: :running,
        status_url: status_url,
        cancel_url: cancel_url,
        transport: RetryLifecycleTransport,
        idempotency_key: "retry-lifecycle-request",
        max_attempts: 2,
        retry_backoff_ms: 0
      })

    assert {:ok, completed} = DSEx.Clients.TrainingJob.refresh(job)
    assert completed.status == :succeeded
    assert completed.result_model == "retry-lifecycle-model"

    assert_received {:retry_lifecycle_request, ^status_url, 1, first_refresh_headers}
    assert_received {:retry_lifecycle_request, ^status_url, 2, second_refresh_headers}

    assert {"idempotency-key", "retry-lifecycle-request:refresh"} in first_refresh_headers
    assert {"idempotency-key", "retry-lifecycle-request:refresh"} in second_refresh_headers

    assert {:ok, cancelled} = DSEx.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled

    assert_received {:retry_lifecycle_request, ^cancel_url, 1, first_cancel_headers}
    assert_received {:retry_lifecycle_request, ^cancel_url, 2, second_cancel_headers}
    assert {"idempotency-key", "retry-lifecycle-request:cancel"} in first_cancel_headers
    assert {"idempotency-key", "retry-lifecycle-request:cancel"} in second_cancel_headers
  end

  test "HTTP training failures redact provider secrets" do
    trainer =
      DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: SecretErrorTrainingTransport,
        max_attempts: 1
      )

    assert {:error, {:http_error, 400, body}} =
             DSEx.Clients.Trainer.finetune(trainer, DSEx.req_llm("gpt-test"), examples())

    assert body =~ "[REDACTED]"
    refute body =~ "sk-provider-error-secret"
  end

  test "OpenAI trainer requires a file id when there are no examples to upload" do
    lm = DSEx.req_llm("gpt-test")

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:error, :openai_training_file_required} =
             DSEx.Clients.Trainer.finetune(trainer, lm, [], [])

    refute_received {:openai_file_upload, _, _, _}
  end

  test "OpenAI trainer deterministically uploads examples before submitting their file id" do
    encoder = fn example ->
      %{
        messages: [
          %{role: "system", content: "Solve the example."},
          %{role: "user", content: "Question: #{DSEx.Example.get(example, :question)}"},
          %{role: "assistant", content: "Answer: #{DSEx.Example.get(example, :answer)}"}
        ]
      }
    end

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport,
        example_encoder: encoder
      )

    assert {:ok, %DSEx.Clients.TrainingJob{id: "ftjob_123"}} =
             DSEx.Clients.Trainer.finetune(
               trainer,
               DSEx.req_llm("gpt-test"),
               examples(),
               method: :sft
             )

    assert_received {:openai_file_upload, "https://api.example/v1/files", upload_headers,
                     multipart}

    assert {"authorization", "Bearer sk-test"} in upload_headers

    assert {"content-type", "multipart/form-data; boundary=" <> boundary} =
             List.keyfind(upload_headers, "content-type", 0)

    jsonl =
      ~s({"messages":[{"content":"Solve the example.","role":"system"},{"content":"Question: 2+2?","role":"user"},{"content":"Answer: 4","role":"assistant"}]}\n)

    digest = :crypto.hash(:sha256, jsonl) |> Base.encode16(case: :lower)

    assert boundary == "dsex-" <> binary_part(digest, 0, 32)
    assert multipart =~ "name=\"purpose\"\r\n\r\nfine-tune"
    assert multipart =~ "filename=\"dsex-training-#{binary_part(digest, 0, 16)}.jsonl\""
    assert multipart =~ "content-type: application/jsonl\r\n\r\n"
    assert multipart =~ jsonl
    assert multipart =~ "\r\n--#{boundary}--\r\n"

    assert_received {:openai_training_request, "https://api.example/v1/fine_tuning/jobs",
                     _headers, %{"model" => "gpt-test", "training_file" => "file-uploaded-demos"}}
  end

  test "OpenAI trainer rejects unshaped example rows before upload" do
    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:error, {:invalid_openai_training_example, 0, :messages_required}} =
             DSEx.Clients.Trainer.finetune(
               trainer,
               DSEx.req_llm("gpt-test"),
               examples(),
               method: :sft
             )

    invalid_messages =
      DSEx.example(
        messages: [
          %{role: "user", content: "Question: 2+2?"},
          %{role: "assistant", content: nil}
        ]
      )

    assert {:error, {:invalid_openai_training_example, 0, {:invalid_message_content, 1, nil}}} =
             DSEx.Clients.Trainer.finetune(
               trainer,
               DSEx.req_llm("gpt-test"),
               [invalid_messages],
               method: :sft
             )

    refute_received {:openai_file_upload, _, _, _}
    refute_received {:openai_training_request, _, _, _}
  end

  test "trainer dispatch reports callback crashes and invalid callback results" do
    lm = DSEx.req_llm("gpt-test")

    assert {:error, {:trainer_failed, :anonymous_trainer, "trainer exploded"}} =
             DSEx.Clients.Trainer.finetune(
               fn _lm, _examples, _opts -> raise "trainer exploded" end,
               lm,
               examples(),
               []
             )

    assert {:error, {:invalid_trainer_result, :not_a_job}} =
             DSEx.Clients.Trainer.finetune(
               fn _lm, _examples, _opts -> {:ok, :not_a_job} end,
               lm,
               examples(),
               []
             )

    assert {:error, {:not_a_trainer, String}} =
             DSEx.Clients.Trainer.finetune(String, lm, examples(), [])
  end

  test "trainer dispatch validates call inputs before provider callbacks run" do
    lm = DSEx.req_llm("gpt-test")

    callback = fn _lm, _examples, _opts ->
      send(self(), :trainer_callback_ran)
      {:ok, DSEx.Clients.TrainingJob.new(%{provider: :test})}
    end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.Trainer\.finetune\/4 expects keyword options/,
                 fn ->
                   DSEx.Clients.Trainer.finetune(callback, lm, examples(), %{method: :sft})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.Trainer\.finetune\/4 expects a list of examples/,
                 fn ->
                   DSEx.Clients.Trainer.finetune(callback, lm, %{question: "2+2?"}, [])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.Trainer\.finetune\/4 expects examples as DSEx\.Example structs/,
                 fn ->
                   DSEx.Clients.Trainer.finetune(callback, lm, [%{question: "2+2?"}], [])
                 end

    refute_received :trainer_callback_ran
  end

  test "HTTP trainer reports payload transport decode and mapper failures" do
    lm = DSEx.req_llm("gpt-test")

    payload_trainer =
      DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        payload_builder: fn _lm, _examples, _opts -> raise "payload exploded" end
      )

    assert {:error, {:invalid_training_payload, "payload exploded"}} =
             DSEx.Clients.Trainer.finetune(payload_trainer, lm, examples(), [])

    transport_trainer =
      DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: RaisingTrainingTransport
      )

    assert {:error, {:training_transport_failed, "transport exploded"}} =
             DSEx.Clients.Trainer.finetune(transport_trainer, lm, examples(), [])

    invalid_json_trainer =
      DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: InvalidJSONTrainingTransport
      )

    assert {:error, {:invalid_training_response, reason}} =
             DSEx.Clients.Trainer.finetune(invalid_json_trainer, lm, examples(), [])

    assert reason =~ "unexpected byte"

    mapper_trainer =
      DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: DatabricksTrainingTransport,
        response_mapper: fn _trainer, _lm, _examples, _decoded -> raise "mapper exploded" end
      )

    assert {:error, {:invalid_training_job, "mapper exploded"}} =
             DSEx.Clients.Trainer.finetune(mapper_trainer, lm, examples(), [])

    missing_id_trainer =
      DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: MissingJobIdTrainingTransport
      )

    assert {:error, :training_job_id_missing} =
             DSEx.Clients.Trainer.finetune(missing_id_trainer, lm, examples(), [])
  end

  test "HTTP trainer validates direct call inputs before transport work starts" do
    lm = DSEx.req_llm("gpt-test")
    trainer = DSEx.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs")

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.HTTPTrainer\.finetune\/4 expects keyword options/,
                 fn ->
                   DSEx.Clients.HTTPTrainer.finetune(trainer, lm, examples(), %{method: :sft})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.HTTPTrainer\.finetune\/4 expects a list of examples/,
                 fn ->
                   DSEx.Clients.HTTPTrainer.finetune(trainer, lm, %{question: "2+2?"}, [])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.HTTPTrainer\.finetune\/4 expects examples as DSEx\.Example structs/,
                 fn ->
                   DSEx.Clients.HTTPTrainer.finetune(trainer, lm, [%{question: "2+2?"}], [])
                 end
  end

  test "training job refresh reports transport decode and shape failures" do
    base =
      DSEx.Clients.TrainingJob.new(%{
        id: "job_1",
        provider: :test,
        status_url: "https://trainer.example/jobs/job_1"
      })

    raising = %{base | transport: RaisingTrainingTransport}

    assert {:error, {:training_refresh_failed, "transport exploded"}} =
             DSEx.Clients.TrainingJob.refresh(raising)

    invalid_json = %{base | transport: InvalidJSONTrainingTransport}

    assert {:error, {:invalid_training_refresh_response, reason}} =
             DSEx.Clients.TrainingJob.refresh(invalid_json)

    assert reason =~ "unexpected byte"

    invalid_shape = %{base | transport: InvalidShapeTrainingTransport}

    assert {:error, {:invalid_training_refresh_response, :not_an_http_response}} =
             DSEx.Clients.TrainingJob.refresh(invalid_shape)
  end

  test "OpenAI trainer custom base URL does not bind ambient API key implicitly" do
    previous = System.get_env("OPENAI_API_KEY")
    Process.put(:previous_training_openai_api_key, previous)
    System.put_env("OPENAI_API_KEY", "sk-should-not-bind")

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://evil.example/v1",
        transport: OpenAITrainingTransport,
        training_file: "file-abc"
      )

    assert trainer.api_key == nil
  after
    previous = Process.get(:previous_training_openai_api_key)

    if previous do
      System.put_env("OPENAI_API_KEY", previous)
    else
      System.delete_env("OPENAI_API_KEY")
    end

    Process.delete(:previous_training_openai_api_key)
  end

  test "Databricks trainer executes submit refresh cancel and artifact lifecycle" do
    lm = DSEx.req_llm("databricks-meta-llama")

    trainer =
      DSEx.Clients.DatabricksTrainer.new(
        base_url: "https://dbc.example",
        api_key: "dbc-token",
        transport: DatabricksTrainingTransport
      )

    assert {:ok, job} =
             DSEx.Clients.Trainer.finetune(trainer, lm, examples(),
               method: :grpo,
               learning_rate: 1.0e-5
             )

    assert %DSEx.Clients.TrainingJob{id: "dbx_1", provider: :databricks, status: :pending} =
             job

    assert_received {:databricks_training_request, "https://dbc.example/api/2.0/dsex/finetune",
                     headers, payload}

    assert {"authorization", "Bearer dbc-token"} in headers
    assert payload["base_model"] == "databricks-meta-llama"
    assert payload["task_type"] == "grpo"
    assert payload["config"] == %{"learning_rate" => 1.0e-5}
    assert [%{"question" => "2+2?", "answer" => "4"}] = payload["train_data"]

    assert {:ok, refreshed} = DSEx.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "dbx-model-output"

    program = DSEx.predict("question -> answer", lm: lm)
    assert {:ok, rebound} = DSEx.Clients.TrainingJob.rebind(refreshed, program)
    assert DSEx.ProgramAccess.lm(rebound).model == "dbx-model-output"

    assert {:ok, cancelled} = DSEx.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled
  end

  test "BootstrapFinetune accepts provider trainer structs" do
    lm = %{
      module: DSEx.LM.Static,
      model: "gpt-test",
      opts: [handler: fn _messages, _opts -> %{answer: "4"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)
    metric = DSEx.Metrics.exact_match(:answer)

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    result =
      metric
      |> DSEx.Optimizer.BootstrapFinetune.new(trainer: trainer, max_demos: 1)
      |> DSEx.Optimizer.BootstrapFinetune.compile(program, examples())

    assert %{
             program: %DSEx.Predict.Predict{},
             job: %DSEx.Clients.TrainingJob{provider: :openai}
           } =
             result

    assert_received {:openai_file_upload, "https://api.example/v1/files", headers, multipart}

    assert {"content-type", "multipart/form-data; boundary=" <> boundary} =
             List.keyfind(headers, "content-type", 0)

    [_, file_part] =
      String.split(multipart, "content-type: application/jsonl\r\n\r\n", parts: 2)

    [jsonl, _closing_boundary] =
      String.split(file_part, "\r\n--#{boundary}--\r\n", parts: 2)

    assert [row] = jsonl |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert row == %{
             "messages" => [
               %{
                 "role" => "system",
                 "content" =>
                   "Your input fields are:\n1. `question` (str):\nYour output fields are:\n1. `answer` (str):\nAll interactions will be structured in the following way, with the appropriate values filled in.\n\n[[ ## question ## ]]\n{question}\n\n[[ ## answer ## ]]\n{answer}\n\n[[ ## completed ## ]]\nIn adhering to this structure, your objective is: \n        Given the fields `question`, produce the fields `answer`."
               },
               %{"role" => "user", "content" => "[[ ## question ## ]]\n2+2?"},
               %{"role" => "assistant", "content" => "[[ ## answer ## ]]\n4"}
             ]
           }

    assert_received {:openai_training_request, "https://api.example/v1/fine_tuning/jobs",
                     _headers, %{"training_file" => "file-uploaded-demos"}}
  end

  test "training optimizer constructors reject invalid boundary contracts" do
    metric = DSEx.Metrics.exact_match(:answer)
    callback = fn _lm, _examples, _opts -> {:ok, DSEx.Clients.TrainingJob.new(%{})} end

    assert {:ok, nil} = DSEx.Clients.Trainer.validate_provider(nil)
    assert {:ok, String} = DSEx.Clients.Trainer.validate_provider(String)
    assert {:ok, ^callback} = DSEx.Clients.Trainer.validate_provider(callback)

    assert {:ok, %DSEx.Clients.HTTPTrainer{}} =
             DSEx.Clients.Trainer.validate_provider(%DSEx.Clients.HTTPTrainer{})

    assert {:error, message} = DSEx.Clients.Trainer.validate_provider(%{not: :a_trainer})

    assert message =~
             "expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback"

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BootstrapFinetune\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.BootstrapFinetune.new(metric, %{max_demos: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BootstrapFinetune\.new\/2 expects a metric function with arity 2/,
                 fn ->
                   DSEx.Optimizer.BootstrapFinetune.new(fn _example, _prediction, _trace ->
                     true
                   end)
                 end

    assert_raise ArgumentError, ~r/DSEx\.Optimizer\.GRPO\.new\/2: expected keyword options/, fn ->
      DSEx.Optimizer.GRPO.new(fn _example -> 1.0 end, %{trainer: nil})
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BootstrapFinetune\.new\/2: invalid value for :trainer option: expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback/,
                 fn ->
                   DSEx.Optimizer.BootstrapFinetune.new(metric, trainer: %{not: :a_trainer})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.GRPO\.new\/2: invalid value for :trainer option: expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback/,
                 fn ->
                   DSEx.Optimizer.GRPO.new(fn _example -> 1.0 end,
                     trainer: fn _lm, _examples -> {:ok, :bad} end
                   )
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.GRPO\.new\/2 expects a reward function with arity 1/,
                 fn ->
                   DSEx.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end)
                 end
  end

  test "BootstrapFinetune treats zero max_demos as no provider demos and rejects negative counts" do
    lm = DSEx.req_llm("gpt-test")
    program = DSEx.predict("question -> answer", lm: lm)
    metric = DSEx.Metrics.exact_match(:answer)

    trainer = fn _lm, demos, _opts ->
      send(self(), {:finetune_demos, demos})
      {:ok, DSEx.Clients.TrainingJob.new(%{id: "job_0", provider: :test, status: :queued})}
    end

    result =
      metric
      |> DSEx.Optimizer.BootstrapFinetune.new(trainer: trainer, max_demos: 0)
      |> DSEx.Optimizer.BootstrapFinetune.compile(program, examples())

    assert %{program: %DSEx.Predict.Predict{}, job: %DSEx.Clients.TrainingJob{}} = result
    assert_received {:finetune_demos, []}

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BootstrapFinetune\.new\/2: invalid value for :max_demos option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.BootstrapFinetune.new(metric, max_demos: -1)
                 end
  end

  test "BootstrapFinetune extracts demos and LM through composed program wrappers" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2"} end]
    }

    retriever = DSEx.Retrieve.Memory.new([%{text: "multiplication by two"}], k: 1)

    program =
      "x, context -> doubled"
      |> DSEx.program_of_thought(lm: lm, output_field: :doubled)
      |> DSEx.rag(retriever, query_field: :x, k: 1)

    trainset = [
      DSEx.example(x: 21, doubled: 42) |> DSEx.with_inputs(:x)
    ]

    metric = DSEx.Metrics.exact_match(:doubled)

    trainer = fn trainer_lm, demos, opts ->
      send(self(), {:bootstrap_finetune, trainer_lm, demos, opts})
      {:ok, DSEx.Clients.TrainingJob.new(%{id: "job_wrapped", provider: :test})}
    end

    result =
      metric
      |> DSEx.Optimizer.BootstrapFinetune.new(trainer: trainer, max_demos: 1)
      |> DSEx.Optimizer.BootstrapFinetune.compile(program, trainset)

    assert %{
             program: %DSEx.Predict.RAG{
               program: %DSEx.Predict.ProgramOfThought{predict: %{demos: [demo]}}
             },
             job: %DSEx.Clients.TrainingJob{id: "job_wrapped"}
           } = result

    assert DSEx.Example.get(demo, :doubled) == 42
    assert_received {:bootstrap_finetune, ^lm, [^demo], [method: :sft]}
  end

  test "GRPO extracts the provider LM through CodeAct and ProgramOfThought wrappers" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "42"} end]
    }

    program = DSEx.code_act("question -> answer", [], lm: lm)
    trainset = [DSEx.example(question: "life?", answer: "42") |> DSEx.with_inputs(:question)]

    trainer = %GRPOTrainingFixture{}

    assert {:ok, %DSEx.Clients.TrainingJob{id: "job_grpo"}} =
             DSEx.Optimizer.GRPO.new(fn _example -> 0.75 end, trainer: trainer)
             |> DSEx.Optimizer.GRPO.compile(program, trainset)

    assert_received {:grpo_finetune, ^lm, [enriched], [method: :grpo]}
    assert DSEx.Example.get(enriched, :reward) == 0.75
  end

  test "an explicit GRPO-only trainer rejects SFT before trainer dispatch" do
    trainer = %GRPOTrainingFixture{}

    assert {:error, {:unsupported_training_method, :sft}} =
             DSEx.Clients.Trainer.finetune(
               trainer,
               DSEx.req_llm("gpt-test"),
               examples(),
               method: :sft
             )

    refute_received {:grpo_finetune, _, _, _}
  end

  test "GRPO rejects OpenAI before reward evaluation or network submission" do
    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    reward_fn = fn _example ->
      send(self(), :grpo_reward_evaluated)
      1.0
    end

    assert {:error, {:unsupported_training_method, :grpo}} =
             DSEx.Optimizer.GRPO.new(reward_fn, trainer: trainer)
             |> DSEx.Optimizer.GRPO.compile(
               DSEx.predict("question -> answer", lm: DSEx.req_llm("gpt-test")),
               examples()
             )

    assert {:error, {:unsupported_training_method, :grpo}} =
             DSEx.Clients.HTTPTrainer.finetune(
               trainer,
               DSEx.req_llm("gpt-test"),
               examples(),
               method: :grpo
             )

    refute_received :grpo_reward_evaluated
    refute_received {:openai_file_upload, _, _, _}
    refute_received {:openai_training_request, _, _, _}
  end
end

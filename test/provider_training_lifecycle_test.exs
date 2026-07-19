defmodule ProviderTrainingLifecycleTest do
  use ExUnit.Case

  test "training statuses distinguish known active, terminal, and unknown states" do
    assert Imp.Clients.TrainingJob.normalize_status("validating_files") == :pending
    assert Imp.Clients.TrainingJob.active_status?("validating_files")
    assert Imp.Clients.TrainingJob.active_status?(:queued)
    assert Imp.Clients.TrainingJob.terminal_status?("cancelled")
    assert Imp.Clients.TrainingJob.terminal_status?(:artifact_missing)
    refute Imp.Clients.TrainingJob.active_status?({:unknown, "provider-paused"})
    refute Imp.Clients.TrainingJob.terminal_status?({:unknown, "provider-paused"})
  end

  defmodule OpenAITrainingTransport do
    @behaviour Imp.HTTP

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
        decoded = if IO.iodata_to_binary(body) == "", do: %{}, else: Jason.decode!(body)
        send(self(), {:openai_training_request, url, headers, decoded})

        response(url, decoded)
      end
    end

    @impl true
    def request(:post, url, headers, body, opts), do: post(url, headers, body, opts)

    def request(:get, url, headers, body, _opts) do
      assert IO.iodata_to_binary(body) == ""
      send(self(), {:openai_training_request, url, headers, :empty})
      response(url, %{})
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
    @behaviour Imp.Clients.Trainer

    defstruct [:owner]

    @impl true
    def supported_methods(%__MODULE__{}), do: [:grpo]

    @impl true
    def start_reinforcement(%__MODULE__{owner: owner}, trainer_lm, opts) do
      send(owner, {:grpo_started, trainer_lm, opts})

      {:ok,
       Imp.Clients.ReinforcementSession.new(%{
         id: "job_grpo",
         provider: :test,
         model: trainer_lm,
         pending_batch_ids: [1]
       })}
    end

    @impl true
    def reinforcement_status(%__MODULE__{}, session), do: {:ok, session}

    @impl true
    def reinforcement_step(%__MODULE__{owner: owner}, session, groups, _opts) do
      send(owner, {:grpo_step, groups})
      {:ok, session}
    end

    @impl true
    def terminate_reinforcement(%__MODULE__{owner: owner}, session) do
      send(owner, :grpo_terminated)
      {:ok, %{session | status: :succeeded}}
    end

    @impl true
    def final_model_artifact(%__MODULE__{}, _session) do
      {:ok, "grpo-model"}
    end
  end

  defmodule DatabricksTrainingTransport do
    @behaviour Imp.HTTP

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
    @behaviour Imp.HTTP

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
    @behaviour Imp.HTTP

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
    @behaviour Imp.HTTP

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
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: raise("transport exploded")
  end

  defmodule InvalidJSONTrainingTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      {:ok, %{status: 200, headers: [], body: "not json"}}
    end
  end

  defmodule InvalidShapeTrainingTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: :not_an_http_response
  end

  defmodule MissingJobIdTrainingTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "running"})}}
    end
  end

  defmodule SecretRefreshTransport do
    @behaviour Imp.HTTP

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
      Imp.example(question: "2+2?", answer: "4") |> Imp.Example.with_inputs(:question)
    ]
  end

  test "OpenAI trainer submits job and refreshes lifecycle status" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :training, :submit, :start],
        [:imp, :training, :refresh, :start]
      ])

    lm = Imp.req_llm("openai:gpt-test")

    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:ok, job} =
             Imp.Clients.Trainer.finetune(trainer, lm, examples(),
               training_file: "file-abc",
               hyperparameters: [n_epochs: 1]
             )

    assert %Imp.Clients.TrainingJob{id: "ftjob_123", provider: :openai, status: :running} =
             job

    assert_received {:openai_training_request, "https://api.example/v1/fine_tuning/jobs", headers,
                     payload}

    assert {"authorization", "Bearer sk-test"} in headers
    assert payload["model"] == "gpt-test"
    assert payload["training_file"] == "file-abc"

    assert payload["method"] == %{
             "type" => "supervised",
             "supervised" => %{"hyperparameters" => %{"n_epochs" => 1}}
           }

    refute Map.has_key?(payload, "hyperparameters")
    refute Map.has_key?(payload, "imp_training_data")

    assert {:ok, refreshed} = Imp.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "ft:gpt-test:org:abc"

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-trained-program-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = Imp.predict("question -> answer", lm: lm)

    assert {:ok, rebound} =
             Imp.Clients.TrainingJob.rebind(refreshed, program, path: path)

    assert %Imp.Clients.ReqLLM{model: "openai:ft:gpt-test:org:abc"} =
             Imp.ProgramAccess.lm(rebound)

    assert Imp.ProgramAccess.get_metadata(rebound, :training_artifact) == %{
             provider: :openai,
             job_id: "ftjob_123",
             base_model: "openai:gpt-test",
             result_model: "ft:gpt-test:org:abc"
           }

    loaded = Imp.load!(path)

    assert %Imp.Clients.ReqLLM{model: "openai:ft:gpt-test:org:abc"} =
             Imp.ProgramAccess.lm(loaded)

    assert_received {^ref, [:imp, :training, :submit, :start], _, %{provider: :openai}}
    assert_received {^ref, [:imp, :training, :refresh, :start], _, %{job_id: "ftjob_123"}}
  end

  test "training jobs normalize provider lifecycle status at construction and refresh" do
    assert %Imp.Clients.TrainingJob{status: :succeeded} =
             Imp.Clients.TrainingJob.new(%{status: "completed", result_model: "model-output"})

    assert %Imp.Clients.TrainingJob{status: :pending} =
             Imp.Clients.TrainingJob.new(%{status: "queued"})

    assert %Imp.Clients.TrainingJob{status: :running} =
             Imp.Clients.TrainingJob.new(%{status: "in_progress"})

    assert %Imp.Clients.TrainingJob{status: :succeeded} =
             Imp.Clients.TrainingJob.new(%{status: :completed, result_model: "atom-model"})

    assert %Imp.Clients.TrainingJob{status: :pending} =
             Imp.Clients.TrainingJob.new(%{status: :queued})

    assert %Imp.Clients.TrainingJob{status: :running} =
             Imp.Clients.TrainingJob.new(%{status: :in_progress})

    assert %Imp.Clients.TrainingJob{status: {:unknown, "provider-paused"}} =
             Imp.Clients.TrainingJob.new(%{status: "provider-paused"})

    assert Imp.Clients.TrainingJob.normalize_status("canceled") == :cancelled
    assert Imp.Clients.TrainingJob.normalize_status(:canceled) == :cancelled

    unknown = Imp.Clients.TrainingJob.new(%{status: "provider-paused"})

    assert Imp.Clients.TrainingJob.load(Imp.Clients.TrainingJob.dump(unknown)).status ==
             {:unknown, "provider-paused"}
  end

  test "rebind accepts an explicit portable deployment LM distinct from the artifact" do
    base_lm = Imp.req_llm("openai:gpt-base", api_key: "secret")

    deployment_lm =
      Imp.req_llm("openai:local-fused-model",
        api_key: "local",
        base_url: "http://127.0.0.1:8189/v1"
      )

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "local-job",
        provider: :mlx_lm,
        model: "qwen-base",
        status: :succeeded,
        result_model: "/artifacts/adapters"
      })

    program = Imp.predict("question -> answer", lm: base_lm)

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-local-trained-program-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, rebound} =
             Imp.Clients.TrainingJob.rebind(job, program, lm: deployment_lm, path: path)

    assert Imp.ProgramAccess.lm(rebound) == deployment_lm

    assert Imp.ProgramAccess.get_metadata(rebound, :training_artifact) == %{
             provider: :mlx_lm,
             job_id: "local-job",
             base_model: "qwen-base",
             result_model: "/artifacts/adapters"
           }

    assert {:error, {:invalid_training_deployment_lm, _message}} =
             Imp.Clients.TrainingJob.rebind(job, program, lm: %{not: :an_lm})

    assert %Imp.Clients.ReqLLM{
             model: "openai:local-fused-model",
             opts: [base_url: "http://127.0.0.1:8189/v1"]
           } =
             Imp.load!(path)
             |> Imp.ProgramAccess.lm()
  end

  test "training success without a provider artifact cannot be rebound or reported as success" do
    job = Imp.Clients.TrainingJob.new(%{id: "job_no_artifact", status: "succeeded"})

    assert job.status == :artifact_missing
    assert job.metadata.error == :training_artifact_missing

    program = Imp.predict("question -> answer", lm: Imp.req_llm("gpt-test"))
    assert {:error, :training_artifact_missing} = Imp.Clients.TrainingJob.rebind(job, program)

    whitespace = Imp.Clients.TrainingJob.new(%{status: "succeeded", result_model: "  "})
    assert whitespace.status == :artifact_missing

    assert Imp.Clients.TrainingJob.load(Imp.Clients.TrainingJob.dump(whitespace)).status ==
             :artifact_missing

    raw_callback = fn _lm, _examples, _opts ->
      {:ok, %Imp.Clients.TrainingJob{id: "raw", status: :succeeded, metadata: %{}}}
    end

    assert {:ok, callback_job} =
             Imp.Clients.Trainer.finetune(
               raw_callback,
               Imp.req_llm("gpt-test"),
               examples()
             )

    assert callback_job.status == :artifact_missing
  end

  test "OpenAI training jobs expose provider-shaped cancellation" do
    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport,
        training_file: "file-abc"
      )

    assert {:ok, job} =
             Imp.Clients.Trainer.finetune(trainer, Imp.req_llm("gpt-test"), examples())

    assert job.cancel_url == "https://api.example/v1/fine_tuning/jobs/ftjob_123/cancel"
    assert {:ok, cancelled} = Imp.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled

    assert_received {:openai_training_request,
                     "https://api.example/v1/fine_tuning/jobs/ftjob_123/cancel", _headers, %{}}

    unsupported = %{job | cancel_url: nil}
    assert {:error, :training_cancel_not_supported} = Imp.Clients.TrainingJob.cancel(unsupported)
  end

  test "a successful cancellation request is incomplete until the provider reports cancelled" do
    statuses = [
      {"running", :running},
      {"queued", :pending},
      {"validating", {:unknown, "validating"}}
    ]

    Enum.each(statuses, fn {provider_status, expected_status} ->
      transport = fn _url, _headers, _body, _opts ->
        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{status: provider_status, request_accepted: true})
         }}
      end

      job =
        Imp.Clients.TrainingJob.new(%{
          id: "cancel-#{provider_status}",
          status: :running,
          transport: transport,
          cancel_url: "https://training.example/jobs/#{provider_status}/cancel",
          cancel_body: :empty,
          max_attempts: 1
        })

      assert {:error,
              {:training_cancel_incomplete, ^expected_status,
               %{"last_status_response" => response}}} =
               Imp.Clients.TrainingJob.cancel(job)

      assert response["status"] == provider_status
      assert response["request_accepted"]
    end)
  end

  test "training jobs accept decoded provider-style attrs and reject malformed attrs clearly" do
    examples = [%{"question" => "2+2?", "answer" => "4"}]

    assert %Imp.Clients.TrainingJob{
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
             Imp.Clients.TrainingJob.new(%{
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

    assert %Imp.Clients.TrainingJob{status: :running} =
             Imp.Clients.TrainingJob.new(status: "running")

    assert_raise ArgumentError,
                 ~r/Imp.Clients.TrainingJob\.new\/1 expects a map or keyword list/,
                 fn ->
                   Imp.Clients.TrainingJob.new(:not_attrs)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.TrainingJob\.new\/1 expects attrs as atom or string keyed pairs/,
                 fn ->
                   Imp.Clients.TrainingJob.new([{123, "bad"}])
                 end
  end

  test "training job inspect redacts refresh credentials without breaking refresh" do
    job =
      Imp.Clients.TrainingJob.new(%{
        id: "job_secret",
        provider: :test,
        status_url: "https://trainer.example/jobs/job_secret",
        api_key: "sk-test-secret-1234567890",
        transport: SecretRefreshTransport
      })

    rendered = inspect(job)

    assert rendered =~ "#Imp.Clients.TrainingJob<"
    assert rendered =~ "[REDACTED]"
    refute rendered =~ "sk-test-secret-1234567890"

    assert {:ok, refreshed} = Imp.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded

    trainer =
      Imp.Clients.OpenAITrainer.new(
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
        "imp-training-job-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    job =
      Imp.Clients.TrainingJob.new(%{
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

    assert :ok = Imp.Clients.TrainingJob.save!(job, path)
    persisted = File.read!(path)
    refute persisted =~ "sk-test-secret-1234567890"
    refute persisted =~ "sk-metadata-secret-1234567890"
    refute persisted =~ "abcdefghijklmnop"

    resumed =
      Imp.Clients.TrainingJob.load!(path,
        transport: SecretRefreshTransport,
        api_key: "sk-test-secret-1234567890"
      )

    assert resumed.provider == :openai
    assert resumed.api_key == "sk-test-secret-1234567890"
    assert {:ok, completed} = Imp.Clients.TrainingJob.refresh(resumed)
    assert completed.status == :succeeded
    assert completed.result_model == "model-secret-fixture"
  end

  test "generic HTTP trainer retries ambiguous submission with one stable idempotency key" do
    Process.delete({RetryTrainingTransport, "https://trainer.example/jobs"})

    trainer =
      Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: RetryTrainingTransport,
        max_attempts: 2,
        retry_backoff_ms: 0
      )

    assert {:ok, job} =
             Imp.Clients.Trainer.finetune(
               trainer,
               Imp.req_llm("gpt-test"),
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
      Imp.Clients.TrainingJob.new(%{
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

    assert {:ok, completed} = Imp.Clients.TrainingJob.refresh(job)
    assert completed.status == :succeeded
    assert completed.result_model == "retry-lifecycle-model"

    assert_received {:retry_lifecycle_request, ^status_url, 1, first_refresh_headers}
    assert_received {:retry_lifecycle_request, ^status_url, 2, second_refresh_headers}

    assert {"idempotency-key", "retry-lifecycle-request:refresh"} in first_refresh_headers
    assert {"idempotency-key", "retry-lifecycle-request:refresh"} in second_refresh_headers

    assert {:ok, cancelled} = Imp.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled

    assert_received {:retry_lifecycle_request, ^cancel_url, 1, first_cancel_headers}
    assert_received {:retry_lifecycle_request, ^cancel_url, 2, second_cancel_headers}
    assert {"idempotency-key", "retry-lifecycle-request:cancel"} in first_cancel_headers
    assert {"idempotency-key", "retry-lifecycle-request:cancel"} in second_cancel_headers
  end

  test "HTTP training failures redact provider secrets" do
    trainer =
      Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: SecretErrorTrainingTransport,
        max_attempts: 1
      )

    assert {:error, {:http_error, 400, body}} =
             Imp.Clients.Trainer.finetune(trainer, Imp.req_llm("gpt-test"), examples())

    assert body =~ "[REDACTED]"
    refute body =~ "sk-provider-error-secret"
  end

  test "OpenAI trainer requires a file id when there are no examples to upload" do
    lm = Imp.req_llm("gpt-test")

    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:error, :openai_training_file_required} =
             Imp.Clients.Trainer.finetune(trainer, lm, [], [])

    refute_received {:openai_file_upload, _, _, _}
  end

  test "OpenAI trainer deterministically uploads examples before submitting their file id" do
    encoder = fn example ->
      %{
        messages: [
          %{role: "system", content: "Solve the example."},
          %{role: "user", content: "Question: #{Imp.Example.get(example, :question)}"},
          %{role: "assistant", content: "Answer: #{Imp.Example.get(example, :answer)}"}
        ]
      }
    end

    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport,
        example_encoder: encoder
      )

    assert {:ok, %Imp.Clients.TrainingJob{id: "ftjob_123"}} =
             Imp.Clients.Trainer.finetune(
               trainer,
               Imp.req_llm("gpt-test"),
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

    assert boundary == "imp-" <> binary_part(digest, 0, 32)
    assert multipart =~ "name=\"purpose\"\r\n\r\nfine-tune"
    assert multipart =~ "filename=\"imp-training-#{binary_part(digest, 0, 16)}.jsonl\""
    assert multipart =~ "content-type: application/jsonl\r\n\r\n"
    assert multipart =~ jsonl
    assert multipart =~ "\r\n--#{boundary}--\r\n"

    assert_received {:openai_training_request, "https://api.example/v1/fine_tuning/jobs",
                     _headers, %{"model" => "gpt-test", "training_file" => "file-uploaded-demos"}}
  end

  test "OpenAI trainer rejects unshaped example rows before upload" do
    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:error, {:invalid_openai_training_example, 0, :messages_required}} =
             Imp.Clients.Trainer.finetune(
               trainer,
               Imp.req_llm("gpt-test"),
               examples(),
               method: :sft
             )

    invalid_messages =
      Imp.example(
        messages: [
          %{role: "user", content: "Question: 2+2?"},
          %{role: "assistant", content: nil}
        ]
      )

    assert {:error, {:invalid_openai_training_example, 0, {:invalid_message_content, 1, nil}}} =
             Imp.Clients.Trainer.finetune(
               trainer,
               Imp.req_llm("gpt-test"),
               [invalid_messages],
               method: :sft
             )

    refute_received {:openai_file_upload, _, _, _}
    refute_received {:openai_training_request, _, _, _}
  end

  test "trainer dispatch reports callback crashes and invalid callback results" do
    lm = Imp.req_llm("gpt-test")

    assert {:error, {:trainer_failed, :anonymous_trainer, "trainer exploded"}} =
             Imp.Clients.Trainer.finetune(
               fn _lm, _examples, _opts -> raise "trainer exploded" end,
               lm,
               examples(),
               []
             )

    assert {:error, {:invalid_trainer_result, :not_a_job}} =
             Imp.Clients.Trainer.finetune(
               fn _lm, _examples, _opts -> {:ok, :not_a_job} end,
               lm,
               examples(),
               []
             )

    assert {:error, {:not_a_trainer, String}} =
             Imp.Clients.Trainer.finetune(String, lm, examples(), [])
  end

  test "trainer dispatch validates call inputs before provider callbacks run" do
    lm = Imp.req_llm("gpt-test")

    callback = fn _lm, _examples, _opts ->
      send(self(), :trainer_callback_ran)
      {:ok, Imp.Clients.TrainingJob.new(%{provider: :test})}
    end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.Trainer\.finetune\/4 expects keyword options/,
                 fn ->
                   Imp.Clients.Trainer.finetune(callback, lm, examples(), %{method: :sft})
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.Trainer\.finetune\/4 expects a list of examples/,
                 fn ->
                   Imp.Clients.Trainer.finetune(callback, lm, %{question: "2+2?"}, [])
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.Trainer\.finetune\/4 expects examples as Imp\.Example structs/,
                 fn ->
                   Imp.Clients.Trainer.finetune(callback, lm, [%{question: "2+2?"}], [])
                 end

    refute_received :trainer_callback_ran
  end

  test "HTTP trainer reports payload transport decode and mapper failures" do
    lm = Imp.req_llm("gpt-test")

    payload_trainer =
      Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        payload_builder: fn _lm, _examples, _opts -> raise "payload exploded" end
      )

    assert {:error, {:invalid_training_payload, "payload exploded"}} =
             Imp.Clients.Trainer.finetune(payload_trainer, lm, examples(), [])

    transport_trainer =
      Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: RaisingTrainingTransport
      )

    assert {:error, {:training_transport_failed, "transport exploded"}} =
             Imp.Clients.Trainer.finetune(transport_trainer, lm, examples(), [])

    invalid_json_trainer =
      Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: InvalidJSONTrainingTransport
      )

    assert {:error, {:invalid_training_response, reason}} =
             Imp.Clients.Trainer.finetune(invalid_json_trainer, lm, examples(), [])

    assert reason =~ "unexpected byte"

    mapper_trainer =
      Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: DatabricksTrainingTransport,
        response_mapper: fn _trainer, _lm, _examples, _decoded -> raise "mapper exploded" end
      )

    assert {:error, {:invalid_training_job, "mapper exploded"}} =
             Imp.Clients.Trainer.finetune(mapper_trainer, lm, examples(), [])

    missing_id_trainer =
      Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs",
        transport: MissingJobIdTrainingTransport
      )

    assert {:error, :training_job_id_missing} =
             Imp.Clients.Trainer.finetune(missing_id_trainer, lm, examples(), [])
  end

  test "HTTP trainer validates direct call inputs before transport work starts" do
    lm = Imp.req_llm("gpt-test")
    trainer = Imp.Clients.HTTPTrainer.new(:test, "https://trainer.example/jobs")

    assert_raise ArgumentError,
                 ~r/Imp.Clients.HTTPTrainer\.finetune\/4 expects keyword options/,
                 fn ->
                   Imp.Clients.HTTPTrainer.finetune(trainer, lm, examples(), %{method: :sft})
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.HTTPTrainer\.finetune\/4 expects a list of examples/,
                 fn ->
                   Imp.Clients.HTTPTrainer.finetune(trainer, lm, %{question: "2+2?"}, [])
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.HTTPTrainer\.finetune\/4 expects examples as Imp\.Example structs/,
                 fn ->
                   Imp.Clients.HTTPTrainer.finetune(trainer, lm, [%{question: "2+2?"}], [])
                 end
  end

  test "training job refresh reports transport decode and shape failures" do
    base =
      Imp.Clients.TrainingJob.new(%{
        id: "job_1",
        provider: :test,
        status_url: "https://trainer.example/jobs/job_1"
      })

    raising = %{base | transport: RaisingTrainingTransport}

    assert {:error, {:training_refresh_failed, "transport exploded"}} =
             Imp.Clients.TrainingJob.refresh(raising)

    invalid_json = %{base | transport: InvalidJSONTrainingTransport}

    assert {:error, {:invalid_training_refresh_response, reason}} =
             Imp.Clients.TrainingJob.refresh(invalid_json)

    assert reason =~ "unexpected byte"

    invalid_shape = %{base | transport: InvalidShapeTrainingTransport}

    assert {:error, {:invalid_training_refresh_response, :not_an_http_response}} =
             Imp.Clients.TrainingJob.refresh(invalid_shape)
  end

  test "OpenAI trainer custom base URL does not bind ambient API key implicitly" do
    previous = System.get_env("OPENAI_API_KEY")
    Process.put(:previous_training_openai_api_key, previous)
    System.put_env("OPENAI_API_KEY", "sk-should-not-bind")

    trainer =
      Imp.Clients.OpenAITrainer.new(
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

  test "Databricks trainer executes SFT submit refresh cancel and artifact lifecycle" do
    lm = Imp.req_llm("databricks-meta-llama")

    trainer =
      Imp.Clients.DatabricksTrainer.new(
        base_url: "https://dbc.example",
        api_key: "dbc-token",
        transport: DatabricksTrainingTransport
      )

    assert {:ok, job} =
             Imp.Clients.Trainer.finetune(trainer, lm, examples(), learning_rate: 1.0e-5)

    assert %Imp.Clients.TrainingJob{id: "dbx_1", provider: :databricks, status: :pending} =
             job

    assert_received {:databricks_training_request, "https://dbc.example/api/2.0/imp/finetune",
                     headers, payload}

    assert {"authorization", "Bearer dbc-token"} in headers
    assert payload["base_model"] == "databricks-meta-llama"
    assert payload["task_type"] == "sft"
    assert payload["config"] == %{"learning_rate" => 1.0e-5}
    assert [%{"question" => "2+2?", "answer" => "4"}] = payload["train_data"]

    assert {:ok, refreshed} = Imp.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "dbx-model-output"

    program = Imp.predict("question -> answer", lm: lm)
    assert {:ok, rebound} = Imp.Clients.TrainingJob.rebind(refreshed, program)
    assert Imp.ProgramAccess.lm(rebound).model == "dbx-model-output"

    assert {:ok, cancelled} = Imp.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled
  end

  test "BootstrapFinetune accepts provider trainer structs" do
    lm = %{
      module: Imp.LM.Static,
      model: "gpt-test",
      opts: [handler: fn _messages, _opts -> %{answer: "4"} end]
    }

    program = Imp.predict("question -> answer", lm: lm)
    metric = Imp.Metrics.exact_match(:answer)

    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    result =
      metric
      |> Imp.Optimizer.BootstrapFinetune.new(trainer: trainer, max_demos: 1)
      |> Imp.Optimizer.BootstrapFinetune.compile(program, examples())

    assert %{
             program: %Imp.Predict.Predict{},
             job: %Imp.Clients.TrainingJob{provider: :openai}
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
               # Finetune assistant turns carry the trailing `[[ ## completed ## ]]`
               # marker, matching DSPy ChatAdapter.format_finetune_data (which
               # renders the assistant content via format_assistant_message_content,
               # always appending the marker) (dee-u4st axis A).
               %{
                 "role" => "assistant",
                 "content" => "[[ ## answer ## ]]\n4\n\n[[ ## completed ## ]]\n"
               }
             ]
           }

    assert_received {:openai_training_request, "https://api.example/v1/fine_tuning/jobs",
                     _headers, %{"training_file" => "file-uploaded-demos"}}
  end

  test "BootstrapFinetune forwards a caller OpenAI example encoder unchanged" do
    lm = %{
      module: Imp.LM.Static,
      model: "gpt-test",
      opts: [handler: fn _messages, _opts -> %{answer: "4"} end]
    }

    program = Imp.predict("question -> answer", lm: lm)
    owner = self()

    encoder = fn example ->
      send(owner, {:caller_example_encoder, Imp.Example.get(example, :question)})

      {:ok,
       %{
         messages: [
           %{role: "user", content: "caller-owned-input"},
           %{role: "assistant", content: "caller-owned-output"}
         ]
       }}
    end

    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    result =
      Imp.Optimizer.BootstrapFinetune.new(Imp.Metrics.exact_match(:answer),
        trainer: trainer,
        max_demos: 1,
        train_kwargs: [example_encoder: encoder]
      )
      |> Imp.Optimizer.BootstrapFinetune.compile(program, examples())

    assert %{job: %Imp.Clients.TrainingJob{provider: :openai}} = result
    assert_received {:caller_example_encoder, "2+2?"}
    assert_received {:openai_file_upload, _url, _headers, multipart}
    assert multipart =~ "caller-owned-input"
    assert multipart =~ "caller-owned-output"
    refute multipart =~ "Your input fields are:"
  end

  test "training optimizer constructors reject invalid boundary contracts" do
    metric = Imp.Metrics.exact_match(:answer)
    callback = fn _lm, _examples, _opts -> {:ok, Imp.Clients.TrainingJob.new(%{})} end

    assert {:ok, nil} = Imp.Clients.Trainer.validate_provider(nil)
    assert {:ok, String} = Imp.Clients.Trainer.validate_provider(String)
    assert {:ok, ^callback} = Imp.Clients.Trainer.validate_provider(callback)

    assert {:ok, %Imp.Clients.HTTPTrainer{}} =
             Imp.Clients.Trainer.validate_provider(%Imp.Clients.HTTPTrainer{})

    assert {:error, message} = Imp.Clients.Trainer.validate_provider(%{not: :a_trainer})

    assert message =~
             "expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback"

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFinetune\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.BootstrapFinetune.new(metric, %{max_demos: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFinetune\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   Imp.Optimizer.BootstrapFinetune.new(fn _example -> true end)
                 end

    assert_raise ArgumentError, ~r/Imp\.Optimizer\.GRPO\.new\/2: expected keyword options/, fn ->
      Imp.Optimizer.GRPO.new(fn _example -> 1.0 end, %{trainer: nil})
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFinetune\.new\/2: invalid value for :trainer option: expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback/,
                 fn ->
                   Imp.Optimizer.BootstrapFinetune.new(metric, trainer: %{not: :a_trainer})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.GRPO\.new\/2: invalid value for :trainer option: expected nil, a trainer module, a trainer struct, or an arity-3 trainer callback/,
                 fn ->
                   Imp.Optimizer.GRPO.new(fn _example -> 1.0 end,
                     trainer: fn _lm, _examples -> {:ok, :bad} end
                   )
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.GRPO\.new\/2 expects a reward function with arity 1, 2, or 3/,
                 fn ->
                   Imp.Optimizer.GRPO.new(fn _example, _prediction, _trace, _extra -> 1.0 end)
                 end
  end

  test "BootstrapFinetune treats zero max_demos as no provider demos and rejects negative counts" do
    lm = Imp.req_llm("gpt-test")
    program = Imp.predict("question -> answer", lm: lm)
    metric = Imp.Metrics.exact_match(:answer)

    trainer = fn _lm, demos, _opts ->
      send(self(), {:finetune_demos, demos})
      {:ok, Imp.Clients.TrainingJob.new(%{id: "job_0", provider: :test, status: :queued})}
    end

    result =
      metric
      |> Imp.Optimizer.BootstrapFinetune.new(trainer: trainer, max_demos: 0)
      |> Imp.Optimizer.BootstrapFinetune.compile(program, examples())

    assert %{program: %Imp.Predict.Predict{}, job: %Imp.Clients.TrainingJob{}} = result
    assert_received {:finetune_demos, []}

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFinetune\.new\/2: invalid value for :max_demos option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.BootstrapFinetune.new(metric, max_demos: -1)
                 end
  end

  test "BootstrapFinetune extracts trace rows and LM through composed program wrappers" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2"} end]
    }

    retriever = Imp.Retrieve.Memory.new([%{text: "multiplication by two"}], k: 1)

    program =
      "x, context -> doubled"
      |> Imp.program_of_thought(lm: lm, output_field: :doubled)
      |> Imp.rag(retriever, query_field: :x, k: 1)

    trainset = [
      Imp.example(x: 21, doubled: 42) |> Imp.with_inputs(:x)
    ]

    metric = Imp.Metrics.exact_match(:doubled)

    trainer = fn trainer_lm, demos, opts ->
      send(self(), {:bootstrap_finetune, trainer_lm, demos, opts})
      {:ok, Imp.Clients.TrainingJob.new(%{id: "job_wrapped", provider: :test})}
    end

    result =
      metric
      |> Imp.Optimizer.BootstrapFinetune.new(trainer: trainer, max_demos: 1)
      |> Imp.Optimizer.BootstrapFinetune.compile(program, trainset)

    assert %{
             program: %Imp.Predict.RAG{
               program: %Imp.Predict.ProgramOfThought{predict: %{demos: []}}
             },
             job: %Imp.Clients.TrainingJob{id: "job_wrapped"}
           } = result

    assert_received {:bootstrap_finetune, ^lm, [training_row], [method: :sft]}
    assert Imp.Example.get(training_row, :program) == "x * 2"
    assert Imp.Example.get(training_row, :doubled) == nil
  end

  test "GRPO extracts the provider LM through CodeAct and ProgramOfThought wrappers" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "42"} end]
    }

    program = Imp.code_act("question -> answer", [], lm: lm)
    trainset = [Imp.example(question: "life?", answer: "42") |> Imp.with_inputs(:question)]

    trainer = %GRPOTrainingFixture{owner: self()}

    assert {:ok, compiled} =
             Imp.Optimizer.GRPO.new(fn _example -> 0.75 end,
               trainer: trainer,
               num_train_steps: 1,
               status_poll_interval_ms: 0
             )
             |> Imp.Optimizer.GRPO.compile(program, trainset)

    assert Imp.ProgramAccess.lm(compiled).model == "grpo-model"
    assert_received {:grpo_started, ^lm, [num_generations: 1]}
    assert_received {:grpo_step, [%{batch_id: 1, group: [%{reward: 0.75}]}]}
    assert_received :grpo_terminated
  end

  test "an explicit GRPO-only trainer rejects SFT before trainer dispatch" do
    trainer = %GRPOTrainingFixture{owner: self()}

    assert {:error, {:unsupported_training_method, :sft}} =
             Imp.Clients.Trainer.finetune(
               trainer,
               Imp.req_llm("gpt-test"),
               examples(),
               method: :sft
             )

    refute_received {:grpo_started, _, _}
  end

  test "trainer accepts token-aligned Fast-Slow trajectories without discarding provenance" do
    trainer = %GRPOTrainingFixture{owner: self()}

    session =
      Imp.Clients.ReinforcementSession.new(%{
        id: "fast-slow-session",
        provider: :test,
        model: "model-v0",
        pending_batch_ids: ["question-group-1"]
      })

    trajectory = %{
      "rollout_id" => "rollout-1",
      "reward" => 1.0,
      "advantage" => 0.75,
      "behavior_policy_id" => "model-v0",
      "behavior_logprobs" => [-0.2, -0.1],
      "response_token_ids" => [101, 102],
      "response_mask" => [1, 1],
      "source" => "gepa_cache"
    }

    groups = [%{"batch_id" => "question-group-1", "group" => [trajectory]}]

    assert {:ok, updated} =
             Imp.Clients.Trainer.reinforcement_step(trainer, session, groups, objective: :cispo)

    assert updated.fulfilled_batch_ids == ["question-group-1"]
    assert_received {:grpo_step, ^groups}

    invalid = put_in(trajectory, ["response_mask"], [1])

    assert {:error, :invalid_reinforcement_groups} =
             Imp.Clients.Trainer.reinforcement_step(
               trainer,
               session,
               [%{"batch_id" => "question-group-1", "group" => [invalid]}]
             )
  end

  test "GRPO rejects OpenAI before reward evaluation or network submission" do
    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    reward_fn = fn _example ->
      send(self(), :grpo_reward_evaluated)
      1.0
    end

    assert {:error, {:unsupported_training_method, :grpo}} =
             Imp.Optimizer.GRPO.new(reward_fn, trainer: trainer)
             |> Imp.Optimizer.GRPO.compile(
               Imp.predict("question -> answer", lm: Imp.req_llm("gpt-test")),
               examples()
             )

    assert {:error, {:unsupported_training_method, :grpo}} =
             Imp.Clients.HTTPTrainer.finetune(
               trainer,
               Imp.req_llm("gpt-test"),
               examples(),
               method: :grpo
             )

    refute_received :grpo_reward_evaluated
    refute_received {:openai_file_upload, _, _, _}
    refute_received {:openai_training_request, _, _, _}
  end
end

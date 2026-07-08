defmodule ProviderTrainingLifecycleTest do
  use ExUnit.Case

  defmodule OpenAITrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      decoded = Jason.decode!(body)
      send(self(), {:openai_training_request, url, headers, decoded})

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

  defmodule DatabricksTrainingTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      decoded = Jason.decode!(body)
      send(self(), {:databricks_training_request, url, headers, decoded})

      {:ok,
       %{
         status: 200,
         headers: [],
         body: Jason.encode!(%{job_id: "dbx_1", state: "pending", result_model: nil})
       }}
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
    assert_received {^ref, [:dsex, :training, :submit, :start], _, %{provider: :openai}}
    assert_received {^ref, [:dsex, :training, :refresh, :start], _, %{job_id: "ftjob_123"}}
  end

  test "OpenAI trainer requires an uploaded training file id" do
    lm = DSEx.req_llm("gpt-test")

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:error, :openai_training_file_required} =
             DSEx.Clients.Trainer.finetune(trainer, lm, examples(), [])
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

  test "Databricks trainer submits expected payload and auth" do
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
  end

  test "BootstrapFinetune accepts provider trainer structs" do
    lm = DSEx.req_llm("gpt-test")

    program = DSEx.predict("question -> answer", lm: lm)
    metric = DSEx.Metrics.exact_match(:answer)

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport,
        training_file: "file-abc"
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
  end

  test "training optimizer constructors reject invalid boundary contracts" do
    metric = DSEx.Metrics.exact_match(:answer)

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
                 ~r/DSEx\.Optimizer\.GRPO\.new\/2 expects a reward function with arity 1/,
                 fn ->
                   DSEx.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end)
                 end
  end

  test "BootstrapFinetune clamps non-positive max_demos before training" do
    lm = DSEx.req_llm("gpt-test")
    program = DSEx.predict("question -> answer", lm: lm)
    metric = DSEx.Metrics.exact_match(:answer)

    trainer = fn _lm, demos, _opts ->
      send(self(), {:finetune_demos, demos})
      {:ok, DSEx.Clients.TrainingJob.new(%{id: "job_0", provider: :test, status: :queued})}
    end

    result =
      metric
      |> DSEx.Optimizer.BootstrapFinetune.new(trainer: trainer, max_demos: -5)
      |> DSEx.Optimizer.BootstrapFinetune.compile(program, examples())

    assert %{program: %DSEx.Predict.Predict{}, job: %DSEx.Clients.TrainingJob{}} = result
    assert_received {:finetune_demos, []}
  end
end

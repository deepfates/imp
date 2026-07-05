defmodule ProviderTrainingLifecycleTest do
  use ExUnit.Case

  defmodule OpenAITrainingTransport do
    @behaviour DSPy.HTTP

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
    @behaviour DSPy.HTTP

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

  defp examples do
    [
      DSPy.example(question: "2+2?", answer: "4") |> DSPy.Example.with_inputs(:question)
    ]
  end

  test "OpenAI trainer submits job and refreshes lifecycle status" do
    lm = DSPy.Clients.OpenAI.new("gpt-test", api_key: "sk-test")

    trainer =
      DSPy.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    assert {:ok, job} =
             DSPy.Clients.Trainer.finetune(trainer, lm, examples(),
               training_file: "file-abc",
               hyperparameters: [n_epochs: 1]
             )

    assert %DSPy.Clients.TrainingJob{id: "ftjob_123", provider: :openai, status: :running} = job

    assert_received {:openai_training_request, "https://api.example/v1/fine_tuning/jobs", headers,
                     payload}

    assert {"authorization", "Bearer sk-test"} in headers
    assert payload["model"] == "gpt-test"
    assert payload["training_file"] == "file-abc"
    assert payload["hyperparameters"] == %{"n_epochs" => 1}
    assert [%{"question" => "2+2?", "answer" => "4"}] = payload["dspy_training_data"]

    assert {:ok, refreshed} = DSPy.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "ft:gpt-test:org:abc"
  end

  test "Databricks trainer submits expected payload and auth" do
    lm = DSPy.Clients.Databricks.new("databricks-meta-llama", api_key: "dbc")

    trainer =
      DSPy.Clients.DatabricksTrainer.new(
        base_url: "https://dbc.example",
        api_key: "dbc-token",
        transport: DatabricksTrainingTransport
      )

    assert {:ok, job} =
             DSPy.Clients.Trainer.finetune(trainer, lm, examples(),
               method: :grpo,
               learning_rate: 1.0e-5
             )

    assert %DSPy.Clients.TrainingJob{id: "dbx_1", provider: :databricks, status: :pending} = job

    assert_received {:databricks_training_request, "https://dbc.example/api/2.0/dspy/finetune",
                     headers, payload}

    assert {"authorization", "Bearer dbc-token"} in headers
    assert payload["base_model"] == "databricks-meta-llama"
    assert payload["task_type"] == "grpo"
    assert payload["config"] == %{"learning_rate" => 1.0e-5}
    assert [%{"question" => "2+2?", "answer" => "4"}] = payload["train_data"]
  end

  test "BootstrapFinetune accepts provider trainer structs" do
    lm =
      DSPy.Clients.OpenAI.new("gpt-test",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    program = DSPy.predict("question -> answer", lm: lm)
    metric = DSPy.Metrics.exact_match(:answer)

    trainer =
      DSPy.Clients.OpenAITrainer.new(
        base_url: "https://api.example/v1",
        api_key: "sk-test",
        transport: OpenAITrainingTransport
      )

    result =
      metric
      |> DSPy.Teleprompt.BootstrapFinetune.new(trainer: trainer, max_demos: 1)
      |> DSPy.Teleprompt.BootstrapFinetune.compile(program, examples())

    assert %{program: %DSPy.Predict.Predict{}, job: %DSPy.Clients.TrainingJob{provider: :openai}} =
             result
  end
end

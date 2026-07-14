defmodule ProtocolTrainingProviderLifecycleTest do
  use ExUnit.Case

  @moduletag :protocol_training

  defmodule TrainedModelFixture do
    def generate_text(model, messages, _opts) do
      {:ok,
       %ReqLLM.Response{
         id: "resp_trained_model",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("Answer: 4")
       }}
    end
  end

  test "protocol training gate exercises provider-compatible submit and refresh lifecycle" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :training, :submit, :start],
        [:imp, :training, :refresh, :start]
      ])

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        assert request.headers["authorization"] == "Bearer sk-live-training-test"

        case request.path do
          "/v1/fine_tuning/jobs" ->
            assert request.method == "POST"
            payload = Jason.decode!(request.body)
            assert payload["model"] == "gpt-training-test"
            assert payload["training_file"] == "file-live-training-test"
            assert payload["suffix"] == "imp-live-gate"
            assert payload["metadata"] == %{"purpose" => "imp-live-training-gate"}

            {200,
             %{
               id: "ftjob_protocol_training_gate",
               status: "running",
               model: payload["model"]
             }}

          "/v1/fine_tuning/jobs/ftjob_protocol_training_gate" ->
            assert request.method == "GET"
            assert request.body == ""

            {200,
             %{
               id: "ftjob_protocol_training_gate",
               status: "succeeded",
               fine_tuned_model: "ft:gpt-training-test:imp:live-gate"
             }}

          "/v1/fine_tuning/jobs/ftjob_protocol_training_gate/cancel" ->
            assert request.method == "POST"
            assert request.body == ""

            {200,
             %{
               id: "ftjob_protocol_training_gate",
               status: "cancelled"
             }}
        end
      end)

    lm = Imp.req_llm("gpt-training-test", req_module: TrainedModelFixture)

    trainer =
      Imp.Clients.OpenAITrainer.new(
        base_url: base_url <> "/v1",
        api_key: "sk-live-training-test"
      )

    assert {:ok, job} =
             Imp.Clients.Trainer.finetune(trainer, lm, [],
               training_file: "file-live-training-test",
               suffix: "imp-live-gate",
               metadata: %{purpose: "imp-live-training-gate"}
             )

    assert %Imp.Clients.TrainingJob{
             id: "ftjob_protocol_training_gate",
             provider: :openai,
             model: "gpt-training-test",
             status: :running
           } = job

    assert is_binary(request_key = job.idempotency_key)

    checkpoint_path =
      Path.join(
        System.tmp_dir!(),
        "imp-protocol-training-job-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(checkpoint_path) end)
    assert :ok = Imp.Clients.TrainingJob.save!(job, checkpoint_path)
    refute File.read!(checkpoint_path) =~ "sk-live-training-test"

    job =
      Imp.Clients.TrainingJob.load!(checkpoint_path,
        api_key: "sk-live-training-test"
      )

    assert job.idempotency_key == request_key

    assert {:ok, refreshed} = Imp.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "ft:gpt-training-test:imp:live-gate"

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-protocol-trained-program-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = Imp.predict("question -> answer", lm: lm)

    assert {:ok, compiled} =
             Imp.Clients.TrainingJob.rebind(refreshed, program, path: path)

    assert {:ok, prediction} = Imp.call(compiled, %{question: "2+2?"})
    assert Imp.get(prediction, :answer) == "4"

    assert %Imp.Clients.ReqLLM{model: "openai:ft:gpt-training-test:imp:live-gate"} =
             Imp.ProgramAccess.lm(Imp.load!(path))

    assert {:ok, cancelled} = Imp.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled

    assert_received {^ref, [:imp, :training, :submit, :start], _measurements,
                     %{provider: :openai, model: "gpt-training-test"}}

    assert_received {^ref, [:imp, :training, :refresh, :start], _measurements,
                     %{provider: :openai, job_id: "ftjob_protocol_training_gate"}}
  end

  test "Databricks protocol fixture executes submit refresh cancel rebind and persistence" do
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.headers["authorization"] == "Bearer dbc-live-training-test"
        assert is_binary(request.headers["idempotency-key"])

        payload = Jason.decode!(request.body)

        case request.path do
          "/api/2.0/imp/finetune" ->
            assert payload["base_model"] == "databricks-meta-llama-test"
            assert payload["task_type"] == "sft"
            assert payload["config"] == %{"epochs" => 1}

            {200, %{job_id: "dbx_protocol_training_gate", state: "PENDING"}}

          "/api/2.0/imp/finetune/dbx_protocol_training_gate" ->
            assert payload["job_id"] == "dbx_protocol_training_gate"

            {200,
             %{
               job_id: "dbx_protocol_training_gate",
               state: "SUCCESS",
               result_model: "dbx:model:imp-live-gate"
             }}

          "/api/2.0/imp/finetune/dbx_protocol_training_gate/cancel" ->
            assert payload["job_id"] == "dbx_protocol_training_gate"
            {200, %{job_id: "dbx_protocol_training_gate", state: "CANCELED"}}
        end
      end)

    lm = Imp.req_llm("databricks-meta-llama-test", req_module: TrainedModelFixture)

    trainer =
      Imp.Clients.DatabricksTrainer.new(
        base_url: base_url,
        api_key: "dbc-live-training-test",
        retry_backoff_ms: 0
      )

    examples = [Imp.example(question: "2+2?", answer: "4") |> Imp.with_inputs(:question)]

    assert {:ok, job} =
             Imp.Clients.Trainer.finetune(trainer, lm, examples,
               epochs: 1,
               idempotency_key: "dbx-protocol-request"
             )

    assert job.provider == :databricks
    assert job.status == :pending
    assert job.idempotency_key == "dbx-protocol-request"

    assert {:ok, completed} = Imp.Clients.TrainingJob.refresh(job)
    assert completed.status == :succeeded
    assert completed.result_model == "dbx:model:imp-live-gate"

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-dbx-trained-program-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, compiled} =
             Imp.Clients.TrainingJob.rebind(
               completed,
               Imp.predict("question -> answer", lm: lm),
               path: path
             )

    assert {:ok, prediction} = Imp.call(compiled, %{question: "2+2?"})
    assert Imp.get(prediction, :answer) == "4"
    assert Imp.ProgramAccess.lm(Imp.load!(path)).model == "dbx:model:imp-live-gate"

    assert {:ok, cancelled} = Imp.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled
  end
end

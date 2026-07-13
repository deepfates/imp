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
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :training, :submit, :start],
        [:dsex, :training, :refresh, :start]
      ])

    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.headers["authorization"] == "Bearer sk-live-training-test"

        case request.path do
          "/v1/fine_tuning/jobs" ->
            assert request.method == "POST"
            payload = Jason.decode!(request.body)
            assert payload["model"] == "gpt-training-test"
            assert payload["training_file"] == "file-live-training-test"
            assert payload["suffix"] == "dsex-live-gate"
            assert payload["metadata"] == %{"purpose" => "dsex-live-training-gate"}

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
               fine_tuned_model: "ft:gpt-training-test:dsex:live-gate"
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

    lm = DSEx.req_llm("gpt-training-test", req_module: TrainedModelFixture)

    trainer =
      DSEx.Clients.OpenAITrainer.new(
        base_url: base_url <> "/v1",
        api_key: "sk-live-training-test"
      )

    assert {:ok, job} =
             DSEx.Clients.Trainer.finetune(trainer, lm, [],
               training_file: "file-live-training-test",
               suffix: "dsex-live-gate",
               metadata: %{purpose: "dsex-live-training-gate"}
             )

    assert %DSEx.Clients.TrainingJob{
             id: "ftjob_protocol_training_gate",
             provider: :openai,
             model: "gpt-training-test",
             status: :running
           } = job

    assert is_binary(request_key = job.idempotency_key)

    checkpoint_path =
      Path.join(
        System.tmp_dir!(),
        "dsex-protocol-training-job-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(checkpoint_path) end)
    assert :ok = DSEx.Clients.TrainingJob.save!(job, checkpoint_path)
    refute File.read!(checkpoint_path) =~ "sk-live-training-test"

    job =
      DSEx.Clients.TrainingJob.load!(checkpoint_path,
        api_key: "sk-live-training-test"
      )

    assert job.idempotency_key == request_key

    assert {:ok, refreshed} = DSEx.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "ft:gpt-training-test:dsex:live-gate"

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-protocol-trained-program-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, compiled} =
             DSEx.Clients.TrainingJob.rebind(refreshed, program, path: path)

    assert {:ok, prediction} = DSEx.call(compiled, %{question: "2+2?"})
    assert DSEx.get(prediction, :answer) == "4"

    assert %DSEx.Clients.ReqLLM{model: "openai:ft:gpt-training-test:dsex:live-gate"} =
             DSEx.ProgramAccess.lm(DSEx.load!(path))

    assert {:ok, cancelled} = DSEx.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled

    assert_received {^ref, [:dsex, :training, :submit, :start], _measurements,
                     %{provider: :openai, model: "gpt-training-test"}}

    assert_received {^ref, [:dsex, :training, :refresh, :start], _measurements,
                     %{provider: :openai, job_id: "ftjob_protocol_training_gate"}}
  end

  test "Databricks protocol fixture executes submit refresh cancel rebind and persistence" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.headers["authorization"] == "Bearer dbc-live-training-test"
        assert is_binary(request.headers["idempotency-key"])

        payload = Jason.decode!(request.body)

        case request.path do
          "/api/2.0/dsex/finetune" ->
            assert payload["base_model"] == "databricks-meta-llama-test"
            assert payload["task_type"] == "sft"
            assert payload["config"] == %{"epochs" => 1}

            {200, %{job_id: "dbx_protocol_training_gate", state: "PENDING"}}

          "/api/2.0/dsex/finetune/dbx_protocol_training_gate" ->
            assert payload["job_id"] == "dbx_protocol_training_gate"

            {200,
             %{
               job_id: "dbx_protocol_training_gate",
               state: "SUCCESS",
               result_model: "dbx:model:dsex-live-gate"
             }}

          "/api/2.0/dsex/finetune/dbx_protocol_training_gate/cancel" ->
            assert payload["job_id"] == "dbx_protocol_training_gate"
            {200, %{job_id: "dbx_protocol_training_gate", state: "CANCELED"}}
        end
      end)

    lm = DSEx.req_llm("databricks-meta-llama-test", req_module: TrainedModelFixture)

    trainer =
      DSEx.Clients.DatabricksTrainer.new(
        base_url: base_url,
        api_key: "dbc-live-training-test",
        retry_backoff_ms: 0
      )

    examples = [DSEx.example(question: "2+2?", answer: "4") |> DSEx.with_inputs(:question)]

    assert {:ok, job} =
             DSEx.Clients.Trainer.finetune(trainer, lm, examples,
               epochs: 1,
               idempotency_key: "dbx-protocol-request"
             )

    assert job.provider == :databricks
    assert job.status == :pending
    assert job.idempotency_key == "dbx-protocol-request"

    assert {:ok, completed} = DSEx.Clients.TrainingJob.refresh(job)
    assert completed.status == :succeeded
    assert completed.result_model == "dbx:model:dsex-live-gate"

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-dbx-trained-program-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, compiled} =
             DSEx.Clients.TrainingJob.rebind(
               completed,
               DSEx.predict("question -> answer", lm: lm),
               path: path
             )

    assert {:ok, prediction} = DSEx.call(compiled, %{question: "2+2?"})
    assert DSEx.get(prediction, :answer) == "4"
    assert DSEx.ProgramAccess.lm(DSEx.load!(path)).model == "dbx:model:dsex-live-gate"

    assert {:ok, cancelled} = DSEx.Clients.TrainingJob.cancel(job)
    assert cancelled.status == :cancelled
  end
end

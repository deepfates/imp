defmodule LiveTrainingProviderLifecycleTest do
  use ExUnit.Case

  @moduletag :live_training

  test "live training gate exercises provider-compatible submit and refresh lifecycle" do
    ref =
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :training, :submit, :start],
        [:dsex, :training, :refresh, :start]
      ])

    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.headers["authorization"] == "Bearer sk-live-training-test"

        payload = Jason.decode!(request.body)

        case request.path do
          "/v1/fine_tuning/jobs" ->
            assert payload["model"] == "gpt-training-test"
            assert payload["training_file"] == "file-live-training-test"
            assert payload["suffix"] == "dsex-live-gate"
            assert payload["metadata"] == %{"purpose" => "dsex-live-training-gate"}

            {200,
             %{
               id: "ftjob_live_training_gate",
               status: "running",
               model: payload["model"]
             }}

          "/v1/fine_tuning/jobs/ftjob_live_training_gate" ->
            assert payload["job_id"] == "ftjob_live_training_gate"

            {200,
             %{
               id: "ftjob_live_training_gate",
               status: "succeeded",
               fine_tuned_model: "ft:gpt-training-test:dsex:live-gate"
             }}
        end
      end)

    lm = DSEx.Clients.OpenAI.new("gpt-training-test", api_key: "sk-live-training-test")

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
             id: "ftjob_live_training_gate",
             provider: :openai,
             model: "gpt-training-test",
             status: :running
           } = job

    assert {:ok, refreshed} = DSEx.Clients.TrainingJob.refresh(job)
    assert refreshed.status == :succeeded
    assert refreshed.result_model == "ft:gpt-training-test:dsex:live-gate"

    assert_received {^ref, [:dsex, :training, :submit, :start], _measurements,
                     %{provider: :openai, model: "gpt-training-test"}}

    assert_received {^ref, [:dsex, :training, :refresh, :start], _measurements,
                     %{provider: :openai, job_id: "ftjob_live_training_gate"}}
  end
end

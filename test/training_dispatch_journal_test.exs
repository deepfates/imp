defmodule TrainingDispatchJournalTest do
  use ExUnit.Case

  alias Imp.Clients.{Trainer, TrainingDispatch, TrainingJob}

  defmodule DurableTrainer do
    @behaviour Imp.Clients.Trainer
    defstruct [
      :owner,
      :state,
      :submits,
      :runtime_mode,
      :endpoint,
      :api_key,
      :runtime_callback,
      :headers
    ]

    @impl true
    def supported_methods(_trainer), do: [:sft]

    @impl true
    def finetune(trainer, lm, examples, opts) do
      dispatch_id = Keyword.fetch!(opts, :idempotency_key)
      send(trainer.owner, {:training_dispatched, dispatch_id})
      Agent.update(trainer.submits, &(&1 + 1))

      job_identity =
        if trainer.runtime_mode == :wrong_identity,
          do: "wrong-dispatch-identity",
          else: dispatch_id

      status_url =
        case trainer.runtime_mode do
          :unsafe_url ->
            "https://provider.test/jobs/1?api_key=sk-url-canary-1234567890"

          :unsafe_userinfo ->
            "https://user:tiny-userinfo-canary@provider.test/jobs/1"

          :unsafe_fragment ->
            "https://provider.test/jobs/1#access_token=tiny-fragment-canary"

          :unsafe_path ->
            "https://provider.test/jobs/access_token=tiny-path-canary"

          :unsafe_nested_url ->
            "https://provider.test/jobs/1?next=https%3A%2F%2Fother.test%2F%3Fapi_key%3Dtiny-nested-canary"

          :unsafe_double_encoded ->
            "https://provider.test/jobs/1?api%255fkey=tiny-double-encoded-canary"

          _other ->
            "https://provider.test/jobs/1"
        end

      result_model =
        if trainer.runtime_mode == :unsafe_artifact,
          do: "artifact://models/sk-artifact-canary-1234567890",
          else: nil

      job =
        TrainingJob.new(%{
          id:
            if(trainer.runtime_mode == :unsafe_id,
              do: "access_token=tiny-id-canary",
              else: "provider-job-1"
            ),
          provider: :fixture,
          model: lm.model,
          status: :running,
          training_data: examples,
          idempotency_key: job_identity,
          status_url: status_url,
          result_model: result_model,
          transport: trainer.runtime_callback,
          metadata: %{
            authorization: "Bearer dummy-training-canary",
            response_schema: %{token: :string}
          }
        })

      Agent.update(trainer.state, &Map.put(&1, dispatch_id, job))
      send(trainer.owner, {:training_accepted, dispatch_id})

      if trainer.runtime_mode == :accepted_then_hang, do: Process.sleep(:infinity)
      {:ok, job}
    end

    @impl true
    def reconcile_finetune(trainer, dispatch_id) do
      send(trainer.owner, {:training_reconciled, dispatch_id})

      case Agent.get(trainer.state, &Map.fetch(&1, dispatch_id)) do
        {:ok, job} ->
          job = %{job | transport: trainer.runtime_callback}

          case trainer.runtime_mode do
            :wrong_reconciliation -> {:ok, %{job | idempotency_key: "wrong-reconciliation"}}
            :other_reconciled_job -> {:ok, %{job | id: "provider-job-2"}}
            _other -> {:ok, job}
          end

        :error ->
          {:error, :training_job_not_found}
      end
    end
  end

  setup do
    state = start_supervised!({Agent, fn -> %{} end})
    {:ok, submits} = Agent.start_link(fn -> 0 end)

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-training-dispatch-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn ->
      File.rm(path)
      if Process.alive?(submits), do: Agent.stop(submits)
    end)

    %{state: state, submits: submits, path: path}
  end

  test "a crash after durable preparation but before dispatch resumes exactly once", context do
    owner = self()

    observer = fn
      :prepared, _identity ->
        send(owner, :training_intent_prepared)
        Process.sleep(:infinity)

      _phase, _identity ->
        :ok
    end

    task =
      Task.async(fn ->
        dispatch(trainer(context, :ok), context.path, dispatch_observer: observer)
      end)

    assert_receive :training_intent_prepared, 5_000
    Task.shutdown(task, :brutal_kill)
    refute_received {:training_dispatched, _dispatch_id}
    assert %{phase: :prepared} = TrainingDispatch.load!(context.path)

    assert {:ok, %TrainingJob{id: "provider-job-1"}} =
             dispatch(trainer(context, :ok), context.path)

    assert_received {:training_dispatched, dispatch_id}
    assert_received {:training_accepted, ^dispatch_id}

    assert %{
             phase: :committed,
             intent: %{dispatch_id: ^dispatch_id},
             job: %TrainingJob{metadata: %{"response_schema" => %{"token" => "string"}}}
           } =
             TrainingDispatch.load!(context.path)
  end

  test "an accepted job survives caller death and is recovered by reconciliation", context do
    hanging_trainer = trainer(context, :accepted_then_hang)

    task =
      Task.async(fn ->
        dispatch(hanging_trainer, context.path)
      end)

    assert_receive {:training_dispatched, dispatch_id}, 5_000
    assert_receive {:training_accepted, ^dispatch_id}, 5_000
    Task.shutdown(task, :brutal_kill)

    assert %{phase: :dispatching, intent: %{dispatch_id: ^dispatch_id}} =
             TrainingDispatch.load!(context.path)

    assert {:ok, %TrainingJob{id: "provider-job-1", idempotency_key: ^dispatch_id}} =
             dispatch(trainer(context, :ok), context.path)

    assert_received {:training_reconciled, ^dispatch_id}
    refute_received {:training_dispatched, ^dispatch_id}
    assert %{phase: :committed} = TrainingDispatch.load!(context.path)
  end

  test "a committed handle is returned after the caller loses the original return", context do
    owner = self()

    observer = fn
      :committed, identity ->
        send(owner, {:training_handle_committed, identity.dispatch_id})
        Process.sleep(:infinity)

      _phase, _identity ->
        :ok
    end

    task =
      Task.async(fn ->
        dispatch(trainer(context, :ok), context.path, dispatch_observer: observer)
      end)

    assert_receive {:training_handle_committed, dispatch_id}, 5_000
    Task.shutdown(task, :brutal_kill)

    assert %{phase: :committed, intent: %{dispatch_id: ^dispatch_id}} =
             TrainingDispatch.load!(context.path)

    refute File.read!(context.path) =~ "dummy-training-canary"
    refute File.read!(context.path) =~ "Bearer"

    assert {:ok, %TrainingJob{id: "provider-job-1", idempotency_key: ^dispatch_id}} =
             dispatch(trainer(context, :ok), context.path)

    refute_received {:training_dispatched, _dispatch_id}
  end

  test "an ambiguous dispatch without reconciliation fails closed and journals no credentials",
       context do
    callback = fn lm, examples, opts ->
      dispatch_id = Keyword.fetch!(opts, :idempotency_key)

      {:ok,
       TrainingJob.new(%{
         id: "anonymous-job",
         model: lm.model,
         training_data: examples,
         idempotency_key: dispatch_id
       })}
    end

    dispatch_id =
      TrainingDispatch.prepare!(callback, lm(), examples(), [method: :sft], context.path)

    journal = TrainingDispatch.load!(context.path)

    :ok =
      context.path
      |> journal_artifact(:dispatching, journal.intent)
      |> then(fn artifact -> File.write!(context.path, artifact, [:sync]) end)

    assert {:error, {:training_dispatch_ambiguous, ^dispatch_id, :reconciliation_not_supported}} =
             dispatch(callback, context.path)

    persisted = File.read!(context.path)
    refute persisted =~ "dummy-training-canary"
    refute persisted =~ "Bearer"
  end

  test "fifty concurrent callers sharing a journal submit exactly once", context do
    provider = trainer(context, :ok)

    results =
      1..50
      |> Task.async_stream(fn _index -> dispatch(provider, context.path) end,
        max_concurrency: 50,
        timeout: 5_000,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %TrainingJob{id: "provider-job-1"}}} -> true
             _other -> false
           end)

    assert Agent.get(context.submits, & &1) == 1
    assert %{phase: :committed} = TrainingDispatch.load!(context.path)
  end

  test "a provider result with the wrong dispatch identity is never committed", context do
    assert {:error, {:training_dispatch_job_identity_mismatch, dispatch_id}} =
             dispatch(trainer(context, :wrong_identity), context.path)

    assert %{phase: :dispatching, intent: %{dispatch_id: ^dispatch_id}, job: nil} =
             TrainingDispatch.load!(context.path)
  end

  test "reconciliation cannot substitute a job with the wrong dispatch identity", context do
    provider = trainer(context, :accepted_then_hang)
    hanging = Task.async(fn -> dispatch(provider, context.path) end)

    assert_receive {:training_dispatched, dispatch_id}, 5_000
    assert_receive {:training_accepted, ^dispatch_id}, 5_000
    Task.shutdown(hanging, :brutal_kill)

    assert {:error, {:training_dispatch_job_identity_mismatch, ^dispatch_id}} =
             dispatch(trainer(context, :wrong_reconciliation), context.path)

    assert %{phase: :dispatching, job: nil} = TrainingDispatch.load!(context.path)
  end

  test "committed resume rejects a reconciled job with a different provider job id", context do
    assert {:ok, %TrainingJob{id: "provider-job-1"}} =
             dispatch(trainer(context, :ok), context.path)

    assert {:error, {:training_dispatch_reconciled_wrong_job, "provider-job-1", "provider-job-2"}} =
             dispatch(trainer(context, :other_reconciled_job), context.path)
  end

  test "credential-bearing URL and artifact locators fail closed without persistence", context do
    for {mode, field, canary} <- [
          {:unsafe_url, "status_url", "sk-url-canary-1234567890"},
          {:unsafe_userinfo, "status_url", "tiny-userinfo-canary"},
          {:unsafe_fragment, "status_url", "tiny-fragment-canary"},
          {:unsafe_path, "status_url", "tiny-path-canary"},
          {:unsafe_nested_url, "status_url", "tiny-nested-canary"},
          {:unsafe_double_encoded, "status_url", "tiny-double-encoded-canary"},
          {:unsafe_id, "id", "tiny-id-canary"},
          {:unsafe_artifact, "result_model", "sk-artifact-canary-1234567890"}
        ] do
      path = context.path <> "-#{mode}"

      assert {:error, {:training_dispatch_unsafe_job_locator, ^field}} =
               dispatch(trainer(context, mode), path)

      persisted = File.read!(path)
      refute persisted =~ canary
      refute persisted =~ "api_key"
      assert %{phase: :dispatching, job: nil} = TrainingDispatch.load!(path)
      File.rm(path)
    end

    semantic_path = context.path <> "-semantic-model"

    assert {:ok, %TrainingJob{model: "org/token/model"}} =
             Trainer.finetune(
               trainer(context, :ok),
               %{model: "org/token/model"},
               examples(),
               method: :sft,
               dispatch_journal_path: semantic_path
             )

    File.rm(semantic_path)
  end

  test "custom provider runtime is rebuilt by reconciliation while credentials and PIDs are not identity",
       context do
    first_runtime = fn request -> {:first_runtime, request} end

    first = %{
      trainer(context, :ok)
      | api_key: "sk-first-runtime-1234567890",
        runtime_callback: first_runtime,
        headers: [{"Authorization", "short-header-canary-one"}]
    }

    assert {:ok, %TrainingJob{transport: ^first_runtime}} = dispatch(first, context.path)

    second_runtime = fn request -> {:second_runtime, request} end

    restarted = %{
      trainer(context, :ok)
      | api_key: "sk-second-runtime-1234567890",
        runtime_callback: second_runtime,
        headers: [{"Authorization", "short-header-canary-two"}]
    }

    # The provider's reconciliation callback supplies fresh process-local runtime;
    # the callback, credential, owner PID, and Agent PID are excluded from identity.
    assert {:ok, %TrainingJob{transport: ^second_runtime} = restored} =
             dispatch(restarted, context.path)

    assert restored.transport.(:probe) == {:second_runtime, :probe}
    persisted = File.read!(context.path)
    refute persisted =~ "sk-first-runtime"
    refute persisted =~ "sk-second-runtime"
    refute persisted =~ "short-header-canary"
  end

  test "committed custom provider without reconciliation reports runtime restoration failure",
       context do
    callback = fn lm, examples, opts ->
      {:ok,
       TrainingJob.new(%{
         id: "anonymous-job",
         model: lm.model,
         training_data: examples,
         idempotency_key: Keyword.fetch!(opts, :idempotency_key)
       })}
    end

    assert {:ok, %TrainingJob{id: "anonymous-job"}} = dispatch(callback, context.path)

    assert {:error, {:training_dispatch_runtime_restoration_unavailable, dispatch_id}} =
             dispatch(callback, context.path)

    assert is_binary(dispatch_id)
  end

  test "semantic identity detects endpoint drift but ignores credential and runtime drift",
       context do
    assert {:ok, %TrainingJob{}} = dispatch(trainer(context, :ok), context.path)

    changed_runtime = %{
      trainer(context, :ok)
      | api_key: "sk-rotated-credential-1234567890",
        runtime_callback: fn _request -> :new_runtime end
    }

    assert {:ok, %TrainingJob{}} = dispatch(changed_runtime, context.path)

    drifted_endpoint = %{changed_runtime | endpoint: "https://other-provider.test/v2"}

    assert {:error, :training_dispatch_identity_mismatch} =
             dispatch(drifted_endpoint, context.path)
  end

  test "semantic identity ignores ordering of unique keyword options", context do
    provider = trainer(context, :ok)

    assert {:ok, %TrainingJob{}} =
             Trainer.finetune(provider, lm(), examples(),
               method: :sft,
               learning_rate: 0.1,
               dispatch_journal_path: context.path
             )

    assert {:ok, %TrainingJob{}} =
             Trainer.finetune(provider, lm(), examples(),
               learning_rate: 0.1,
               method: :sft,
               dispatch_journal_path: context.path
             )

    assert Agent.get(context.submits, & &1) == 1
  end

  test "checksum detects accidental journal mutation without claiming authenticated storage",
       context do
    assert {:ok, %TrainingJob{}} = dispatch(trainer(context, :ok), context.path)

    tampered =
      context.path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["payload", "phase"], "dispatching")
      |> Jason.encode!()

    File.write!(context.path, tampered)

    assert_raise ArgumentError, ~r/checksum mismatch/, fn ->
      TrainingDispatch.load!(context.path)
    end
  end

  defp dispatch(provider, path, extra_opts \\ []) do
    Trainer.finetune(
      provider,
      lm(),
      examples(),
      [method: :sft, dispatch_journal_path: path] ++ extra_opts
    )
  end

  defp trainer(context, mode),
    do: %DurableTrainer{
      owner: self(),
      state: context.state,
      submits: context.submits,
      runtime_mode: mode,
      endpoint: "https://provider.test/v1",
      api_key: "sk-runtime-only-1234567890",
      headers: [{"Authorization", "short-header-canary-default"}]
    }

  defp lm, do: %{model: "base-model", api_key: "dummy-training-canary"}

  defp examples do
    [Imp.example(question: "safe local question", answer: "safe local answer")]
  end

  # Re-encodes a valid journal at a requested crash phase without exposing a
  # mutation API in production. The payload/checksum shape is asserted here.
  defp journal_artifact(path, phase, intent) do
    _ = path

    payload = %{
      "phase" => Atom.to_string(phase),
      "intent" => %{
        "dispatch_id" => intent.dispatch_id,
        "identity_digest" => intent.identity_digest,
        "provider" => intent.provider,
        "model" => intent.model,
        "method" => to_string(intent.method)
      },
      "job" => nil
    }

    digest =
      payload
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Jason.encode!(%{
      "artifact_type" => "imp_training_dispatch_journal",
      "schema_version" => 1,
      "payload_sha256" => "sha256:" <> digest,
      "payload" => payload
    })
  end
end

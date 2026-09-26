defmodule GRPOLifecycleTest do
  use ExUnit.Case

  defmodule DurableTrainer do
    @behaviour Imp.Clients.Trainer
    defstruct [:owner, :state, :runtime_mode, identity: :fixture]

    @impl true
    def supported_methods(_trainer), do: [:grpo]

    @impl true
    def start_reinforcement(trainer, lm, opts) do
      dispatch_id = Keyword.get(opts, :dispatch_id, "ephemeral-session")
      send(trainer.owner, {:grpo_start, dispatch_id})

      session =
        Imp.Clients.ReinforcementSession.new(%{
          id: "durable-session",
          provider: :fixture,
          model: lm,
          pending_batch_ids:
            case trainer.runtime_mode do
              :zero_steps -> []
              :partial_step_then_hang -> [1, 2]
              _other -> [1]
            end,
          metadata:
            if(trainer.runtime_mode in [:all_groups_accept_then_hang, :all_groups_ok],
              do: %{batch_assignment: :all_generated_groups},
              else: %{}
            )
        })

      Agent.update(trainer.state, &Map.put(&1, dispatch_id, session))
      send(trainer.owner, {:grpo_accepted, dispatch_id})

      if trainer.runtime_mode == :accepted_then_hang, do: Process.sleep(1_000)
      {:ok, session}
    end

    @impl true
    def reconcile_reinforcement(trainer, dispatch_id) do
      send(trainer.owner, {:grpo_reconcile, dispatch_id})

      case Agent.get(trainer.state, &Map.fetch(&1, dispatch_id)) do
        {:ok, session} -> {:ok, session}
        :error -> {:error, :reinforcement_session_not_found}
      end
    end

    @impl true
    def reinforcement_status(trainer, session) do
      send(trainer.owner, :grpo_status)
      if trainer.runtime_mode == :hung_status, do: Process.sleep(1_000)
      {:ok, session}
    end

    @impl true
    def reinforcement_step(trainer, session, groups, opts) do
      send(trainer.owner, {:grpo_step, opts})
      send(trainer.owner, {:grpo_step_batches, groups})
      ids = Enum.map(groups, & &1.batch_id)

      case trainer.runtime_mode do
        :provider_error ->
          :ok

        :pending_step_then_hang ->
          Process.sleep(1_000)

        :partial_step_then_hang ->
          session
          |> Imp.Clients.ReinforcementSession.fulfill(Enum.take(ids, 1))
          |> then(&update_session(trainer.state, &1))

          Process.sleep(1_000)

        mode ->
          updated = Imp.Clients.ReinforcementSession.fulfill(session, ids)
          update_session(trainer.state, updated)

          if mode in [:accepted_step_then_hang, :all_groups_accept_then_hang],
            do: Process.sleep(1_000)
      end

      case trainer.runtime_mode do
        :provider_error -> {:error, :provider_transport_closed}
        _other -> {:ok, session}
      end
    end

    @impl true
    def terminate_reinforcement(trainer, session) do
      send(trainer.owner, :grpo_terminate)

      case trainer.runtime_mode do
        :termination_error ->
          {:error, :provider_refused_termination}

        :hung_termination ->
          Process.sleep(1_000)
          {:error, :unexpected_hung_termination_return}

        _other ->
          terminated = %{session | status: :succeeded, pending_batch_ids: []}
          update_session(trainer.state, terminated)
          {:ok, terminated}
      end
    end

    @impl true
    def final_model_artifact(_trainer, _session), do: {:ok, "trained/durable-grpo"}

    defp update_session(state, session) do
      Agent.update(state, fn sessions ->
        Map.new(sessions, fn {dispatch_id, existing} ->
          if existing.id == session.id, do: {dispatch_id, session}, else: {dispatch_id, existing}
        end)
      end)
    end
  end

  defmodule TwoPredictorProgram do
    @behaviour Imp.Module

    defstruct [:first, :second]

    @impl true
    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    @impl true
    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    @impl true
    def call(program, inputs) do
      with {:ok, first} <- Imp.Module.call(program.first, inputs),
           {:ok, second} <- Imp.Module.call(program.second, inputs) do
        {:ok,
         Imp.Prediction.new(
           Map.merge(Imp.Prediction.to_map(first), Imp.Prediction.to_map(second))
         )}
      end
    end
  end

  setup do
    state = start_supervised!({Agent, fn -> %{} end})

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-grpo-lifecycle-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    %{state: state, path: path}
  end

  test "provider callbacks are bounded by default" do
    optimizer = Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end)
    assert optimizer.callback_timeout_ms == 30_000
  end

  describe "rollout timeout threading" do
    test "defaults to 5000ms and accepts :infinity" do
      assert Imp.Optimizer.GRPO.new(fn _e, _p -> 1.0 end).timeout == 5_000

      assert %Imp.Optimizer.GRPO{timeout: :infinity} =
               Imp.Optimizer.GRPO.new(fn _e, _p -> 1.0 end, timeout: :infinity)
    end

    test "a rollout slower than the configured timeout is killed and scored as a failure",
         context do
      optimizer = optimizer(trainer(context, :ok), nil, num_train_steps: 1, timeout: 20)

      assert {:ok, _compiled} =
               Imp.Optimizer.GRPO.compile(optimizer, slow_program(200), trainset())

      assert_received {:grpo_step_batches, batches}
      rewards = for group <- batches, completion <- group.group, do: completion.reward
      assert rewards != []
      assert Enum.all?(rewards, &(&1 == 0.0))
    end

    test "raising the timeout past rollout latency preserves the real reward (5s default was previously not threadable)",
         context do
      optimizer = optimizer(trainer(context, :ok), nil, num_train_steps: 1, timeout: 2_000)

      assert {:ok, _compiled} =
               Imp.Optimizer.GRPO.compile(optimizer, slow_program(200), trainset())

      assert_received {:grpo_step_batches, batches}
      rewards = for group <- batches, completion <- group.group, do: completion.reward
      assert rewards != []
      assert Enum.all?(rewards, &(&1 == 1.0))
    end
  end

  test "an accepted session is reconciled after the start callback crash window", context do
    first = trainer(context, :accepted_then_hang)
    optimizer = optimizer(first, context.path, num_train_steps: 0)

    assert {:error, {:reinforcement_callback_timeout, :start_reinforcement, 25}} =
             Imp.Optimizer.GRPO.compile(optimizer, program(), trainset())

    assert_received {:grpo_accepted, dispatch_id}
    assert_received {:grpo_start, ^dispatch_id}
    assert File.regular?(context.path)

    assert %{phase: :dispatch_intent, data: %{dispatch_id: ^dispatch_id}} =
             Imp.Optimizer.GRPO.Checkpoint.load!(context.path)

    resumed = %{optimizer | trainer: trainer(context, :ok)}
    assert {:ok, compiled} = Imp.Optimizer.GRPO.compile(resumed, program(), trainset())
    assert_received {:grpo_reconcile, ^dispatch_id}
    refute_received {:grpo_start, _other_dispatch}
    refute File.exists?(context.path)
    assert Imp.ProgramAccess.get_metadata(compiled, :training_artifact).resumed
  end

  test "a hung status callback is bounded and the session is still terminated", context do
    optimizer = optimizer(trainer(context, :hung_status), nil, num_train_steps: 1)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:reinforcement_callback_timeout, :reinforcement_status, 25}} =
             Imp.Optimizer.GRPO.compile(optimizer, program(), trainset())

    assert System.monotonic_time(:millisecond) - started_at < 300
    assert_received :grpo_status
    assert_received :grpo_terminate
  end

  test "termination failures remain visible and a checkpoint resumes without replaying steps",
       context do
    first = optimizer(trainer(context, :termination_error), context.path, num_train_steps: 1)

    assert {:error, {:grpo_termination_failed, :provider_refused_termination}} =
             Imp.Optimizer.GRPO.compile(first, program(), trainset())

    assert_received {:grpo_step, _opts}

    assert %{phase: :termination_failed, data: %{next_step: 1}} =
             Imp.Optimizer.GRPO.Checkpoint.load!(context.path)

    resumed = %{first | trainer: trainer(context, :ok)}
    assert {:ok, compiled} = Imp.Optimizer.GRPO.compile(resumed, program(), trainset())
    refute_received :grpo_step
    assert_received :grpo_terminate
    assert Imp.ProgramAccess.lm(compiled).model == "trained/durable-grpo"
    assert Imp.ProgramAccess.get_metadata(compiled, :training_artifact).resumed
    refute File.exists?(context.path)
  end

  test "a hung termination is bounded and reported truthfully", context do
    optimizer = optimizer(trainer(context, :hung_termination), context.path, num_train_steps: 0)

    assert {:error,
            {:grpo_termination_failed,
             {:reinforcement_callback_timeout, :terminate_reinforcement, 25}}} =
             Imp.Optimizer.GRPO.compile(optimizer, program(), trainset())

    assert %{phase: :termination_failed, data: %{termination_error: _reason}} =
             Imp.Optimizer.GRPO.Checkpoint.load!(context.path)
  end

  test "an accepted reinforcement effect is recovered without replay", context do
    first =
      optimizer(trainer(context, :accepted_step_then_hang), context.path, num_train_steps: 1)

    assert {:error,
            {:grpo_step_outcome_unknown, step_id,
             {:reinforcement_callback_timeout, :reinforcement_step, 25}}} =
             Imp.Optimizer.GRPO.compile(first, program(), trainset())

    assert_received {:grpo_step, first_opts}
    assert first_opts[:step_id] == step_id
    assert first_opts[:idempotency_key] == step_id

    assert %{phase: :running, data: %{next_step: 0, step_intent: %{id: ^step_id}}} =
             Imp.Optimizer.GRPO.Checkpoint.load!(context.path)

    resumed = %{first | trainer: trainer(context, :ok)}
    assert {:ok, _compiled} = Imp.Optimizer.GRPO.compile(resumed, program(), trainset())
    refute_received {:grpo_step, _opts}
    assert_received :grpo_terminate
    refute File.exists?(context.path)
  end

  test "a demonstrably pending reinforcement intent replays exact batches with the stable key",
       context do
    first = optimizer(trainer(context, :pending_step_then_hang), context.path, num_train_steps: 1)

    assert {:error, {:grpo_step_outcome_unknown, step_id, _timeout}} =
             Imp.Optimizer.GRPO.compile(first, program(), trainset())

    assert_received {:grpo_step, first_opts}
    assert_received {:grpo_step_batches, first_batches}
    resumed = %{first | trainer: trainer(context, :ok)}
    assert {:ok, _compiled} = Imp.Optimizer.GRPO.compile(resumed, program(), trainset())
    assert_received {:grpo_step, second_opts}
    assert_received {:grpo_step_batches, second_batches}
    assert first_opts[:step_id] == step_id
    assert second_opts[:step_id] == step_id
    assert second_opts[:idempotency_key] == step_id
    assert second_batches == first_batches
  end

  test "a provider error after dispatch remains unknown until durable reconciliation", context do
    first = optimizer(trainer(context, :provider_error), context.path, num_train_steps: 1)

    assert {:error, {:grpo_step_outcome_unknown, step_id, :provider_transport_closed}} =
             Imp.Optimizer.GRPO.compile(first, program(), trainset())

    assert_received {:grpo_step, first_opts}
    assert first_opts[:step_id] == step_id
    assert File.regular?(context.path)

    resumed = %{first | trainer: trainer(context, :ok)}
    assert {:ok, _compiled} = Imp.Optimizer.GRPO.compile(resumed, program(), trainset())
    assert_received {:grpo_step, second_opts}
    assert second_opts[:step_id] == step_id
    assert second_opts[:idempotency_key] == step_id
  end

  test "credential-shaped replay data is sanitized before first submission and remains exact",
       context do
    canary = "sk-test-secret-1234567890"
    dataset = trainset(canary)
    first = optimizer(trainer(context, :pending_step_then_hang), context.path, num_train_steps: 1)

    assert {:error, {:grpo_step_outcome_unknown, _step_id, _timeout}} =
             Imp.Optimizer.GRPO.compile(first, program(), dataset)

    assert_received {:grpo_step_batches, first_batches}
    refute inspect(first_batches) =~ canary
    assert inspect(first_batches) =~ "[REDACTED]"

    resumed = %{first | trainer: trainer(context, :ok)}
    assert {:ok, _compiled} = Imp.Optimizer.GRPO.compile(resumed, program(), dataset)
    assert_received {:grpo_step_batches, second_batches}
    assert second_batches == first_batches
  end

  test "a partially visible reinforcement effect is not guessed or replayed", context do
    first =
      optimizer(trainer(context, :partial_step_then_hang), context.path,
        num_train_steps: 1,
        num_rollouts_per_grpo_step: 2
      )

    assert {:error, {:grpo_step_outcome_unknown, step_id, _timeout}} =
             Imp.Optimizer.GRPO.compile(first, program(), trainset())

    assert_received {:grpo_step, _opts}
    resumed = %{first | trainer: trainer(context, :ok)}

    assert {:error,
            {:grpo_step_recovery_ambiguous, ^step_id,
             %{fulfilled_batch_ids: [1], intended_batch_ids: [1, 2], pending_batch_ids: [2]}}} =
             Imp.Optimizer.GRPO.compile(resumed, program(), trainset())

    refute_received {:grpo_step, _opts}
    refute_received :grpo_terminate
    assert File.regular?(context.path)
  end

  test "checkpoint resume rejects every training-semantic identity drift", context do
    first = optimizer(trainer(context, :accepted_then_hang), context.path, num_train_steps: 0)

    assert {:error, {:reinforcement_callback_timeout, :start_reinforcement, 25}} =
             Imp.Optimizer.GRPO.compile(first, program(), trainset())

    variants = [
      %{first | variably_invoked_predictor_grouping_mode: :ragged},
      %{
        first
        | variably_invoked_predictor_grouping_mode: :fill,
          variably_invoked_predictor_fill_strategy: :max
      },
      %{first | failure_score: 0.25},
      %{first | format_failure_score: -2.0},
      %{first | reward_fn: reward(0.5)},
      %{
        first
        | validation_fn:
            Imp.Optimizer.GRPO.Callback.validation(
              Imp.Test.StableGRPOCallbacks,
              :validate,
              id: "test-validation-v1",
              config: %{"result" => "ok"}
            )
      },
      %{first | num_steps_for_val: 3},
      %{first | report_train_scores: true, use_train_as_val: true},
      %{first | train_kwargs: [learning_rate: 0.001]},
      %{first | trainer: %{trainer(context, :ok) | identity: :other_provider}}
    ]

    for variant <- variants do
      assert {:error, {:grpo_checkpoint_failed, "GRPO session checkpoint identity mismatch"}} =
               Imp.Optimizer.GRPO.compile(variant, program(), trainset())
    end
  end

  test "all-generated-groups mode resumes two predictors by two rows without stale carryover",
       context do
    program = two_predictor_program()
    trainset = two_row_trainset()

    first =
      optimizer(trainer(context, :all_groups_accept_then_hang), context.path,
        num_train_steps: 2,
        num_dspy_examples_per_grpo_step: 2,
        num_rollouts_per_grpo_step: 2
      )

    assert {:error, {:grpo_step_outcome_unknown, step_id, _timeout}} =
             Imp.Optimizer.GRPO.compile(first, program, trainset)

    assert_received {:grpo_step_batches, first_groups}
    assert length(first_groups) == 4
    assert Enum.all?(first_groups, &(&1.selection_step == 0))
    assert MapSet.new(Enum.map(first_groups, & &1.predictor)) == MapSet.new([:first, :second])
    assert MapSet.size(MapSet.new(Enum.map(first_groups, & &1.batch_id))) == 4
    assert Enum.all?(first_groups, &String.starts_with?(&1.batch_id, "imp-grpo-group:"))

    assert %{phase: :running, data: %{next_step: 0, step_intent: %{id: ^step_id}}} =
             Imp.Optimizer.GRPO.Checkpoint.load!(context.path)

    resumed = %{first | trainer: trainer(context, :all_groups_ok)}
    assert {:ok, compiled} = Imp.Optimizer.GRPO.compile(resumed, program, trainset)
    assert_received {:grpo_step_batches, second_groups}
    refute_received {:grpo_step_batches, _third_groups}

    assert length(second_groups) == 4
    assert Enum.all?(second_groups, &(&1.selection_step == 1))
    assert MapSet.new(Enum.map(second_groups, & &1.predictor)) == MapSet.new([:first, :second])
    assert MapSet.size(MapSet.new(Enum.map(second_groups, & &1.batch_id))) == 4

    refute MapSet.disjoint?(
             MapSet.new(Enum.map(first_groups, & &1.source_row_sha256)),
             MapSet.new(Enum.map(second_groups, & &1.source_row_sha256))
           )

    assert Enum.all?(TwoPredictorProgram.optimizer_predictors(compiled), fn {_name, predictor} ->
             predictor.lm.model == "trained/durable-grpo"
           end)

    refute File.exists?(context.path)
  end

  defp trainer(context, mode),
    do: %DurableTrainer{owner: self(), state: context.state, runtime_mode: mode}

  defp optimizer(trainer, checkpoint_path, opts) do
    Imp.Optimizer.GRPO.new(
      reward(1.0),
      Keyword.merge(
        [
          trainer: trainer,
          checkpoint_path: checkpoint_path,
          callback_timeout_ms: 25,
          status_poll_interval_ms: 0,
          num_rollouts_per_grpo_step: 1
        ],
        opts
      )
    )
  end

  defp reward(value) do
    Imp.Optimizer.GRPO.Callback.reward(Imp.Test.StableGRPOCallbacks, :reward,
      id: "test-reward-v1",
      config: %{"value" => value}
    )
  end

  defp program do
    lm =
      Imp.LM.Static.new(model: "base-model", handler: fn _messages, _opts -> %{answer: "ok"} end)

    Imp.predict("question -> answer", lm: lm)
  end

  defp slow_program(sleep_ms) do
    lm =
      Imp.LM.Static.new(
        model: "base-model",
        handler: fn _messages, _opts ->
          Process.sleep(sleep_ms)
          %{answer: "ok"}
        end
      )

    Imp.predict("question -> answer", lm: lm)
  end

  defp two_predictor_program do
    lm =
      Imp.LM.Static.new(
        model: "base-model",
        handler: fn _messages, _opts -> %{first_answer: "one", second_answer: "two"} end
      )

    %TwoPredictorProgram{
      first: Imp.predict("question -> first_answer", lm: lm),
      second: Imp.predict("question -> second_answer", lm: lm)
    }
  end

  defp two_row_trainset do
    for question <- ["alpha", "beta"] do
      Imp.example(question: question, first_answer: "one", second_answer: "two")
      |> Imp.with_inputs(:question)
    end
  end

  defp trainset,
    do: [Imp.example(question: "q", answer: "ok") |> Imp.with_inputs(:question)]

  defp trainset(question),
    do: [Imp.example(question: question, answer: "ok") |> Imp.with_inputs(:question)]
end

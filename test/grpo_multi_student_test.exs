defmodule GRPOMultiStudentTest do
  use ExUnit.Case

  alias Imp.Clients.{ReinforcementSession, TrainingJob}
  alias Imp.Optimizer.{GRPO, TrainingResult}

  defmodule StudentLM do
    @behaviour Imp.LM
    defstruct [:model, :output]

    @impl true
    def generate(_messages, _opts), do: {:error, :student_lm_instance_required}

    def generate(%__MODULE__{output: output}, _messages, _opts), do: {:ok, output}
  end

  defmodule Program do
    @behaviour Imp.Module

    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

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

  defmodule Trainer do
    @behaviour Imp.Clients.Trainer

    defstruct [:owner, :state, :runtime_mode, identity: :multi_student_fixture]

    @impl true
    def supported_methods(_trainer), do: [:grpo]

    @impl true
    def start_reinforcement(trainer, lm, opts) do
      model = lm.model
      dispatch_id = Keyword.fetch!(opts, :dispatch_id)
      send(trainer.owner, {:multi_start, model, dispatch_id})

      session =
        ReinforcementSession.new(%{
          id: "session:#{model}",
          provider: :fixture,
          model: lm,
          pending_batch_ids: ["batch:#{model}"],
          backend_state: %{dispatch_id: dispatch_id}
        })

      put_session(trainer.state, dispatch_id, session)
      {:ok, session}
    end

    @impl true
    def reconcile_reinforcement(trainer, dispatch_id) do
      send(trainer.owner, {:multi_reconcile, dispatch_id})

      case Agent.get(trainer.state, &Map.fetch(&1, dispatch_id)) do
        {:ok, session} -> {:ok, session}
        :error -> {:error, :reinforcement_session_not_found}
      end
    end

    @impl true
    def reinforcement_status(_trainer, session), do: {:ok, session}

    @impl true
    def reinforcement_step(trainer, session, batches, _opts) do
      model = session.model.model
      send(trainer.owner, {:multi_step, model, batches})

      if trainer.runtime_mode == {:reject, model} do
        {:error, {:reinforcement_step_not_accepted, {:rejected, model}}}
      else
        artifact = "trained/#{model}"
        ids = Enum.map(batches, & &1.batch_id)

        updated =
          session
          |> ReinforcementSession.fulfill(ids)
          |> Map.put(:current_model, artifact)
          |> Map.put(:result_model, artifact)
          |> Map.put(:metadata, %{
            artifact_sha256: "artifact:#{model}",
            checkpoint_sha256: "checkpoint:#{model}"
          })

        put_session(trainer.state, session.backend_state.dispatch_id, updated)

        if trainer.runtime_mode == {:accept_then_hang, model}, do: Process.sleep(1_000)
        {:ok, updated}
      end
    end

    @impl true
    def terminate_reinforcement(trainer, session) do
      model = session.model.model
      send(trainer.owner, {:multi_terminate, model})
      terminated = %{session | status: :succeeded, pending_batch_ids: []}
      put_session(trainer.state, session.backend_state.dispatch_id, terminated)
      {:ok, terminated}
    end

    @impl true
    def final_model_artifact(_trainer, session), do: {:ok, session.result_model}

    defp put_session(state, dispatch_id, session),
      do: Agent.update(state, &Map.put(&1, dispatch_id, session))
  end

  setup do
    state = start_supervised!({Agent, fn -> %{} end})

    checkpoint =
      Path.join(
        System.tmp_dir!(),
        "imp-grpo-multi-student-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn ->
      checkpoint
      |> Path.dirname()
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, Path.basename(checkpoint)))
      |> Enum.each(&File.rm(Path.join(Path.dirname(checkpoint), &1)))
    end)

    %{state: state, checkpoint: checkpoint}
  end

  test "distinct student LMs receive independent predictor groups, artifacts, and public jobs",
       context do
    optimizer = optimizer(trainer(context, :normal), nil)

    assert {:ok,
            %TrainingResult{status: :completed, job: nil, jobs: jobs, program: compiled} = result} =
             Imp.train(program(), optimizer, trainset())

    assert length(jobs) == 2
    assert Enum.all?(jobs, &match?(%TrainingJob{status: :succeeded}, &1))
    assert Enum.map(jobs, & &1.model) == ["base-a", "base-b"]
    assert Enum.map(jobs, & &1.result_model) == ["trained/base-a", "trained/base-b"]
    assert result.metadata == %{method: :grpo, student_lms: 2}

    assert_received {:multi_start, "base-a", first_dispatch}
    assert_received {:multi_step, "base-a", first_batches}
    assert_received {:multi_terminate, "base-a"}
    assert_received {:multi_start, "base-b", second_dispatch}
    assert_received {:multi_step, "base-b", second_batches}
    assert_received {:multi_terminate, "base-b"}
    refute first_dispatch == second_dispatch

    assert MapSet.new(Enum.map(first_batches, & &1.predictor)) == MapSet.new([:first])
    assert MapSet.new(Enum.map(second_batches, & &1.predictor)) == MapSet.new([:second])

    assert compiled.first.lm.model == "trained/base-a"
    assert compiled.second.lm.model == "trained/base-b"

    first_artifact = Imp.ProgramAccess.get_metadata(compiled.first, :training_artifact)
    second_artifact = Imp.ProgramAccess.get_metadata(compiled.second, :training_artifact)
    assert first_artifact.predictors == [:first]
    assert second_artifact.predictors == [:second]
    refute first_artifact.session_id == second_artifact.session_id
    refute first_artifact.result_model == second_artifact.result_model
  end

  test "a later student failure terminates every session that was started", context do
    optimizer = optimizer(trainer(context, {:reject, "base-b"}), nil)

    assert {:error, {:rejected, "base-b"}} =
             GRPO.compile(optimizer, program(), trainset())

    assert_received {:multi_terminate, "base-a"}
    assert_received {:multi_terminate, "base-b"}
    refute_received {:multi_start, "trained/base-a", _dispatch}
  end

  test "durable resume reuses the completed first artifact and reconciles only the active student",
       context do
    first =
      optimizer(trainer(context, {:accept_then_hang, "base-b"}), context.checkpoint,
        callback_timeout_ms: 25
      )

    assert {:error,
            {:grpo_step_outcome_unknown, _step_id,
             {:reinforcement_callback_timeout, :reinforcement_step, 25}}} =
             GRPO.compile(first, program(), trainset())

    assert_received {:multi_start, "base-a", first_dispatch}
    assert_received {:multi_terminate, "base-a"}
    assert_received {:multi_start, "base-b", second_dispatch}
    refute first_dispatch == second_dispatch
    refute_received {:multi_terminate, "base-b"}
    assert File.regular?(context.checkpoint)

    resumed = %{first | trainer: trainer(context, :normal)}
    assert {:ok, compiled} = GRPO.compile(resumed, program(), trainset())

    assert_received {:multi_reconcile, ^second_dispatch}
    refute_received {:multi_reconcile, ^first_dispatch}
    refute_received {:multi_start, "base-a", _dispatch}
    refute_received {:multi_start, "base-b", _dispatch}
    assert_received {:multi_terminate, "base-b"}

    assert compiled.first.lm.model == "trained/base-a"
    assert compiled.second.lm.model == "trained/base-b"
    refute File.exists?(context.checkpoint)

    refute Enum.any?(File.ls!(Path.dirname(context.checkpoint)), fn entry ->
             String.starts_with?(entry, Path.basename(context.checkpoint) <> ".student-")
           end)
  end

  test "durable resume rejects student topology drift before reconciling a session", context do
    first =
      optimizer(trainer(context, {:accept_then_hang, "base-b"}), context.checkpoint,
        callback_timeout_ms: 25
      )

    assert {:error, {:grpo_step_outcome_unknown, _step_id, _reason}} =
             GRPO.compile(first, program(), trainset())

    flush_messages()
    drifted = put_in(program().second.lm.model, "base-c")
    resumed = %{first | trainer: trainer(context, :normal)}

    assert {:error, :grpo_multi_student_checkpoint_identity_mismatch} =
             GRPO.compile(resumed, drifted, trainset())

    refute_received {:multi_reconcile, _dispatch}
    assert File.regular?(context.checkpoint)
  end

  defp optimizer(trainer, checkpoint, opts \\ []) do
    reward =
      Imp.Optimizer.GRPO.Callback.reward(Imp.Test.StableGRPOCallbacks, :reward,
        id: "multi-student-reward-v1",
        config: %{"value" => 1.0}
      )

    GRPO.new(
      reward,
      Keyword.merge(
        [
          trainer: trainer,
          checkpoint_path: checkpoint,
          num_train_steps: 1,
          num_rollouts_per_grpo_step: 2,
          status_poll_interval_ms: 0
        ],
        opts
      )
    )
  end

  defp trainer(context, mode),
    do: %Trainer{owner: self(), state: context.state, runtime_mode: mode}

  defp program do
    %Program{
      first:
        Imp.predict("question -> first_answer",
          lm: %StudentLM{model: "base-a", output: %{first_answer: "one"}}
        ),
      second:
        Imp.predict("question -> second_answer",
          lm: %StudentLM{model: "base-b", output: %{second_answer: "two"}}
        )
    }
  end

  defp trainset do
    [
      Imp.example(question: "alpha", first_answer: "one", second_answer: "two")
      |> Imp.with_inputs(:question)
    ]
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end
end

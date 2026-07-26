defmodule Imp.Optimizer.GRPO do
  @behaviour Imp.Optimizer
  @moduledoc """
  Provider-neutral, iterative module-level mmGRPO compilation.

  Groups align calls by `{predictor, relative invocation}` across rollouts and
  propagate the program-level reward to each aligned completion. A trainer owns
  only the reinforcement session lifecycle and model artifact. Optional durable
  session checkpoints reconcile accepted dispatches after caller crashes and
  resume completed optimizer steps. Provider callbacks execute under explicit
  deadlines in isolated unlinked tasks, so callback implementations must not
  rely on the caller's process dictionary or mailbox. Independent jobs for
  multiple student LMs are not implemented.

  Durable jobs require `Imp.Optimizer.GRPO.Callback` values for reward and
  validation logic. They bind a trusted module/function to a consumer-owned
  versioned id and JSON-safe configuration digest. Bare functions remain
  available only when `checkpoint_path` is absent; Imp refuses them before
  trainer activity rather than persisting compiler-local function identity as
  a false restart contract.

  `timeout` bounds each per-example rollout and validation evaluation (default
  5000ms) and is a BEAM-native execution option: pass a larger value or
  `:infinity` when rollouts are slow — agentic or environment-backed programs
  routinely run for minutes and would otherwise be killed at the 5s default.
  """

  alias Imp.Clients.{ReinforcementSession, Trainer, TrainingJob, TRLProtocol}
  alias Imp.Optimizer.{GRPO.Callback, GRPO.Checkpoint, Sampling, TrajectoryRunner}

  defstruct [
    :reward_fn,
    :trainer,
    :validation_fn,
    num_train_steps: 100,
    seed: 0,
    num_dspy_examples_per_grpo_step: 1,
    num_rollouts_per_grpo_step: 1,
    use_train_as_val: false,
    num_steps_for_val: 5,
    report_train_scores: false,
    failure_score: 0.0,
    format_failure_score: -1.0,
    variably_invoked_predictor_grouping_mode: :truncate,
    variably_invoked_predictor_fill_strategy: nil,
    status_poll_interval_ms: 1_000,
    max_status_polls: 300,
    callback_timeout_ms: 30_000,
    checkpoint_path: nil,
    train_kwargs: [],
    timeout: 5_000
  ]

  @option_schema [
    trainer: [type: {:custom, __MODULE__, :validate_trainer, []}, default: nil],
    validation_fn: [
      type: {:custom, __MODULE__, :validate_validation_callback, []},
      default: nil
    ],
    num_train_steps: [type: :non_neg_integer, default: 100],
    seed: [type: :integer, default: 0],
    num_dspy_examples_per_grpo_step: [type: :pos_integer, default: 1],
    num_rollouts_per_grpo_step: [type: :pos_integer, default: 1],
    use_train_as_val: [type: :boolean, default: false],
    num_steps_for_val: [type: :pos_integer, default: 5],
    report_train_scores: [type: :boolean, default: false],
    failure_score: [type: {:or, [:integer, :float]}, default: 0.0],
    format_failure_score: [type: {:or, [:integer, :float]}, default: -1.0],
    variably_invoked_predictor_grouping_mode: [
      type: {:in, [:truncate, :fill, :ragged]},
      default: :truncate
    ],
    variably_invoked_predictor_fill_strategy: [
      type: {:or, [{:in, [:randint, :max]}, nil]},
      default: nil
    ],
    status_poll_interval_ms: [type: :non_neg_integer, default: 1_000],
    max_status_polls: [type: :pos_integer, default: 300],
    callback_timeout_ms: [
      type: {:custom, __MODULE__, :validate_callback_timeout, []},
      default: 30_000
    ],
    checkpoint_path: [type: {:or, [:string, nil]}, default: nil],
    train_kwargs: [type: :keyword_list, default: []],
    timeout: [type: {:or, [:timeout, :pos_integer]}, default: 5_000]
  ]

  def new(reward_fn, opts \\ []) do
    validate_reward!(reward_fn)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.GRPO.new/2")

    if opts[:failure_score] <= opts[:format_failure_score] do
      raise ArgumentError,
            "Imp.Optimizer.GRPO.new/2 requires failure_score > format_failure_score"
    end

    if opts[:use_train_as_val] and not opts[:report_train_scores] do
      raise ArgumentError,
            "Imp.Optimizer.GRPO.new/2 requires report_train_scores when use_train_as_val is true"
    end

    if opts[:variably_invoked_predictor_grouping_mode] == :fill and
         is_nil(opts[:variably_invoked_predictor_fill_strategy]) do
      raise ArgumentError,
            "Imp.Optimizer.GRPO.new/2 requires a fill strategy when grouping mode is :fill"
    end

    struct!(__MODULE__, Keyword.put(opts, :reward_fn, reward_fn))
  end

  @doc false
  def validate_callback_timeout(:infinity), do: {:ok, :infinity}

  def validate_callback_timeout(timeout) when is_integer(timeout) and timeout > 0,
    do: {:ok, timeout}

  def validate_callback_timeout(_timeout),
    do: {:error, "expected :infinity or a positive integer"}

  @doc false
  def validate_validation_callback(nil), do: {:ok, nil}
  def validate_validation_callback(callback) when is_function(callback, 3), do: {:ok, callback}

  def validate_validation_callback(%Callback{kind: :validation} = callback),
    do: {:ok, callback}

  def validate_validation_callback(_callback),
    do: {:error, "expected nil, an arity-three function, or a stable GRPO validation callback"}

  @doc false
  def validate_trainer(trainer) when is_function(trainer) do
    {:error,
     "expected nil or a trainer module or struct implementing the GRPO reinforcement lifecycle"}
  end

  def validate_trainer(trainer), do: Trainer.validate_provider(trainer)

  @impl true
  def __optimizer__,
    do: %{
      kind: :training,
      datasets: %{trainset: :required, validation: :optional},
      result: :training_result
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    compile_opts =
      opts
      |> Imp.Optimizer.invocation_options()
      |> maybe_put_validation(opts)

    with :ok <- Imp.Optimizer.reject_options(Keyword.drop(compile_opts, [:valset])),
         {:ok, compiled} <-
           compile(
             optimizer,
             program,
             Imp.Optimizer.fetch_dataset!(opts, :trainset),
             compile_opts
           ) do
      {:ok,
       %Imp.Optimizer.TrainingResult{
         program: compiled,
         job: completed_training_job(compiled),
         status: :completed,
         metadata: %{method: :grpo}
       }}
    end
  end

  def compile(%__MODULE__{} = optimizer, program, trainset),
    do: compile(optimizer, program, trainset, [])

  def compile(%__MODULE__{trainer: nil}, _program, _trainset, _opts),
    do: {:error, :trainer_required}

  def compile(%__MODULE__{} = optimizer, program, trainset, opts) when is_list(opts) do
    with {:ok, trainset} <- materialize_dataset(trainset, :trainset),
         {:ok, valset} <- materialize_dataset(Keyword.get(opts, :valset), :valset),
         :ok <- validate_compile_inputs(optimizer, program, trainset, valset),
         :ok <- validate_durable_callbacks(optimizer),
         :ok <- Trainer.supports_method(optimizer.trainer, :grpo),
         lm <- program_lm(program),
         identity <- checkpoint_identity(optimizer, lm, trainset, valset),
         {:ok, session, resume_data, resumed?, dispatch_id} <-
           acquire_session(optimizer, lm, identity) do
      run_started_session(
        optimizer,
        program,
        trainset,
        valset,
        session,
        Map.put(identity, :dispatch_id, dispatch_id),
        resume_data,
        resumed?
      )
    end
  end

  def compile(%__MODULE__{}, _program, _trainset, opts),
    do:
      raise(
        ArgumentError,
        "Imp.Optimizer.GRPO.compile/4 expects keyword options, got: #{inspect(opts)}"
      )

  defp maybe_put_validation(compile_opts, opts) do
    if Keyword.has_key?(opts, :validation),
      do: Keyword.put(compile_opts, :valset, Keyword.fetch!(opts, :validation)),
      else: compile_opts
  end

  defp materialize_dataset(nil, :valset), do: {:ok, nil}
  defp materialize_dataset(dataset, _name) when is_list(dataset), do: {:ok, dataset}

  defp materialize_dataset(dataset, name) do
    if Enumerable.impl_for(dataset) do
      {:ok, Enum.to_list(dataset)}
    else
      {:error, invalid_dataset_reason(name)}
    end
  rescue
    _error -> {:error, invalid_dataset_reason(name)}
  catch
    _kind, _reason -> {:error, invalid_dataset_reason(name)}
  end

  defp invalid_dataset_reason(:trainset), do: :invalid_grpo_trainset
  defp invalid_dataset_reason(:valset), do: :invalid_grpo_valset

  defp acquire_session(%{checkpoint_path: path} = optimizer, lm, identity)
       when is_binary(path) do
    if File.regular?(path) do
      checkpoint = Checkpoint.load!(path)
      verify_checkpoint_identity!(checkpoint.data, identity)
      dispatch_id = Map.fetch!(checkpoint.data, :dispatch_id)

      case bounded_callback(optimizer, :reconcile_reinforcement, fn ->
             Trainer.reconcile_reinforcement(optimizer.trainer, dispatch_id)
           end) do
        {:ok, %ReinforcementSession{} = session} ->
          resume_data =
            if checkpoint.phase == :dispatch_intent,
              do: nil,
              else: Map.put(checkpoint.data, :checkpoint_phase, checkpoint.phase)

          {:ok, session, resume_data, true, dispatch_id}

        {:error, :reinforcement_session_not_found} when checkpoint.phase == :dispatch_intent ->
          start_session(optimizer, lm, identity, dispatch_id)

        {:error, reason} ->
          {:error, {:grpo_session_reconciliation_failed, dispatch_id, reason}}
      end
    else
      dispatch_id = new_dispatch_id(identity)
      Checkpoint.save!(path, :dispatch_intent, %{dispatch_id: dispatch_id, identity: identity})
      start_session(optimizer, lm, identity, dispatch_id)
    end
  rescue
    error -> {:error, {:grpo_checkpoint_failed, Exception.message(error)}}
  end

  defp acquire_session(optimizer, lm, identity) do
    dispatch_id = new_dispatch_id(identity)
    start_session(optimizer, lm, identity, dispatch_id)
  end

  defp start_session(optimizer, lm, identity, dispatch_id) do
    opts =
      optimizer.train_kwargs
      |> Keyword.put(:num_generations, optimizer.num_rollouts_per_grpo_step)
      |> Keyword.put(:imp_reinforcement_contract, reinforcement_contract(identity))
      |> maybe_put_dispatch_id(optimizer.checkpoint_path, dispatch_id)

    case bounded_callback(optimizer, :start_reinforcement, fn ->
           Trainer.start_reinforcement(optimizer.trainer, lm, opts)
         end) do
      {:ok, %ReinforcementSession{} = session} ->
        maybe_checkpoint(optimizer, :running, %{
          dispatch_id: dispatch_id,
          identity: identity,
          next_step: 0,
          session: session_summary(session)
        })

        {:ok, session, nil, false, dispatch_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_dispatch_id(opts, path, dispatch_id) when is_binary(path),
    do: Keyword.put_new(opts, :dispatch_id, dispatch_id)

  defp maybe_put_dispatch_id(opts, _path, _dispatch_id), do: opts

  defp run_started_session(
         optimizer,
         program,
         trainset,
         valset,
         session,
         identity,
         resume_data,
         resumed?
       ) do
    trainset = repeat_short_trainset(trainset, optimizer.num_dspy_examples_per_grpo_step)

    {initial_state, next_step} =
      restore_or_initialize_state(program, session, optimizer.seed, resume_data)

    result =
      cond do
        resume_data && resume_data[:checkpoint_phase] in [:terminating, :termination_failed] ->
          {:ok, initial_state}

        resume_data && is_map(resume_data[:step_intent]) ->
          safely_resume_step_intent(
            optimizer,
            trainset,
            valset,
            initial_state,
            resume_data[:step_intent],
            identity
          )

        true ->
          try do
            with :ok <-
                   maybe_initial_validation(
                     optimizer,
                     initial_state.program,
                     trainset,
                     valset,
                     next_step
                   ),
                 {:ok, state} <-
                   run_steps(
                     optimizer,
                     trainset,
                     valset,
                     initial_state,
                     next_step,
                     identity
                   ) do
              {:ok, state}
            end
          rescue
            error -> {:error, {:grpo_execution_failed, Exception.message(error)}}
          catch
            kind, reason -> {:error, {:grpo_execution_failed, {kind, reason}}}
          end
      end

    case result do
      {:ok, state} ->
        maybe_checkpoint(
          optimizer,
          :terminating,
          checkpoint_data(state, identity, optimizer.num_train_steps)
        )

        case terminate_session(optimizer, state.session) do
          {:ok, terminated} ->
            with {:ok, artifact} <-
                   bounded_callback(optimizer, :final_model_artifact, fn ->
                     Trainer.final_model_artifact(optimizer.trainer, terminated)
                   end),
                 {:ok, rebound} <-
                   rebind_program(state.program, artifact, terminated, resumed?) do
              Checkpoint.remove(optimizer.checkpoint_path)
              {:ok, rebound}
            end

          {:error, reason} ->
            maybe_checkpoint(
              optimizer,
              :termination_failed,
              checkpoint_data(state, identity, optimizer.num_train_steps)
              |> Map.put(:termination_error, reason)
            )

            {:error, {:grpo_termination_failed, reason}}
        end

      {:error, reason, state} ->
        terminate_after_failure(optimizer, state, identity, reason)

      {:step_outcome_unknown, reason} ->
        {:error, reason}

      {:error, reason} ->
        terminate_after_failure(optimizer, initial_state, identity, reason)
    end
  end

  defp run_steps(%{num_train_steps: count}, _trainset, _valset, state, next_step, _identity)
       when next_step >= count,
       do: {:ok, state}

  defp run_steps(optimizer, trainset, valset, state, next_step, identity) do
    Enum.reduce_while(next_step..(optimizer.num_train_steps - 1), {:ok, state}, fn step,
                                                                                   {:ok, state} ->
      case run_step(optimizer, trainset, valset, step, state, identity) do
        {:ok, state} ->
          maybe_checkpoint(optimizer, :running, checkpoint_data(state, identity, step + 1))
          {:cont, {:ok, state}}

        {:error, reason, state} ->
          {:halt, {:error, reason, state}}

        {:step_outcome_unknown, reason} ->
          {:halt, {:step_outcome_unknown, reason}}
      end
    end)
  end

  defp run_step(optimizer, trainset, valset, step, state, identity) do
    with {:ok, selected, state} <- select_examples(optimizer, trainset, step, state),
         {:ok, session} <- await_pending(optimizer, state.session, optimizer.max_status_polls) do
      state = %{state | session: session}

      with {:ok, groups, state} <- build_groups(optimizer, state.program, selected, step, state),
           {:ok, batches, state} <- assign_batches(groups, session, state),
           step_intent <- step_intent(identity, step, batches),
           :ok <- checkpoint_step_intent(optimizer, state, identity, step, step_intent),
           {:ok, stepped} <-
             submit_step(optimizer, session, Map.fetch!(step_intent, :batches), step_intent) do
        program = rebind_current_model(state.program, stepped.current_model)
        state = %{state | session: stepped, program: program}

        case maybe_validate(optimizer, program, trainset, valset, step) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end
      else
        {:step_outcome_unknown, reason} -> {:step_outcome_unknown, reason}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp submit_step(optimizer, session, batches, step_intent) do
    step_id = Map.fetch!(step_intent, :id)

    case bounded_callback(optimizer, :reinforcement_step, fn ->
           Trainer.reinforcement_step(optimizer.trainer, session, batches,
             step_id: step_id,
             idempotency_key: step_id
           )
         end) do
      {:ok, stepped} ->
        {:ok, stepped}

      {:error, {:reinforcement_step_not_accepted, reason}} ->
        {:error, reason}

      {:error, reason} ->
        # Once a mutating provider callback has been invoked, an ordinary error
        # cannot prove that the remote side rejected the request. Providers may
        # opt into the explicit not-accepted result above; every other failure is
        # reconciled from the durable intent before Imp decides whether to replay.
        {:step_outcome_unknown, {:grpo_step_outcome_unknown, step_id, reason}}
    end
  end

  defp checkpoint_step_intent(optimizer, state, identity, step, step_intent) do
    maybe_checkpoint(
      optimizer,
      :running,
      checkpoint_data(state, identity, step) |> Map.put(:step_intent, step_intent)
    )
  end

  defp step_intent(identity, step, batches) do
    # The persisted replay payload and the first submitted payload must be the
    # same credential-safe value. Sanitizing only while writing the checkpoint
    # would change its digest and make exact recovery impossible after a crash.
    batches = checkpoint_safe_batches(batches)
    batch_ids = Enum.map(batches, &fetch(&1, :batch_id))

    payload = %{
      dispatch_id: Map.fetch!(identity, :dispatch_id),
      step: step,
      batch_ids: batch_ids,
      batches_digest: digest(batches)
    }

    Map.merge(payload, %{id: "grpo-step:" <> digest(payload), batches: batches})
  end

  defp checkpoint_safe_batches(batches) do
    batches
    |> Imp.Optimizer.Report.encode_term()
    |> Imp.Redaction.redact()
    |> Imp.Optimizer.Report.decode_term()
  end

  defp resume_step_intent(optimizer, trainset, valset, state, intent, identity) do
    with :ok <- verify_step_intent(intent, identity),
         {:ok, refreshed} <-
           bounded_callback(optimizer, :reinforcement_status, fn ->
             Trainer.reinforcement_status(optimizer.trainer, state.session)
           end) do
      batch_ids = Map.fetch!(intent, :batch_ids)
      fulfilled = Enum.filter(batch_ids, &(&1 in refreshed.fulfilled_batch_ids))
      pending = Enum.filter(batch_ids, &(&1 in refreshed.pending_batch_ids))
      state = %{state | session: refreshed}

      cond do
        length(fulfilled) == length(batch_ids) ->
          complete_recovered_step(optimizer, trainset, valset, state, intent, identity)

        fulfilled == [] and length(pending) == length(batch_ids) ->
          case submit_step(optimizer, refreshed, Map.fetch!(intent, :batches), intent) do
            {:ok, stepped} ->
              state = %{state | session: stepped}
              complete_recovered_step(optimizer, trainset, valset, state, intent, identity)

            {:step_outcome_unknown, reason} ->
              {:step_outcome_unknown, reason}

            {:error, reason} ->
              {:error, reason, state}
          end

        true ->
          {:step_outcome_unknown,
           {:grpo_step_recovery_ambiguous, Map.fetch!(intent, :id),
            %{
              intended_batch_ids: batch_ids,
              fulfilled_batch_ids: fulfilled,
              pending_batch_ids: pending
            }}}
      end
    else
      {:error, reason} -> {:step_outcome_unknown, reason}
    end
  end

  defp safely_resume_step_intent(optimizer, trainset, valset, state, intent, identity) do
    resume_step_intent(optimizer, trainset, valset, state, intent, identity)
  rescue
    error -> {:error, {:grpo_execution_failed, Exception.message(error)}, state}
  catch
    kind, reason -> {:error, {:grpo_execution_failed, {kind, reason}}, state}
  end

  defp verify_step_intent(intent, identity) do
    payload = %{
      dispatch_id: Map.fetch!(identity, :dispatch_id),
      step: Map.fetch!(intent, :step),
      batch_ids: Map.fetch!(intent, :batch_ids),
      batches_digest: digest(Map.fetch!(intent, :batches))
    }

    expected = "grpo-step:" <> digest(payload)

    if Map.fetch!(intent, :id) == expected and
         Map.fetch!(intent, :batches_digest) == payload.batches_digest do
      :ok
    else
      {:error, :grpo_step_intent_integrity_mismatch}
    end
  rescue
    KeyError -> {:error, :invalid_grpo_step_intent}
  end

  defp complete_recovered_step(optimizer, trainset, valset, state, intent, identity) do
    step = Map.fetch!(intent, :step)
    program = rebind_current_model(state.program, state.session.current_model)
    state = %{state | program: program}

    case maybe_validate(optimizer, program, trainset, valset, step) do
      :ok ->
        maybe_checkpoint(optimizer, :running, checkpoint_data(state, identity, step + 1))
        run_steps(optimizer, trainset, valset, state, step + 1, identity)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp await_pending(_optimizer, _session, 0),
    do: {:error, :reinforcement_pending_batch_timeout}

  defp await_pending(optimizer, session, polls_left) do
    with {:ok, refreshed} <-
           bounded_callback(optimizer, :reinforcement_status, fn ->
             Trainer.reinforcement_status(optimizer.trainer, session)
           end) do
      available =
        Enum.reject(refreshed.pending_batch_ids, &(&1 in refreshed.fulfilled_batch_ids))

      if available == [] do
        Process.sleep(optimizer.status_poll_interval_ms)
        await_pending(optimizer, refreshed, polls_left - 1)
      else
        {:ok, %{refreshed | pending_batch_ids: available}}
      end
    end
  end

  defp restore_or_initialize_state(program, session, seed, nil) do
    {%{
       session: session,
       program: rebind_current_model(program, session.current_model),
       rng: seed_state(seed),
       shuffled_ids: [],
       frequencies: %{},
       frequency_order: [],
       epoch: -1,
       group_queue: []
     }, 0}
  end

  defp restore_or_initialize_state(program, session, seed, data)
       when not is_map_key(data, :rng) do
    restore_or_initialize_state(program, session, seed, nil)
  end

  defp restore_or_initialize_state(program, session, _seed, data) do
    {%{
       session: session,
       program: rebind_current_model(program, session.current_model),
       rng: data |> Map.fetch!(:rng) |> Sampling.load!(),
       shuffled_ids: Map.fetch!(data, :shuffled_ids),
       frequencies: Map.fetch!(data, :frequencies),
       frequency_order: Map.fetch!(data, :frequency_order),
       epoch: Map.fetch!(data, :epoch),
       group_queue: Map.fetch!(data, :group_queue)
     }, Map.fetch!(data, :next_step)}
  end

  defp maybe_initial_validation(_optimizer, _program, _trainset, _valset, next_step)
       when next_step > 0,
       do: :ok

  defp maybe_initial_validation(optimizer, program, trainset, valset, 0),
    do: maybe_validate(optimizer, program, trainset, valset, -1)

  defp checkpoint_data(state, identity, next_step) do
    %{
      dispatch_id: Map.fetch!(identity, :dispatch_id),
      identity: Map.delete(identity, :dispatch_id),
      next_step: next_step,
      session: session_summary(state.session),
      rng: Sampling.dump(state.rng),
      shuffled_ids: state.shuffled_ids,
      frequencies: state.frequencies,
      frequency_order: state.frequency_order,
      epoch: state.epoch,
      group_queue: state.group_queue
    }
  end

  defp session_summary(session) do
    %{
      id: session.id,
      provider: session.provider,
      status: session.status,
      pending_batch_ids: session.pending_batch_ids,
      fulfilled_batch_ids: session.fulfilled_batch_ids,
      current_model: session.current_model,
      result_model: session.result_model,
      metadata: session.metadata
    }
  end

  defp terminate_after_failure(optimizer, state, identity, execution_reason) do
    case terminate_session(optimizer, state.session) do
      {:ok, _terminated} ->
        Checkpoint.remove(optimizer.checkpoint_path)
        {:error, execution_reason}

      {:error, termination_reason} ->
        maybe_checkpoint(
          optimizer,
          :termination_failed,
          checkpoint_data(state, identity, 0)
          |> Map.put(:execution_error, execution_reason)
          |> Map.put(:termination_error, termination_reason)
        )

        {:error, {:grpo_execution_and_termination_failed, execution_reason, termination_reason}}
    end
  end

  defp terminate_session(optimizer, session) do
    bounded_callback(optimizer, :terminate_reinforcement, fn ->
      Trainer.terminate_reinforcement(optimizer.trainer, session)
    end)
  end

  defp bounded_callback(%{callback_timeout_ms: :infinity}, callback, fun) do
    normalize_callback_result(callback, fun.())
  rescue
    error -> {:error, {:reinforcement_callback_failed, callback, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:reinforcement_callback_exit, callback, {kind, reason}}}
  end

  defp bounded_callback(optimizer, callback, fun) do
    task = Task.Supervisor.async_nolink(Imp.UnlinkedTaskSupervisor, fun)

    case Task.yield(task, optimizer.callback_timeout_ms) do
      {:ok, result} ->
        normalize_callback_result(callback, result)

      {:exit, reason} ->
        {:error, {:reinforcement_callback_exit, callback, reason}}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, {:reinforcement_callback_timeout, callback, optimizer.callback_timeout_ms}}
    end
  rescue
    error -> {:error, {:reinforcement_callback_failed, callback, Exception.message(error)}}
  end

  defp normalize_callback_result(_callback, {:ok, _value} = result), do: result
  defp normalize_callback_result(_callback, {:error, _reason} = error), do: error

  defp normalize_callback_result(callback, other),
    do: {:error, {:invalid_reinforcement_callback_result, callback, other}}

  defp maybe_checkpoint(%{checkpoint_path: path}, phase, data) when is_binary(path),
    do: Checkpoint.save!(path, phase, data)

  defp maybe_checkpoint(_optimizer, _phase, _data), do: :ok

  defp checkpoint_identity(optimizer, lm, trainset, valset) do
    effective_trainset =
      repeat_short_trainset(trainset, optimizer.num_dspy_examples_per_grpo_step)

    identity = %{
      model: if(is_map(lm), do: Map.get(lm, :model, Map.get(lm, "model")), else: inspect(lm)),
      provider: compatibility_identity(optimizer.trainer),
      seed: optimizer.seed,
      num_train_steps: optimizer.num_train_steps,
      examples_per_step: optimizer.num_dspy_examples_per_grpo_step,
      rollouts_per_step: optimizer.num_rollouts_per_grpo_step,
      grouping: %{
        mode: optimizer.variably_invoked_predictor_grouping_mode,
        fill_strategy: optimizer.variably_invoked_predictor_fill_strategy
      },
      reward_policy: %{
        reward_fn: callback_identity(optimizer.reward_fn),
        failure_score: optimizer.failure_score,
        format_failure_score: optimizer.format_failure_score
      },
      validation_policy: %{
        validation_fn: callback_identity(optimizer.validation_fn),
        use_train_as_val: optimizer.use_train_as_val,
        num_steps_for_val: optimizer.num_steps_for_val,
        report_train_scores: optimizer.report_train_scores
      },
      train_kwargs: compatibility_identity(optimizer.train_kwargs),
      trainset: Enum.map(trainset, &Imp.Example.to_map/1),
      valset: if(is_list(valset), do: Enum.map(valset, &Imp.Example.to_map/1), else: nil),
      prompt_schedule: prompt_schedule(optimizer, effective_trainset)
    }

    Map.put(identity, :digest, digest(identity))
  end

  defp verify_checkpoint_identity!(data, identity) do
    saved = Map.fetch!(data, :identity)

    unless Map.fetch!(saved, :digest) == Map.fetch!(identity, :digest) do
      raise ArgumentError, "GRPO session checkpoint identity mismatch"
    end
  end

  defp new_dispatch_id(identity) do
    "grpo:" <>
      Map.fetch!(identity, :digest) <>
      ":" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp callback_identity(nil), do: nil
  defp callback_identity(%Callback{} = callback), do: Callback.identity(callback)

  defp callback_identity(callback) when is_function(callback) do
    [:module, :name, :arity, :type, :uniq, :index]
    |> Map.new(fn key -> {key, callback |> :erlang.fun_info(key) |> elem(1)} end)
    |> Map.put(
      :environment,
      callback |> :erlang.fun_info(:env) |> elem(1) |> compatibility_identity()
    )
  end

  defp compatibility_identity(%Callback{} = callback), do: Callback.identity(callback)

  defp compatibility_identity(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__imp_provider_module__, module)
    |> compatibility_identity()
  end

  defp compatibility_identity(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      cond do
        runtime_identity_key?(key) ->
          acc

        Imp.Redaction.credential_entry?(key, value) ->
          Map.put(acc, key, :credential_present)

        true ->
          Map.put(acc, key, compatibility_identity(value))
      end
    end)
  end

  defp compatibility_identity(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
      |> Enum.map(fn {key, value} ->
        if Imp.Redaction.credential_entry?(key, value) do
          {key, :credential_present}
        else
          {key, compatibility_identity(value)}
        end
      end)
      |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
    else
      Enum.map(list, &compatibility_identity/1)
    end
  end

  defp compatibility_identity(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&compatibility_identity/1)
    |> List.to_tuple()
  end

  defp compatibility_identity(callback) when is_function(callback),
    do: callback_identity(callback)

  defp compatibility_identity(value) when is_pid(value), do: :runtime_pid
  defp compatibility_identity(value) when is_port(value), do: :runtime_port
  defp compatibility_identity(value) when is_reference(value), do: :runtime_reference

  defp compatibility_identity(value) when is_binary(value) do
    if Imp.Redaction.redact(value) == value, do: value, else: :credential_present
  end

  defp compatibility_identity(value), do: value

  defp runtime_identity_key?(key) when is_atom(key) or is_binary(key) do
    normalized = key |> to_string() |> String.downcase()

    normalized in ~w(owner state transport dispatch_observer pid task process runtime) or
      String.starts_with?(normalized, "runtime_") or
      String.ends_with?(normalized, [
        "_pid",
        "_process",
        "_runtime",
        "_transport"
      ])
  end

  defp runtime_identity_key?(_key), do: false

  defp select_examples(optimizer, trainset, step, state) do
    width = optimizer.num_dspy_examples_per_grpo_step
    base = step * width
    epoch = if state.epoch == -1, do: 0, else: div(base, max(length(state.shuffled_ids), 1))

    {state, epoch} =
      if epoch > state.epoch do
        {ids, rng} = shuffle(Enum.to_list(0..(length(trainset) - 1)), state.rng)

        frequencies =
          Enum.reduce(ids, state.frequencies, &Map.update(&2, &1, 1, fn n -> n + 1 end))

        frequency_order =
          state.frequency_order ++ Enum.reject(ids, &(&1 in state.frequency_order))

        padding = width - rem(length(trainset), width)
        {ids, frequencies} = pad_ids(ids, frequencies, frequency_order, padding)

        {%{
           state
           | shuffled_ids: ids,
             frequencies: frequencies,
             frequency_order: frequency_order,
             epoch: epoch,
             rng: rng
         }, epoch}
      else
        {state, epoch}
      end

    base = rem(step * width, length(state.shuffled_ids))
    ids = Enum.slice(state.shuffled_ids, base, width)

    if length(ids) == width do
      {:ok, Enum.map(ids, &Enum.at(trainset, &1)), %{state | epoch: epoch}}
    else
      {:error, :invalid_grpo_selection_state}
    end
  end

  # This preserves the pinned implementation's extra full batch when the
  # dataset size is already divisible by the per-step width.
  defp pad_ids(ids, frequencies, frequency_order, count) do
    Enum.reduce(1..count, {ids, frequencies}, fn _, {ids, frequencies} ->
      selected =
        frequencies
        |> Enum.min_by(fn {id, frequency} ->
          {frequency, -Enum.find_index(frequency_order, &(&1 == id))}
        end)
        |> elem(0)

      {ids ++ [selected], Map.update!(frequencies, selected, &(&1 + 1))}
    end)
  end

  defp build_groups(optimizer, program, examples, step, state) do
    predictors = Imp.ProgramParameters.predictors(program)

    trajectories =
      for rollout <- 0..(optimizer.num_rollouts_per_grpo_step - 1),
          reduce: [] do
        acc ->
          rollout_program = bind_rollout(program, step, rollout)

          round =
            TrajectoryRunner.run(
              rollout_program,
              examples,
              trajectory_metric(optimizer.reward_fn),
              max_concurrency: 1,
              rollout_id: rollout,
              timeout: optimizer.timeout
            )
            |> Enum.with_index()
            |> Enum.map(fn {trajectory, example_index} ->
              %{trajectory: trajectory, rollout: rollout, example_index: example_index}
            end)

          acc ++ round
      end

    {groups, rng} =
      Enum.reduce(predictors, {[], state.rng}, fn predictor, acc ->
        Enum.reduce(Enum.with_index(examples), acc, fn {_example, example_index}, {groups, rng} ->
          rollouts =
            trajectories
            |> Enum.filter(&(&1.example_index == example_index))
            |> Enum.sort_by(& &1.rollout)

          {predictor_groups, rng} =
            groups_for_predictor(optimizer, predictor, rollouts, example_index, rng)

          {groups ++ predictor_groups, rng}
        end)
      end)

    if groups == [],
      do: {:error, :no_grpo_training_data},
      else: {:ok, groups, %{state | rng: rng}}
  end

  defp groups_for_predictor(
         optimizer,
         %{name: name, predictor: predictor},
         rollouts,
         example_index,
         rng
       ) do
    invocations =
      Enum.map(rollouts, fn %{trajectory: trajectory} ->
        matching = Enum.filter(trajectory.trace || [], &(fetch(&1, :predictor) == name))

        if matching == [] do
          failure_invocations(optimizer, predictor, trajectory)
        else
          Enum.map(matching, &successful_invocation(optimizer, predictor, trajectory, &1))
        end
      end)

    if invocations == [] or Enum.any?(invocations, &(&1 == [])) do
      {[], rng}
    else
      {invocations, rng} = normalize_invocation_counts(optimizer, invocations, rng)
      max_count = invocations |> Enum.map(&length/1) |> Enum.max()

      groups =
        for invocation_index <- 0..(max_count - 1),
            group = Enum.flat_map(invocations, &List.wrap(Enum.at(&1, invocation_index))),
            group != [] do
          group = pad_group(group, optimizer.num_rollouts_per_grpo_step)

          %{
            predictor: name,
            group_id: {example_index, name, invocation_index},
            group: group
          }
        end

      {groups, rng}
    end
  end

  defp normalize_invocation_counts(
         %{variably_invoked_predictor_grouping_mode: :truncate},
         lists,
         rng
       ) do
    count = lists |> Enum.map(&length/1) |> Enum.min()
    {Enum.map(lists, &Enum.take(&1, count)), rng}
  end

  defp normalize_invocation_counts(
         %{variably_invoked_predictor_grouping_mode: :ragged},
         lists,
         rng
       ),
       do: {lists, rng}

  defp normalize_invocation_counts(%{variably_invoked_predictor_fill_strategy: :max}, lists, rng) do
    count = lists |> Enum.map(&length/1) |> Enum.max()
    {Enum.map(lists, &fill_to(&1, count, List.last(&1))), rng}
  end

  defp normalize_invocation_counts(
         %{variably_invoked_predictor_fill_strategy: :randint},
         lists,
         rng
       ) do
    count = lists |> Enum.map(&length/1) |> Enum.max()

    Enum.map_reduce(lists, rng, fn list, rng ->
      if length(list) >= count do
        {list, rng}
      else
        Enum.reduce((length(list) + 1)..count, {list, rng}, fn _, {filled, rng} ->
          {index, rng} = uniform(length(list), rng)
          {filled ++ [Enum.at(list, index - 1)], rng}
        end)
      end
    end)
  end

  defp successful_invocation(_optimizer, predictor, trajectory, trace) do
    inputs = fetch(trace, :inputs, %{})
    outputs = fetch(trace, :outputs, %{})
    adapter = predictor_adapter(predictor)

    %{
      messages: normalize_messages(adapter.format(predictor.signature, inputs, demos: [])),
      completion: completion_message(adapter, predictor.signature, inputs, outputs),
      reward: trajectory.score * 1.0
    }
  end

  defp failure_invocations(optimizer, predictor, trajectory) do
    case failure_trace(trajectory.error) do
      %{messages: messages, raw: raw} ->
        [
          %{
            messages: normalize_messages(messages),
            completion: %{role: "assistant", content: completion_content(raw)},
            reward: optimizer.format_failure_score * 1.0
          }
        ]

      _other ->
        inputs = trajectory.example |> Imp.Example.inputs() |> Imp.Example.to_map()
        adapter = predictor_adapter(predictor)

        [
          %{
            messages: normalize_messages(adapter.format(predictor.signature, inputs, demos: [])),
            completion: %{role: "assistant", content: ""},
            reward: optimizer.failure_score * 1.0
          }
        ]
    end
  end

  defp assign_batches(groups, %ReinforcementSession{} = session, state) do
    available =
      Enum.reject(session.pending_batch_ids, &(&1 in session.fulfilled_batch_ids))

    {queue, rng} = refill_queue(state.group_queue, groups, length(available), state.rng)
    {selected, queue} = Enum.split(queue, length(available))

    batches =
      Enum.zip(available, selected)
      |> Enum.map(fn {batch_id, group} -> Map.put(group, :batch_id, batch_id) end)

    if batches == [],
      do: {:error, :no_pending_reinforcement_batches},
      else: {:ok, batches, %{state | group_queue: queue, rng: rng}}
  end

  defp refill_queue(queue, _groups, needed, rng) when length(queue) >= needed,
    do: {queue, rng}

  defp refill_queue(queue, groups, needed, rng) do
    {shuffled, rng} = shuffle(groups, rng)
    refill_queue(queue ++ shuffled, groups, needed, rng)
  end

  defp maybe_validate(optimizer, program, trainset, valset, step) do
    due? =
      step == -1 or step == optimizer.num_train_steps - 1 or
        rem(step + 1, optimizer.num_steps_for_val) == 0

    dataset = validation_dataset(optimizer, trainset, valset)

    if due? and dataset != [] do
      context = %{step: step, final?: step == optimizer.num_train_steps - 1}

      case optimizer.validation_fn do
        nil ->
          _ =
            TrajectoryRunner.run(program, dataset, trajectory_metric(optimizer.reward_fn),
              max_concurrency: 1,
              timeout: optimizer.timeout
            )

          :ok

        callback ->
          result =
            case callback do
              %Callback{} -> Callback.invoke(callback, program, dataset, context)
              fun -> fun.(program, dataset, context)
            end

          case result do
            :ok -> :ok
            {:ok, _result} -> :ok
            {:error, _reason} = error -> error
            other -> {:error, {:invalid_grpo_validation_result, other}}
          end
      end
    else
      :ok
    end
  end

  defp validation_dataset(%{report_train_scores: true}, trainset, valset) when is_list(valset),
    do: valset ++ trainset

  defp validation_dataset(_optimizer, _trainset, valset) when is_list(valset), do: valset
  defp validation_dataset(%{use_train_as_val: true}, trainset, nil), do: trainset
  defp validation_dataset(_optimizer, _trainset, nil), do: []

  defp validate_compile_inputs(optimizer, program, trainset, valset) do
    cond do
      not is_list(trainset) or trainset == [] ->
        {:error, :empty_grpo_trainset}

      Enum.any?(trainset, &(not match?(%Imp.Example{}, &1))) ->
        {:error, :invalid_grpo_trainset}

      not is_nil(valset) and not is_list(valset) ->
        {:error, :invalid_grpo_valset}

      is_list(valset) and Enum.any?(valset, &(not match?(%Imp.Example{}, &1))) ->
        {:error, :invalid_grpo_valset}

      optimizer.use_train_as_val and not is_nil(valset) ->
        {:error, :grpo_train_and_val_conflict}

      optimizer.report_train_scores and is_nil(valset) and not optimizer.use_train_as_val ->
        {:error, :grpo_train_scores_require_validation}

      Imp.ProgramParameters.predictors(program) == [] ->
        {:error, :grpo_predictor_required}

      Enum.any?(Imp.ProgramParameters.predictors(program), &is_nil(&1.predictor.lm)) ->
        {:error, :grpo_predictor_lm_required}

      unique_lms(program) != 1 ->
        {:error, :grpo_single_student_lm_required}

      true ->
        :ok
    end
  end

  defp rebind_program(program, artifact, session, resumed?) do
    training_artifact =
      %{
        provider: session.provider,
        session_id: session.id,
        base_model: lm_model(session.model),
        result_model: artifact,
        method: :grpo,
        resumed: resumed?
      }
      |> maybe_put_session_metadata(session.metadata, :artifact_sha256)
      |> maybe_put_session_metadata(session.metadata, :checkpoint_sha256)
      |> maybe_put_session_metadata(session.metadata, :protocol_payload_sha256)

    rebound =
      Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
        Imp.ProgramParameters.update_predictor(acc, name, fn predictor ->
          %{predictor | lm: rebind_lm(predictor.lm, artifact), dynamic_lm?: false}
        end)
      end)
      |> Imp.ProgramAccess.put_metadata(:training_artifact, training_artifact)

    {:ok, rebound}
  rescue
    error -> {:error, {:grpo_rebind_failed, Exception.message(error)}}
  end

  defp rebind_lm(%Imp.Clients.ReqLLM{} = lm, artifact), do: %{lm | model: artifact}
  defp rebind_lm(%{model: _} = lm, artifact), do: Map.put(lm, :model, artifact)
  defp rebind_lm(lm, artifact) when is_map(lm), do: Map.put(lm, :model, artifact)
  defp rebind_lm(_lm, _artifact), do: raise(ArgumentError, "student LM is not rebindable")

  defp rebind_current_model(program, nil), do: program

  defp rebind_current_model(program, model) when is_binary(model) and model != "" do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      Imp.ProgramParameters.update_predictor(acc, name, fn predictor ->
        %{predictor | lm: rebind_lm(predictor.lm, model), dynamic_lm?: false}
      end)
    end)
  end

  defp bind_rollout(program, step, rollout) do
    rollout_id = step * 1_000_000 + rollout

    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      Imp.ProgramParameters.update_predictor(acc, name, fn predictor ->
        %{predictor | config: Keyword.put(predictor.config, :rollout_id, rollout_id)}
      end)
    end)
  end

  defp completion_message(adapter, signature, inputs, outputs) do
    demo =
      inputs
      |> Map.merge(outputs)
      |> Imp.Example.new()

    adapter.format(signature, %{}, demos: [demo])
    |> Enum.find(&(message_role(&1) == "assistant"))
    |> normalize_message()
  end

  defp predictor_adapter(%{dynamic_adapter?: true}), do: Imp.Settings.get().adapter
  defp predictor_adapter(%{adapter: nil}), do: Imp.Settings.get().adapter
  defp predictor_adapter(%{adapter: adapter}), do: adapter

  defp normalize_messages(messages), do: Enum.map(messages, &normalize_message/1)

  defp normalize_message(message) do
    %{role: message_role(message), content: fetch(message, :content, "")}
  end

  defp message_role(message), do: message |> fetch(:role, "assistant") |> to_string()

  defp failure_trace(%{trace: trace}) when is_map(trace), do: trace
  defp failure_trace(%{"trace" => trace}) when is_map(trace), do: trace
  defp failure_trace(_error), do: nil

  defp completion_content(content) when is_binary(content), do: content
  defp completion_content(content), do: Jason.encode!(content)

  defp pad_group(group, size) when length(group) >= size, do: Enum.take(group, size)
  defp pad_group([], _size), do: []

  defp pad_group(group, size),
    do: pad_group(group ++ Enum.take(group, size - length(group)), size)

  defp fill_to(list, count, _item) when length(list) >= count, do: list
  defp fill_to(list, count, item), do: fill_to(list ++ [item], count, item)

  defp unique_lms(program) do
    program
    |> Imp.ProgramParameters.predictors()
    |> Enum.map(&:erlang.term_to_binary(&1.predictor.lm, [:deterministic]))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp program_lm(program),
    do:
      program
      |> Imp.ProgramParameters.predictors()
      |> hd()
      |> Map.fetch!(:predictor)
      |> Map.fetch!(:lm)

  defp repeat_short_trainset(trainset, width) when length(trainset) < width do
    multiplier = div(width + length(trainset) - 1, length(trainset))
    List.duplicate(trainset, multiplier) |> List.flatten()
  end

  defp repeat_short_trainset(trainset, _width), do: trainset

  defp prompt_schedule(%{num_train_steps: 0}, _trainset), do: []

  defp prompt_schedule(optimizer, trainset) do
    initial = %{
      rng: seed_state(optimizer.seed),
      shuffled_ids: [],
      frequencies: %{},
      frequency_order: [],
      epoch: -1
    }

    0..(optimizer.num_train_steps - 1)
    |> Enum.map_reduce(initial, fn step, state ->
      {:ok, examples, state} = select_examples(optimizer, trainset, step, state)

      {%{
         "step" => step,
         "ordered_row_sha256s" => Enum.map(examples, &protocol_digest(Imp.Example.to_map(&1)))
       }, state}
    end)
    |> elem(0)
  end

  defp reinforcement_contract(identity) do
    train_rows = Enum.map(identity.trainset, &protocol_digest/1)

    val_rows =
      if is_list(identity.valset), do: Enum.map(identity.valset, &protocol_digest/1), else: []

    %{
      "dataset" => %{
        "train_sha256" => protocol_digest(train_rows),
        "validation_sha256" => if(val_rows == [], do: nil, else: protocol_digest(val_rows)),
        "ordered_train_row_sha256s" => train_rows
      },
      "prompt_schedule" => %{
        "selector" => "imp_grpo_v1",
        "steps" => identity.prompt_schedule
      },
      "optimizer" => %{
        "name" => "grpo",
        "num_generations" => identity.rollouts_per_step,
        "config_sha256" =>
          identity
          |> Map.drop([:trainset, :valset, :prompt_schedule, :digest])
          |> protocol_digest()
      },
      "rng" => %{
        "algorithm" => "exsss",
        "state_sha256" => protocol_digest(Sampling.dump(seed_state(identity.seed)))
      }
    }
  end

  defp protocol_digest(value) do
    value
    |> Imp.Optimizer.Report.encode_term()
    |> TRLProtocol.digest()
  end

  defp maybe_put_session_metadata(metadata, session_metadata, key) do
    case Map.get(session_metadata, key, Map.get(session_metadata, Atom.to_string(key))) do
      value when is_binary(value) -> Map.put(metadata, key, value)
      _missing -> metadata
    end
  end

  defp completed_training_job(program) do
    artifact = Imp.ProgramAccess.get_metadata(program, :training_artifact) || %{}
    lm = Imp.ProgramAccess.lm(program)

    TrainingJob.new(%{
      id: Map.get(artifact, :session_id, "grpo-completed"),
      provider: Map.get(artifact, :provider, :local),
      model: Map.get(artifact, :base_model, lm_model(lm)),
      status: :succeeded,
      result_model: Map.get(artifact, :result_model),
      metadata:
        artifact
        |> Map.take([:artifact_sha256, :checkpoint_sha256, :protocol_payload_sha256])
        |> Map.put(:method, :grpo)
    })
  end

  defp lm_model(%{model: model}), do: model
  defp lm_model(%{"model" => model}), do: model
  defp lm_model(lm), do: inspect(lm)

  defp seed_state(seed) do
    value = abs(seed) + 1
    :rand.seed_s(:exsss, {value, value * 2 + 1, value * 3 + 7})
  end

  defp shuffle(list, rng) do
    Enum.reduce(Enum.reverse(1..length(list)), {list, rng}, fn
      index, {items, rng} when index > 1 ->
        {swap_index, rng} = uniform(index, rng)
        {swap(items, index - 1, swap_index - 1), rng}

      _index, state ->
        state
    end)
  end

  defp uniform(max, rng), do: :rand.uniform_s(max, rng)

  defp swap(list, index, index), do: list

  defp swap(list, left, right) do
    left_value = Enum.at(list, left)
    right_value = Enum.at(list, right)

    list
    |> List.replace_at(left, right_value)
    |> List.replace_at(right, left_value)
  end

  defp fetch(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp trajectory_metric(%Callback{kind: :reward} = callback),
    do: fn example, prediction -> Callback.invoke(callback, example, prediction) end

  defp trajectory_metric(reward_fn) when is_function(reward_fn, 3), do: reward_fn
  defp trajectory_metric(reward_fn) when is_function(reward_fn, 2), do: reward_fn
  defp trajectory_metric(reward_fn), do: fn example, _prediction -> reward_fn.(example) end

  defp validate_reward!(reward_fn) do
    unless match?(%Callback{kind: :reward}, reward_fn) or
             (is_function(reward_fn) and
                Enum.any?([1, 2, 3], &:erlang.is_function(reward_fn, &1))) do
      raise ArgumentError,
            "Imp.Optimizer.GRPO.new/2 expects a stable reward callback or a reward function with arity 1, 2, or 3"
    end
  end

  defp validate_durable_callbacks(%{checkpoint_path: nil}), do: :ok

  defp validate_durable_callbacks(%{reward_fn: %Callback{} = reward, validation_fn: nil}),
    do: Callback.validate(reward, :reward)

  defp validate_durable_callbacks(%{
         reward_fn: %Callback{} = reward,
         validation_fn: %Callback{} = validation
       }) do
    with :ok <- Callback.validate(reward, :reward),
         :ok <- Callback.validate(validation, :validation),
         do: :ok
  end

  defp validate_durable_callbacks(_optimizer),
    do: {:error, :stable_grpo_callbacks_required_for_checkpoint}
end

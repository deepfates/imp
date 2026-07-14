defmodule DSEx.Optimizer.GEPA.Engine do
  @moduledoc false

  alias DSEx.Optimizer.GEPA.{
    Acceptance,
    Adapter,
    Budget,
    BudgetLedger,
    Callback,
    Candidate,
    CandidateSelector,
    ComBee,
    Coordinator,
    Evaluation,
    EvaluationCache,
    EvaluationPolicy,
    Frontier,
    Merge,
    ModuleSelector,
    Proposal,
    Reflection,
    Result,
    Stopper
  }

  alias DSEx.Optimizer.GEPA.EvaluationCache.Disk, as: DiskEvaluationCache
  alias DSEx.Optimizer.Trajectory

  defmodule Entry do
    @moduledoc false
    @enforce_keys [:id, :candidate, :validation]
    defstruct [:id, :candidate, :validation, parent_ids: [], next_component: 0, discovered_at: 0]
  end

  defmodule State do
    @moduledoc false
    @enforce_keys [:budget, :rng_state]
    defstruct iteration: 0,
              candidates: [],
              rejected: [],
              history: [],
              cache: %{},
              budget: nil,
              rng_state: nil,
              merge_due: 0,
              total_merges_tested: 0,
              merge_attempts: %{ancestors: [], descriptions: []},
              last_iteration_found_candidate: false,
              frontier_type: :instance,
              evaluation_policy: EvaluationPolicy.Full,
              best_outputs_valset: nil,
              stopper_state: nil,
              budget_ledger: %BudgetLedger{},
              pending_proposal_batch: nil,
              proposal_policy: %{requested: 1, resolved: 1, timeout: :infinity},
              combee_policy: nil,
              combee_reports: [],
              stop_reason: nil
  end

  @type proposer ::
          (Candidate.t(), Candidate.component_name(), [map()], non_neg_integer() ->
             String.t() | {:ok, String.t()} | {:error, term()})
          | (Candidate.t(), Candidate.component_name(), [map()], non_neg_integer(), map() ->
               String.t() | {:ok, String.t()} | {:error, term()})

  @spec run(Adapter.t(), Candidate.t(), [term()], [term()], proposer(), keyword()) :: State.t()
  def run(adapter, seed_candidate, trainset, valset, proposer, opts \\ [])
      when is_list(trainset) and is_list(valset) and
             (is_function(proposer, 4) or is_function(proposer, 5)) and is_list(opts) do
    seed_candidate = Candidate.validate!(seed_candidate)
    validate_inputs!(seed_candidate, trainset, valset, opts)
    requested_minibatch_size = Keyword.get(opts, :minibatch_size, min(3, length(trainset)))

    combee_policy =
      ComBee.resolve(
        Keyword.get(opts, :combee, false),
        length(trainset),
        requested_minibatch_size,
        Keyword.get(opts, :seed, 0)
      )

    minibatch_size = combee_policy.effective_batch_size
    proposal_policy = proposal_policy(opts, minibatch_size)

    combee_policy =
      ComBee.resolve_concurrency(
        combee_policy,
        DSEx.Settings.snapshot() |> Map.fetch!(:async_max_workers),
        proposal_policy.resolved
      )
      |> ComBee.bound_timeout(proposal_policy.timeout)

    opts =
      opts
      |> Keyword.put(:proposal_policy, proposal_policy)
      |> Keyword.put(:combee_policy, combee_policy)
      |> Keyword.put(:effective_minibatch_size, minibatch_size)

    notify(opts, :on_optimization_start, %{
      seed_candidate: seed_candidate,
      trainset_size: length(trainset),
      valset_size: length(valset),
      config: callback_config(opts)
    })

    if combee_policy.batch_controller &&
         combee_policy.batch_controller.mode == :offline_measurements do
      notify(opts, :on_combee_batch_selected, %{
        policy_identity: combee_policy.identity,
        report: combee_policy.batch_controller
      })
    end

    state =
      case Keyword.get(opts, :resume_state) do
        nil -> initialize(adapter, seed_candidate, valset, opts)
        resume_state -> load_state!(resume_state, seed_candidate, opts)
      end

    state =
      state
      |> ensure_proposal_policy!(proposal_policy)
      |> ensure_combee_policy!(combee_policy)

    max_iterations = Keyword.get(opts, :max_iterations, 10)

    {state, opts, minibatch_size} =
      run_combee_profile(
        adapter,
        trainset,
        valset,
        proposer,
        requested_minibatch_size,
        max_iterations,
        state,
        opts
      )

    state =
      if proposal_policy.resolved == 1 and not combee_policy.enabled and
           is_nil(state.pending_proposal_batch) do
        run_sequential_loop(
          adapter,
          trainset,
          valset,
          proposer,
          minibatch_size,
          max_iterations,
          state,
          opts
        )
      else
        run_parallel_loop(
          adapter,
          trainset,
          valset,
          proposer,
          minibatch_size,
          max_iterations,
          state,
          opts
        )
      end

    state =
      if state.iteration >= max_iterations and is_nil(state.stop_reason),
        do: %{state | stop_reason: :max_iterations},
        else: state

    best = best(state)

    notify(opts, :on_optimization_end, %{
      best_candidate_idx: best.id,
      total_iterations: state.iteration,
      total_metric_calls: state.budget.metric_calls,
      final_state: state
    })

    state
  end

  defp run_combee_profile(
         adapter,
         trainset,
         valset,
         proposer,
         fallback_batch_size,
         max_iterations,
         state,
         opts
       ) do
    case state.combee_policy.batch_controller do
      %ComBee.BatchController.Report{mode: :runtime, status: :started} ->
        raise ArgumentError,
              "GEPA resume contains a started ComBee profiling trial with ambiguous external effects"

      %ComBee.BatchController.Report{mode: :runtime, status: status}
      when status in [:pending, :profiling] ->
        deadline = profile_deadline(state.combee_policy.batch_controller)

        profile_runtime_trials(
          adapter,
          trainset,
          valset,
          proposer,
          max_iterations,
          state,
          opts,
          deadline
        )

      %ComBee.BatchController.Report{mode: :runtime} = report ->
        {state, Keyword.put(opts, :combee_policy, state.combee_policy),
         selected_profile_batch(report, fallback_batch_size)}

      _ ->
        {state, opts, state.combee_policy.effective_batch_size || fallback_batch_size}
    end
  end

  defp profile_runtime_trials(
         adapter,
         trainset,
         valset,
         proposer,
         max_iterations,
         state,
         opts,
         deadline
       ) do
    report = state.combee_policy.batch_controller

    cond do
      state.stop_reason != nil ->
        profile_stopped(state, opts, report, state.stop_reason)

      profile_deadline_elapsed?(deadline) ->
        profile_stopped(state, opts, report, :profiling_timeout)

      is_nil(ComBee.BatchController.next_batch_size(report)) ->
        finish_profile(state, opts)

      state.iteration >= max_iterations ->
        profile_stopped(state, opts, report, :max_iterations)

      true ->
        batch_size = ComBee.BatchController.next_batch_size(report)
        iteration = state.iteration + 1
        started_report = ComBee.BatchController.start_trial(report, iteration)

        state = put_profile_report(state, started_report)
        checkpoint!(state, opts)

        before_budget = state.budget
        started_at = System.monotonic_time(:microsecond)
        trial_opts = Keyword.put(opts, :combee_policy, state.combee_policy)

        result =
          Coordinator.run([:trial], {:deadline, deadline}, 1, fn :trial ->
            run_parallel_loop(
              adapter,
              trainset,
              valset,
              proposer,
              batch_size,
              iteration,
              state,
              trial_opts
            )
          end)
          |> hd()

        case result do
          {:ok, %State{} = trial_state} ->
            delay_ms = (System.monotonic_time(:microsecond) - started_at) / 1_000

            if trial_state.iteration == iteration and is_nil(trial_state.stop_reason) do
              completed =
                ComBee.BatchController.complete_trial(
                  started_report,
                  delay_ms,
                  trial_state.budget.metric_calls - before_budget.metric_calls,
                  trial_state.budget.reflection_calls - before_budget.reflection_calls
                )

              trial_state = put_profile_report(trial_state, completed)
              checkpoint!(trial_state, trial_opts)

              profile_runtime_trials(
                adapter,
                trainset,
                valset,
                proposer,
                max_iterations,
                trial_state,
                Keyword.put(trial_opts, :combee_policy, trial_state.combee_policy),
                deadline
              )
            else
              reason =
                trial_state.stop_reason || {:profiling_iteration_incomplete, iteration}

              delay_ms = (System.monotonic_time(:microsecond) - started_at) / 1_000

              aborted =
                ComBee.BatchController.abort_trial(
                  started_report,
                  delay_ms,
                  trial_state.budget.metric_calls - before_budget.metric_calls,
                  trial_state.budget.reflection_calls - before_budget.reflection_calls,
                  reason
                )

              state = trial_state |> put_profile_report(aborted) |> Map.put(:stop_reason, reason)
              checkpoint!(state, trial_opts)

              {state, Keyword.put(trial_opts, :combee_policy, state.combee_policy),
               aborted.selected_batch_size}
            end

          {:error, reason} ->
            raise RuntimeError,
                  "ComBee profiling trial #{iteration} interrupted with ambiguous provider effects: " <>
                    inspect(reason)
        end
    end
  end

  defp finish_profile(state, opts) do
    report = state.combee_policy.batch_controller

    notify(opts, :on_combee_batch_selected, %{
      policy_identity: state.combee_policy.identity,
      report: report
    })

    {state, Keyword.put(opts, :combee_policy, state.combee_policy), report.selected_batch_size}
  end

  defp profile_stopped(state, opts, report, reason) do
    report = ComBee.BatchController.stop(report, reason)
    state = state |> put_profile_report(report) |> Map.put(:stop_reason, reason)
    checkpoint!(state, opts)
    {state, Keyword.put(opts, :combee_policy, state.combee_policy), report.selected_batch_size}
  end

  defp put_profile_report(state, report) do
    %{state | combee_policy: ComBee.put_batch_controller_report(state.combee_policy, report)}
  end

  defp selected_profile_batch(report, fallback),
    do: if(report.status in [:ok, :degenerate], do: report.selected_batch_size, else: fallback)

  defp profile_deadline(%ComBee.BatchController.Report{profiling_timeout: :infinity}),
    do: :infinity

  defp profile_deadline(report) do
    remaining = max(report.profiling_timeout - ceil(report.elapsed_ms), 0)
    Coordinator.deadline(remaining)
  end

  defp profile_deadline_elapsed?(:infinity), do: false

  defp profile_deadline_elapsed?(deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  defp run_sequential_loop(
         adapter,
         trainset,
         valset,
         proposer,
         minibatch_size,
         max_iterations,
         state,
         opts
       ) do
    Enum.reduce_while(iteration_range(state.iteration + 1, max_iterations), state, fn iteration,
                                                                                      state ->
      case check_stopper(state, opts) do
        {:continue, state} ->
          run_iteration(
            adapter,
            trainset,
            valset,
            proposer,
            minibatch_size,
            iteration,
            state,
            opts
          )

        {:stop, reason, state} ->
          state = %{state | stop_reason: reason}
          checkpoint!(state, opts)
          {:halt, state}
      end
    end)
  end

  defp run_parallel_loop(
         adapter,
         trainset,
         valset,
         proposer,
         minibatch_size,
         max_iterations,
         state,
         opts
       ) do
    cond do
      state.stop_reason != nil or state.iteration >= max_iterations ->
        state

      match?(
        %Proposal.Batch{phase: :reflection, status: :started},
        state.pending_proposal_batch
      ) ->
        state = recover_interrupted_reflection(state, opts)

        run_parallel_loop(
          adapter,
          trainset,
          valset,
          proposer,
          minibatch_size,
          max_iterations,
          state,
          opts
        )

      match?(%Proposal.Batch{status: :started}, state.pending_proposal_batch) ->
        raise ArgumentError,
              "GEPA resume contains a started proposal batch with ambiguous external effects"

      match?(%Proposal.Batch{phase: :parent}, state.pending_proposal_batch) ->
        state = execute_parent_batch(state, adapter, trainset, opts)

        run_parallel_loop(
          adapter,
          trainset,
          valset,
          proposer,
          minibatch_size,
          max_iterations,
          state,
          opts
        )

      match?(%Proposal.Batch{phase: :reflection}, state.pending_proposal_batch) ->
        state = execute_reflection_batch(state, adapter, proposer, trainset, opts)

        run_parallel_loop(
          adapter,
          trainset,
          valset,
          proposer,
          minibatch_size,
          max_iterations,
          state,
          opts
        )

      match?(%Proposal.Batch{phase: :child}, state.pending_proposal_batch) ->
        state = execute_child_batch(state, adapter, trainset, valset, opts)

        run_parallel_loop(
          adapter,
          trainset,
          valset,
          proposer,
          minibatch_size,
          max_iterations,
          state,
          opts
        )

      merge_scheduled?(state, opts) ->
        case check_stopper(state, opts) do
          {:continue, state} ->
            case run_iteration(
                   adapter,
                   trainset,
                   valset,
                   proposer,
                   minibatch_size,
                   state.iteration + 1,
                   state,
                   opts
                 ) do
              {:cont, state} ->
                run_parallel_loop(
                  adapter,
                  trainset,
                  valset,
                  proposer,
                  minibatch_size,
                  max_iterations,
                  state,
                  opts
                )

              {:halt, state} ->
                state
            end

          {:stop, reason, state} ->
            state = %{state | stop_reason: reason}
            checkpoint!(state, opts)
            state
        end

      true ->
        case check_stopper(state, opts) do
          {:continue, state} ->
            state =
              prepare_parent_batch(
                state,
                adapter,
                trainset,
                minibatch_size,
                max_iterations,
                opts
              )

            run_parallel_loop(
              adapter,
              trainset,
              valset,
              proposer,
              minibatch_size,
              max_iterations,
              state,
              opts
            )

          {:stop, reason, state} ->
            state = %{state | stop_reason: reason}
            checkpoint!(state, opts)
            state
        end
    end
  end

  defp prepare_parent_batch(state, adapter, trainset, minibatch_size, max_iterations, opts) do
    count = min(state.proposal_policy.resolved, max_iterations - state.iteration)

    {contexts, state, deferred_stop_reason} =
      Enum.reduce_while(0..(count - 1), {[], state, nil}, fn slot, {contexts, state, _reason} ->
        iteration = state.iteration + slot + 1

        {batch, minibatch_ids, rng_state} =
          sample_batch(trainset, minibatch_size, state.rng_state)

        {parent, rng_state} =
          opts
          |> Keyword.get(:candidate_selection_strategy, :pareto)
          |> CandidateSelector.select(%{state | rng_state: rng_state})

        reservation =
          Adapter.metric_call_reservation(
            adapter,
            batch,
            parent.candidate,
            capture_traces: true
          )

        id = reservation_id(:parent, iteration)

        case BudgetLedger.reserve(state.budget_ledger, state.budget, id, %{
               metric_calls: reservation
             }) do
          {:ok, ledger} ->
            context = %Proposal.Context{
              slot: slot,
              iteration: iteration,
              parent_id: parent.id,
              minibatch_ids: minibatch_ids
            }

            {:cont,
             {contexts ++ [context], %{state | rng_state: rng_state, budget_ledger: ledger}, nil}}

          {:error, reason} ->
            {:halt, {contexts, state, reason}}
        end
      end)

    case contexts do
      [] ->
        state = %{state | stop_reason: deferred_stop_reason}
        checkpoint!(state, opts)
        state

      contexts ->
        batch = Proposal.new_batch(:parent, contexts, deferred_stop_reason)
        state = %{state | pending_proposal_batch: batch}
        checkpoint!(state, opts)
        state
    end
  end

  defp execute_parent_batch(state, adapter, trainset, opts) do
    %Proposal.Batch{status: :prepared, contexts: contexts} =
      batch =
      state.pending_proposal_batch

    state = mark_batch_started!(state, opts)

    outputs =
      Coordinator.run(contexts, state.proposal_policy.timeout, fn context ->
        parent = Enum.fetch!(state.candidates, context.parent_id)
        examples = Enum.map(context.minibatch_ids, &Enum.fetch!(trainset, &1))
        Evaluation.evaluate(adapter, examples, parent.candidate, capture_traces: true)
      end)

    {contexts, state, deferred_stop_reason} =
      contexts
      |> Enum.zip(outputs)
      |> Enum.reduce({[], state, batch.deferred_stop_reason}, fn {context, output},
                                                                 {contexts, state, stop_reason} ->
        parent = Enum.fetch!(state.candidates, context.parent_id)

        case output do
          {:ok, %Result{} = result} ->
            context = %{
              context
              | parent_result: result,
                parent_metric_calls: metric_calls(result, length(context.minibatch_ids))
            }

            if perfect_result?(result, opts) do
              {contexts ++ [%{context | action: :skip}], state, stop_reason}
            else
              components =
                apply(ModuleSelector, :select, [
                  Keyword.get(opts, :module_selector, :round_robin),
                  state,
                  result.trajectories,
                  result.scores,
                  parent.id,
                  parent.candidate
                ])

              next_component = next_component(parent, opts)
              state = advance_component_cursor(state, parent.id, next_component, opts)

              case build_reflective_dataset(adapter, parent, result, components) do
                {:ok, dataset} ->
                  reflection_id = reservation_id(:reflection, context.iteration)

                  reflection_calls =
                    reflection_call_reservation(components, dataset, state.combee_policy)

                  case BudgetLedger.reserve(
                         state.budget_ledger,
                         state.budget,
                         reflection_id,
                         %{reflection_calls: reflection_calls}
                       ) do
                    {:ok, ledger} ->
                      context = %{
                        context
                        | action: :reflect,
                          components: components,
                          next_component: next_component,
                          dataset: dataset
                      }

                      {contexts ++ [context], %{state | budget_ledger: ledger}, stop_reason}

                    {:error, reason} ->
                      context = %{
                        context
                        | action: :budget_stop,
                          components: components,
                          dataset: dataset,
                          error: reason
                      }

                      {contexts ++ [context], state, stop_reason || reason}
                  end

                {:error, reason} ->
                  context = %{
                    context
                    | action: :error,
                      components: components,
                      next_component: next_component,
                      error: reason
                  }

                  {contexts ++ [context], state, stop_reason}
              end
            end

          {:error, reason} ->
            context = %{context | action: :error, error: reason, parent_ambiguous: true}
            {contexts ++ [context], state, stop_reason}
        end
      end)

    next_batch = Proposal.new_batch(:reflection, contexts, deferred_stop_reason)
    state = %{state | pending_proposal_batch: next_batch}
    checkpoint!(state, opts)
    state
  end

  defp execute_reflection_batch(state, adapter, proposer, trainset, opts) do
    %Proposal.Batch{status: :prepared, contexts: contexts} =
      batch =
      state.pending_proposal_batch

    runnable = Enum.filter(contexts, &(&1.action == :reflect))
    state = if runnable == [], do: state, else: mark_batch_started!(state, opts)

    outputs =
      Coordinator.run(runnable, state.proposal_policy.timeout, fn context ->
        parent = Enum.fetch!(state.candidates, context.parent_id)
        Reflection.execute(proposer, parent, context, state.combee_policy)
      end)
      |> then(&Map.new(Enum.zip(Enum.map(runnable, fn context -> context.slot end), &1)))

    {contexts, state, deferred_stop_reason} =
      Enum.reduce(contexts, {[], state, batch.deferred_stop_reason}, fn context,
                                                                        {contexts, state,
                                                                         stop_reason} ->
        if context.action != :reflect do
          {contexts ++ [context], state, stop_reason}
        else
          case Map.fetch!(outputs, context.slot) do
            {:ok, %{status: :ok} = output} ->
              examples = Enum.map(context.minibatch_ids, &Enum.fetch!(trainset, &1))

              reservation =
                Adapter.metric_call_reservation(
                  adapter,
                  examples,
                  output.candidate,
                  capture_traces: true
                )

              child_id = reservation_id(:child, context.iteration)

              context = %{
                context
                | reflection_calls: output.reflection_calls,
                  dataset: output.dataset,
                  aggregation_reports: output.aggregation_reports,
                  replacements: output.replacements,
                  candidate: output.candidate
              }

              case BudgetLedger.reserve(state.budget_ledger, state.budget, child_id, %{
                     metric_calls: reservation
                   }) do
                {:ok, ledger} ->
                  {contexts ++ [%{context | action: :child}], %{state | budget_ledger: ledger},
                   stop_reason}

                {:error, reason} ->
                  {contexts ++ [%{context | action: :budget_stop, error: reason}], state,
                   stop_reason || reason}
              end

            {:ok, %{status: :error} = output} ->
              context = %{
                context
                | action: :error,
                  reflection_calls: output.reflection_calls,
                  dataset: output.dataset,
                  aggregation_reports: output.aggregation_reports,
                  replacements: output.replacements,
                  error: output.error
              }

              {contexts ++ [context], state, stop_reason}

            {:error, reason} ->
              context = %{
                context
                | action: :error,
                  error: reason,
                  reflection_ambiguous: true
              }

              {contexts ++ [context], state, stop_reason}
          end
        end
      end)

    next_batch = Proposal.new_batch(:child, contexts, deferred_stop_reason)
    state = %{state | pending_proposal_batch: next_batch}
    checkpoint!(state, opts)
    state
  end

  defp execute_child_batch(state, adapter, trainset, valset, opts) do
    %Proposal.Batch{status: :prepared, contexts: contexts} =
      batch =
      state.pending_proposal_batch

    runnable = Enum.filter(contexts, &(&1.action == :child))
    state = if runnable == [], do: state, else: mark_batch_started!(state, opts)

    outputs =
      Coordinator.run(runnable, state.proposal_policy.timeout, fn context ->
        examples = Enum.map(context.minibatch_ids, &Enum.fetch!(trainset, &1))
        Evaluation.evaluate(adapter, examples, context.candidate, capture_traces: true)
      end)
      |> then(&Map.new(Enum.zip(Enum.map(runnable, fn context -> context.slot end), &1)))

    contexts =
      Enum.map(contexts, fn context ->
        if context.action != :child do
          context
        else
          case Map.fetch!(outputs, context.slot) do
            {:ok, %Result{} = result} ->
              %{
                context
                | child_result: result,
                  child_metric_calls: metric_calls(result, length(context.minibatch_ids))
              }

            {:error, reason} ->
              %{context | action: :error, error: reason, child_ambiguous: true}
          end
        end
      end)

    state = apply_parallel_contexts(state, contexts, adapter, trainset, valset, opts)
    stop_reason = state.stop_reason || batch.deferred_stop_reason

    unless BudgetLedger.empty?(state.budget_ledger) do
      raise "GEPA proposal batch completed with unreleased budget reservations"
    end

    state = %{
      state
      | pending_proposal_batch: nil,
        budget_ledger: BudgetLedger.new(),
        stop_reason: stop_reason
    }

    checkpoint!(state, opts)
    state
  end

  defp apply_parallel_contexts(state, contexts, adapter, trainset, valset, opts) do
    Enum.reduce(contexts, state, fn context, state ->
      {state, reservation_error} = commit_context_reservations(state, context)

      context =
        if reservation_error,
          do: %{context | action: :error, error: reservation_error},
          else: context

      parent = Enum.fetch!(state.candidates, context.parent_id)
      candidate_count = length(state.candidates)

      notify(opts, :on_iteration_start, %{iteration: context.iteration, state: state})

      notify(opts, :on_candidate_selected, %{
        iteration: context.iteration,
        candidate_idx: parent.id,
        candidate: parent.candidate,
        score: parent.validation.aggregate_score
      })

      notify(opts, :on_minibatch_sampled, %{
        iteration: context.iteration,
        minibatch_ids: context.minibatch_ids,
        trainset_size: length(trainset)
      })

      state = apply_parent_result(state, context, parent, trainset, opts)
      state = apply_parallel_action(state, context, parent, adapter, trainset, valset, opts)
      notify_iteration_end(opts, context.iteration, state, candidate_count)
      state
    end)
  end

  defp apply_parent_result(
         state,
         %Proposal.Context{parent_result: nil},
         _parent,
         _trainset,
         _opts
       ),
       do: state

  defp apply_parent_result(state, context, parent, trainset, opts) do
    examples = Enum.map(context.minibatch_ids, &Enum.fetch!(trainset, &1))

    event = %{
      iteration: context.iteration,
      candidate_idx: parent.id,
      parent_ids: parent.parent_ids,
      is_seed_candidate: parent.id == 0
    }

    notify_evaluation_start(opts, examples, true, event)
    notify_evaluation_end(opts, context.parent_result, event)

    cache =
      maybe_cache_result(state.cache, parent.candidate, examples, context.parent_result, true)

    %{state | cache: cache}
  end

  defp apply_parallel_action(
         state,
         %{action: :skip} = context,
         parent,
         _adapter,
         _trainset,
         _valset,
         opts
       ) do
    notify(opts, :on_evaluation_skipped, %{
      iteration: context.iteration,
      candidate_idx: parent.id,
      reason: :all_scores_perfect,
      scores: context.parent_result.scores,
      is_seed_candidate: parent.id == 0
    })

    %{state | iteration: context.iteration, last_iteration_found_candidate: false}
  end

  defp apply_parallel_action(
         state,
         %{action: :budget_stop} = context,
         _parent,
         _adapter,
         _trainset,
         _valset,
         _opts
       ) do
    %{state | iteration: context.iteration, stop_reason: state.stop_reason || context.error}
  end

  defp apply_parallel_action(
         state,
         %{action: :error} = context,
         parent,
         _adapter,
         _trainset,
         _valset,
         opts
       ) do
    maybe_notify_reflection_start(opts, context, parent)
    state = record_combee_reports(state, context.aggregation_reports, opts)

    notify(opts, :on_error, %{
      iteration: context.iteration,
      exception: context.error,
      will_continue: true
    })

    reject(
      state,
      context.iteration,
      parent,
      context.components || [],
      {:proposal_error, context.error},
      context.parent_result,
      context.child_result,
      context.candidate
    )
  end

  defp apply_parallel_action(
         state,
         %{action: :child, child_result: %Result{}} = context,
         parent,
         adapter,
         trainset,
         valset,
         opts
       ) do
    maybe_notify_reflection_start(opts, context, parent)
    state = record_combee_reports(state, context.aggregation_reports, opts)

    notify(opts, :on_proposal_end, %{
      iteration: context.iteration,
      new_instructions: context.replacements,
      aggregation_reports: context.aggregation_reports || []
    })

    examples = Enum.map(context.minibatch_ids, &Enum.fetch!(trainset, &1))

    event = %{
      iteration: context.iteration,
      candidate_idx: nil,
      parent_ids: [parent.id],
      is_seed_candidate: false
    }

    notify_evaluation_start(opts, examples, true, event)
    notify_evaluation_end(opts, context.child_result, event)

    cache =
      maybe_cache_result(state.cache, context.candidate, examples, context.child_result, true)

    state = %{state | cache: cache, last_iteration_found_candidate: false}
    policy = Keyword.get(opts, :acceptance_policy, Acceptance.default(:mutation))

    case Acceptance.decide(policy, context.parent_result, context.child_result, %{
           operation: :mutation,
           iteration: context.iteration,
           parent_id: parent.id,
           component: legacy_component(context.components),
           components: context.components,
           candidate: context.candidate
         }) do
      {:accept, acceptance} ->
        case authorize_parallel_validation(
               adapter,
               valset,
               context.candidate,
               context.iteration,
               state
             ) do
          {:ok, state} ->
            case accept_candidate(
                   adapter,
                   valset,
                   context.candidate,
                   parent,
                   context.components,
                   context.next_component,
                   context.parent_result,
                   context.child_result,
                   context.iteration,
                   state,
                   opts,
                   acceptance
                 ) do
              {:ok, state} ->
                state

              {:stop, reason, state} ->
                %{state | stop_reason: reason, iteration: context.iteration}
            end

          {:error, reason, state} ->
            %{state | stop_reason: reason, iteration: context.iteration}
        end

      {:reject, reason} ->
        notify(opts, :on_candidate_rejected, %{
          iteration: context.iteration,
          old_score: context.parent_result.aggregate_score,
          new_score: context.child_result.aggregate_score,
          reason: reason,
          components: context.components
        })

        reject(
          state,
          context.iteration,
          parent,
          context.components,
          reason,
          context.parent_result,
          context.child_result,
          context.candidate
        )
    end
  end

  defp maybe_notify_reflection_start(_opts, %{dataset: nil}, _parent), do: :ok

  defp maybe_notify_reflection_start(opts, context, parent) do
    notify(opts, :on_reflective_dataset_built, %{
      iteration: context.iteration,
      candidate_idx: parent.id,
      components: context.components,
      dataset: context.dataset
    })

    notify(opts, :on_proposal_start, %{
      iteration: context.iteration,
      parent_candidate: parent.candidate,
      components: context.components,
      reflective_dataset: context.dataset,
      aggregation: ComBee.metadata(Keyword.fetch!(opts, :combee_policy))
    })
  end

  defp mark_batch_started!(state, opts) do
    state = %{state | pending_proposal_batch: Proposal.started(state.pending_proposal_batch)}
    checkpoint!(state, opts)
    state
  end

  defp recover_interrupted_reflection(state, opts) do
    %Proposal.Batch{phase: :reflection, status: :started, contexts: contexts} =
      state.pending_proposal_batch

    {contexts, state} =
      Enum.map_reduce(contexts, state, fn context, state ->
        id = reservation_id(:reflection, context.iteration)

        if Map.has_key?(state.budget_ledger.reservations, id) do
          {budget, ledger} =
            BudgetLedger.commit_ambiguous(state.budget_ledger, state.budget, id)

          context = %{
            context
            | action: :error,
              error: {:interrupted_reflection, :ambiguous_external_effects},
              reflection_calls: nil,
              reflection_ambiguous: false
          }

          {context, %{state | budget: budget, budget_ledger: ledger}}
        else
          {context, state}
        end
      end)

    batch =
      Proposal.new_batch(:child, contexts, state.pending_proposal_batch.deferred_stop_reason)

    state = %{state | pending_proposal_batch: batch}
    checkpoint!(state, opts)
    state
  end

  defp commit_reservation(state, id, actual) do
    try do
      {budget, ledger} = BudgetLedger.commit(state.budget_ledger, state.budget, id, actual)
      {%{state | budget: budget, budget_ledger: ledger}, :ok}
    rescue
      error in ArgumentError ->
        {budget, ledger} =
          BudgetLedger.commit_ambiguous(state.budget_ledger, state.budget, id)

        {%{state | budget: budget, budget_ledger: ledger},
         {:error, {:reservation_mismatch, Exception.message(error)}}}
    end
  end

  defp commit_context_reservations(state, context) do
    phases = [
      {:parent, context.parent_ambiguous, %{metric_calls: context.parent_metric_calls || 0}},
      {:reflection, context.reflection_ambiguous,
       %{reflection_calls: context.reflection_calls || 0}},
      {:child, context.child_ambiguous, %{metric_calls: context.child_metric_calls || 0}}
    ]

    Enum.reduce(phases, {state, nil}, fn {phase, ambiguous?, actual}, {state, error} ->
      id = reservation_id(phase, context.iteration)

      if Map.has_key?(state.budget_ledger.reservations, id) do
        if ambiguous? do
          {budget, ledger} =
            BudgetLedger.commit_ambiguous(state.budget_ledger, state.budget, id)

          {%{state | budget: budget, budget_ledger: ledger}, error}
        else
          {state, status} = commit_reservation(state, id, actual)
          next_error = if status == :ok, do: error, else: elem(status, 1)
          {state, next_error}
        end
      else
        {state, error}
      end
    end)
  end

  defp authorize_parallel_validation(adapter, valset, candidate, iteration, state) do
    target_id = length(state.candidates)

    ids =
      EvaluationPolicy.validation_ids(
        state.evaluation_policy,
        valset,
        state,
        target_id
      )

    batch = Enum.map(ids, &Enum.fetch!(valset, &1))

    metric_calls =
      Adapter.metric_call_reservation(adapter, batch, candidate, capture_traces: false)

    id = reservation_id(:validation, iteration)

    case BudgetLedger.reserve(state.budget_ledger, state.budget, id, %{
           metric_calls: metric_calls,
           full_evaluations: 1
         }) do
      {:ok, ledger} ->
        {_reservation, ledger} = BudgetLedger.release(ledger, id)
        {:ok, %{state | budget_ledger: ledger}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp perfect_result?(result, opts) do
    Keyword.get(opts, :skip_perfect_score, false) and
      Enum.all?(result.scores, &(&1 >= Keyword.fetch!(opts, :perfect_score)))
  end

  defp reservation_id(phase, iteration), do: "#{phase}:#{iteration}"

  defp proposal_policy(opts, minibatch_size) do
    requested = Keyword.get(opts, :proposal_concurrency, 1)
    timeout = Keyword.get(opts, :proposal_timeout, :infinity)

    resolved =
      case requested do
        :auto ->
          workers = DSEx.Settings.snapshot() |> Map.fetch!(:async_max_workers)
          max(1, div(workers, minibatch_size))

        value ->
          value
      end

    %{requested: requested, resolved: resolved, timeout: timeout}
  end

  defp ensure_proposal_policy!(%State{proposal_policy: policy} = state, requested) do
    if policy == requested do
      state
    else
      raise ArgumentError,
            "GEPA resume proposal policy mismatch: stored #{inspect(policy)}, requested #{inspect(requested)}"
    end
  end

  defp dump_proposal_policy(policy) do
    %{
      "requested" => if(policy.requested == :auto, do: "auto", else: policy.requested),
      "resolved" => policy.resolved,
      "timeout" => if(policy.timeout == :infinity, do: "infinity", else: policy.timeout)
    }
  end

  defp load_proposal_policy(_dumped, 1, requested), do: requested

  defp load_proposal_policy(dumped, schema_version, _requested)
       when schema_version in [3, 4, 5] do
    stored = Map.fetch!(dumped, "proposal_policy")

    %{
      requested: if(stored["requested"] == "auto", do: :auto, else: stored["requested"]),
      resolved: Map.fetch!(stored, "resolved"),
      timeout: if(stored["timeout"] == "infinity", do: :infinity, else: stored["timeout"])
    }
  end

  defp load_combee_policy(_dumped, schema_version, requested) when schema_version in [1, 3] do
    if requested.enabled do
      raise ArgumentError, "GEPA resume ComBee policy mismatch: legacy checkpoint is disabled"
    end

    requested
  end

  defp load_combee_policy(dumped, schema_version, _requested) when schema_version in [4, 5] do
    dumped |> Map.fetch!("combee_policy") |> ComBee.load_policy!()
  end

  defp validate_pending_ledger!(%State{pending_proposal_batch: nil, budget_ledger: ledger}) do
    unless BudgetLedger.empty?(ledger) do
      raise ArgumentError, "GEPA checkpoint has reservations without a pending proposal batch"
    end

    :ok
  end

  defp validate_pending_ledger!(%State{pending_proposal_batch: batch, budget_ledger: ledger}) do
    parent_ids =
      if batch.phase == :parent do
        Enum.map(batch.contexts, &reservation_id(:parent, &1.iteration))
      else
        batch.contexts
        |> Enum.filter(&(not is_nil(&1.parent_metric_calls) or &1.parent_ambiguous))
        |> Enum.map(&reservation_id(:parent, &1.iteration))
      end

    reflection_ids =
      if batch.phase in [:reflection, :child] do
        batch.contexts
        |> Enum.filter(fn context ->
          context.action == :reflect or not is_nil(context.reflection_calls) or
            context.reflection_ambiguous
        end)
        |> Enum.map(&reservation_id(:reflection, &1.iteration))
      else
        []
      end

    child_ids =
      if batch.phase == :child do
        batch.contexts
        |> Enum.filter(&(&1.action == :child))
        |> Enum.map(&reservation_id(:child, &1.iteration))
      else
        []
      end

    expected = Enum.sort(parent_ids ++ reflection_ids ++ child_ids)

    actual = ledger.reservations |> Map.keys() |> Enum.sort()

    unless actual == expected do
      raise ArgumentError, "GEPA pending proposal reservations do not match the batch"
    end

    :ok
  end

  defp validate_checkpoint_integrity!(_dumped, 1), do: :ok

  defp validate_checkpoint_integrity!(dumped, 3) do
    expected =
      Proposal.checkpoint_integrity(
        Map.get(dumped, "pending_proposal_batch"),
        Map.fetch!(dumped, "budget_ledger"),
        Map.fetch!(dumped, "proposal_policy")
      )

    unless Map.get(dumped, "pending_proposal_integrity") == expected do
      raise ArgumentError, "GEPA pending proposal checkpoint integrity mismatch"
    end

    :ok
  end

  defp validate_checkpoint_integrity!(dumped, schema_version) when schema_version in [4, 5] do
    expected =
      Proposal.checkpoint_integrity(
        Map.get(dumped, "pending_proposal_batch"),
        Map.fetch!(dumped, "budget_ledger"),
        Map.fetch!(dumped, "proposal_policy"),
        Map.fetch!(dumped, "combee_policy")
      )

    unless Map.get(dumped, "pending_proposal_integrity") == expected do
      raise ArgumentError, "GEPA pending proposal checkpoint integrity mismatch"
    end

    :ok
  end

  defp run_iteration(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts) do
    notify(opts, :on_iteration_start, %{iteration: iteration, state: state})
    candidate_count = length(state.candidates)

    case iterate(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts) do
      {:ok, state} ->
        notify_iteration_end(opts, iteration, state, candidate_count)
        checkpoint!(state, opts)
        {:cont, state}

      {:stop, reason, state} ->
        state = %{state | stop_reason: reason}
        notify_iteration_end(opts, iteration, state, candidate_count)
        checkpoint!(state, opts)
        {:halt, state}
    end
  end

  @spec best(State.t()) :: Entry.t()
  def best(%State{candidates: candidates, evaluation_policy: policy}),
    do: policy.best_entry(candidates)

  @spec frontier(State.t()) :: [Entry.t()]
  def frontier(%State{candidates: candidates, frontier_type: frontier_type}) do
    ids = candidates |> frontier_candidates() |> Frontier.candidate_ids(frontier_type)
    by_id = Map.new(candidates, &{&1.id, &1})
    Enum.map(ids, &Map.fetch!(by_id, &1))
  end

  @spec dump_state(State.t()) :: map()
  def dump_state(%State{} = state) do
    ledger = BudgetLedger.dump(state.budget_ledger)
    pending = Proposal.dump(state.pending_proposal_batch, &dump_result/1)
    policy = dump_proposal_policy(state.proposal_policy)

    resolved_combee_policy =
      state.combee_policy ||
        false
        |> ComBee.resolve(1, 1, 0)
        |> ComBee.bound_timeout(:infinity)

    combee_policy = ComBee.dump_policy(resolved_combee_policy)

    checkpoint = %{
      "schema_version" => 4,
      "iteration" => state.iteration,
      "candidates" => Enum.map(state.candidates, &dump_entry/1),
      "rejected" => DSEx.Optimizer.Report.json_safe(state.rejected),
      "history" => DSEx.Optimizer.Report.json_safe(state.history),
      "cache" => dump_cache(state.cache),
      "budget" => Budget.dump(state.budget),
      "rng_state" => dump_rng(state.rng_state),
      "merge_due" => state.merge_due,
      "total_merges_tested" => state.total_merges_tested,
      "merge_attempts" => DSEx.Optimizer.Report.json_safe(state.merge_attempts),
      "last_iteration_found_candidate" => state.last_iteration_found_candidate,
      "frontier_type" => state.frontier_type,
      "evaluation_policy" => Atom.to_string(state.evaluation_policy),
      "best_outputs_valset" => dump_best_outputs(state.best_outputs_valset),
      "stopper_state" => dump_stopper_state(state.stopper_state),
      "budget_ledger" => ledger,
      "pending_proposal_batch" => pending,
      "proposal_policy" => policy,
      "combee_policy" => combee_policy,
      "combee_reports" => Enum.map(state.combee_reports, &ComBee.dump_report/1),
      "stop_reason" => DSEx.Optimizer.Report.json_safe(state.stop_reason)
    }

    Map.put(
      checkpoint,
      "pending_proposal_integrity",
      Proposal.checkpoint_integrity(pending, ledger, policy, combee_policy)
    )
  end

  defp initialize(adapter, seed_candidate, valset, opts) do
    state = %State{
      cache: new_evaluation_cache(opts),
      budget:
        Budget.new(
          max_metric_calls: Keyword.get(opts, :max_metric_calls, :infinity),
          max_full_evaluations: Keyword.get(opts, :max_full_evaluations, :infinity),
          max_reflection_calls: Keyword.get(opts, :max_reflection_calls, :infinity)
        ),
      rng_state: seed_rng(Keyword.get(opts, :seed, 0)),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      evaluation_policy:
        opts |> Keyword.get(:evaluation_policy, :full) |> EvaluationPolicy.resolve!(),
      best_outputs_valset: if(Keyword.get(opts, :track_best_outputs, false), do: %{}),
      stopper_state: new_stopper_state(opts),
      proposal_policy: Keyword.fetch!(opts, :proposal_policy),
      combee_policy: Keyword.fetch!(opts, :combee_policy)
    }

    case evaluate_validation(adapter, valset, seed_candidate, 0, [], 0, state, opts) do
      {:ok, validation, state} ->
        entry = %Entry{
          id: 0,
          candidate: seed_candidate,
          validation: validation,
          discovered_at: state.budget.metric_calls
        }

        state = state |> track_validation_outputs(entry) |> Map.put(:candidates, [entry])
        notify_valset_evaluated(opts, state, entry, valset, 0)
        checkpoint!(state, opts)
        state

      {:error, reason, _state} ->
        notify(opts, :on_error, %{iteration: 0, exception: reason, will_continue: false})
        raise ArgumentError, "GEPA cannot evaluate the seed candidate: #{inspect(reason)}"
    end
  end

  defp iterate(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts) do
    if merge_scheduled?(state, opts) do
      case attempt_merge(adapter, valset, iteration, state, opts) do
        {:none, state} ->
          mutate(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts)

        result ->
          result
      end
    else
      mutate(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts)
    end
  end

  defp mutate(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts) do
    state = %{state | last_iteration_found_candidate: false}

    {batch, minibatch_ids, rng_state} =
      sample_batch(trainset, minibatch_size, state.rng_state)

    state = %{state | rng_state: rng_state}

    {parent, rng_state} =
      opts
      |> Keyword.get(:candidate_selection_strategy, :pareto)
      |> CandidateSelector.select(state)

    state = %{state | rng_state: rng_state}

    notify(opts, :on_candidate_selected, %{
      iteration: iteration,
      candidate_idx: parent.id,
      candidate: parent.candidate,
      score: parent.validation.aggregate_score
    })

    notify(opts, :on_minibatch_sampled, %{
      iteration: iteration,
      minibatch_ids: minibatch_ids,
      trainset_size: length(trainset)
    })

    with {:ok, parent_result, state} <-
           evaluate(adapter, batch, parent.candidate, true, :minibatch, state, opts, %{
             iteration: iteration,
             candidate_idx: parent.id,
             parent_ids: parent.parent_ids,
             is_seed_candidate: parent.id == 0
           }),
         :ok <- maybe_skip_perfect(parent_result, parent, iteration, state, opts),
         components <-
           ModuleSelector.select(
             Keyword.get(opts, :module_selector, :round_robin),
             state,
             parent_result.trajectories,
             parent_result.scores,
             parent.id,
             parent.candidate
           ),
         next_component <- next_component(parent, opts),
         state <- advance_component_cursor(state, parent.id, next_component, opts),
         reflective_dataset <-
           Adapter.make_reflective_dataset(
             adapter,
             parent.candidate,
             parent_result,
             components
           ),
         :ok <-
           notify(opts, :on_reflective_dataset_built, %{
             iteration: iteration,
             candidate_idx: parent.id,
             components: components,
             dataset: reflective_dataset
           }),
         :ok <-
           notify(opts, :on_proposal_start, %{
             iteration: iteration,
             parent_candidate: parent.candidate,
             components: components,
             reflective_dataset: reflective_dataset,
             aggregation: ComBee.metadata(state.combee_policy)
           }),
         {:ok, replacements, aggregation_reports, state} <-
           propose_components_with_budget(
             proposer,
             parent,
             components,
             reflective_dataset,
             minibatch_ids,
             parent_result,
             next_component,
             iteration,
             state,
             opts
           ),
         :ok <-
           notify(opts, :on_proposal_end, %{
             iteration: iteration,
             new_instructions: replacements,
             aggregation_reports: aggregation_reports
           }),
         proposed_candidate = Map.merge(parent.candidate, replacements),
         {:ok, proposed_result, state} <-
           evaluate(adapter, batch, proposed_candidate, false, :minibatch, state, opts, %{
             iteration: iteration,
             candidate_idx: nil,
             parent_ids: [parent.id],
             is_seed_candidate: false
           }) do
      policy = Keyword.get(opts, :acceptance_policy, Acceptance.default(:mutation))

      case Acceptance.decide(policy, parent_result, proposed_result, %{
             operation: :mutation,
             iteration: iteration,
             parent_id: parent.id,
             component: legacy_component(components),
             components: components,
             candidate: proposed_candidate
           }) do
        {:accept, acceptance} ->
          accept_candidate(
            adapter,
            valset,
            proposed_candidate,
            parent,
            components,
            next_component,
            parent_result,
            proposed_result,
            iteration,
            state,
            opts,
            acceptance
          )

        {:reject, reason} ->
          notify(opts, :on_candidate_rejected, %{
            iteration: iteration,
            old_score: parent_result.aggregate_score,
            new_score: proposed_result.aggregate_score,
            reason: reason,
            components: components
          })

          {:ok,
           reject(
             state,
             iteration,
             parent,
             components,
             reason,
             parent_result,
             proposed_result,
             proposed_candidate
           )}
      end
    else
      {:skip, state} ->
        {:ok, %{state | iteration: iteration}}

      {:error, {:budget_exhausted, _, _, _} = reason, state} ->
        {:stop, reason, state}

      {:error, {:component_proposal_error, reason, components}, state} ->
        notify(opts, :on_error, %{iteration: iteration, exception: reason, will_continue: true})

        {:ok,
         reject(state, iteration, parent, components, {:proposal_error, reason}, nil, nil, nil)}

      {:error, reason, state} ->
        notify(opts, :on_error, %{iteration: iteration, exception: reason, will_continue: true})

        {:ok, reject(state, iteration, parent, [], {:proposal_error, reason}, nil, nil, nil)}

      {:error, reason} ->
        notify(opts, :on_error, %{iteration: iteration, exception: reason, will_continue: true})

        {:ok, reject(state, iteration, parent, [], {:proposal_error, reason}, nil, nil, nil)}
    end
  end

  defp attempt_merge(adapter, valset, iteration, state, opts) do
    candidates = Map.new(state.candidates, &{&1.id, &1.candidate})
    lineage = Map.new(state.candidates, &{&1.id, &1.parent_ids})

    validation_scores =
      Map.new(state.candidates, fn entry ->
        scores =
          entry.validation.scores
          |> Enum.zip(result_validation_ids(entry.validation))
          |> Map.new(fn {score, id} -> {id, score} end)

        {entry.id, scores}
      end)

    aggregate_scores = aggregate_scores(state.candidates)

    frontier_ids =
      state.candidates
      |> frontier_candidates()
      |> Frontier.candidate_ids(state.frontier_type)

    merge_opts = [
      overlap_floor: Keyword.get(opts, :merge_val_overlap_floor, 5),
      sample_size: Keyword.get(opts, :merge_subsample_size, 5)
    ]

    case Merge.propose_source(
           candidates,
           lineage,
           validation_scores,
           aggregate_scores,
           frontier_ids,
           state.merge_attempts,
           state.rng_state,
           merge_opts
         ) do
      {:none, attempts, rng_state} ->
        {:none,
         %{
           state
           | merge_attempts: attempts,
             rng_state: rng_state,
             last_iteration_found_candidate: false
         }}

      {:ok, proposal, attempts, rng_state} ->
        state = %{
          state
          | merge_attempts: attempts,
            rng_state: rng_state,
            last_iteration_found_candidate: false
        }

        evaluate_merge(adapter, valset, proposal, iteration, state, opts)
    end
  end

  defp evaluate_merge(adapter, valset, proposal, iteration, state, opts) do
    batch = Enum.map(proposal.validation_instances, &Enum.fetch!(valset, &1))

    notify(opts, :on_merge_attempted, %{
      iteration: iteration,
      parent_ids: proposal.parent_ids,
      merged_candidate: proposal.candidate
    })

    case evaluate(adapter, batch, proposal.candidate, false, :minibatch, state, opts, %{
           iteration: iteration,
           candidate_idx: nil,
           parent_ids: proposal.parent_ids,
           is_seed_candidate: false
         }) do
      {:ok, result, state} ->
        parent_result = strongest_parent_result(proposal)
        policy = Keyword.get(opts, :merge_acceptance_policy, Acceptance.default(:merge))

        case Acceptance.decide(policy, parent_result, result, %{
               operation: :merge,
               iteration: iteration,
               parent_ids: proposal.parent_ids,
               ancestor: proposal.ancestor,
               candidate: proposal.candidate,
               parent_scores: proposal.parent_scores
             }) do
          {:accept, acceptance} ->
            accept_merge(adapter, valset, proposal, result, iteration, state, opts, acceptance)

          {:reject, reason} ->
            notify(opts, :on_merge_rejected, %{
              iteration: iteration,
              parent_ids: proposal.parent_ids,
              reason: reason
            })

            {:ok,
             reject_merge(
               proposal,
               result,
               Enum.sum(parent_result.scores),
               reason,
               iteration,
               state
             )}
        end

      {:error, {:budget_exhausted, _, _, _} = reason, state} ->
        {:stop, reason, state}
    end
  end

  defp accept_merge(
         adapter,
         valset,
         proposal,
         minibatch_result,
         iteration,
         state,
         opts,
         acceptance
       ) do
    case evaluate_validation(
           adapter,
           valset,
           proposal.candidate,
           length(state.candidates),
           proposal.parent_ids,
           iteration,
           state,
           opts
         ) do
      {:ok, validation, state} ->
        parent_entries = Enum.map(proposal.parent_ids, &Enum.fetch!(state.candidates, &1))

        entry = %Entry{
          id: length(state.candidates),
          candidate: proposal.candidate,
          validation: validation,
          parent_ids: proposal.parent_ids,
          next_component: parent_entries |> Enum.map(& &1.next_component) |> Enum.max(),
          discovered_at: state.budget.metric_calls
        }

        event = %{
          iteration: iteration,
          status: :accepted,
          operation: :merge,
          candidate_id: entry.id,
          parent_ids: proposal.parent_ids,
          ancestor: proposal.ancestor,
          component_sources: proposal.component_sources,
          validation_instances: proposal.validation_instances,
          parent_scores: proposal.parent_scores,
          minibatch_candidate_score: minibatch_result.aggregate_score,
          acceptance: acceptance,
          validation_score: validation.aggregate_score
        }

        state = track_validation_outputs(state, entry)

        state = %{
          state
          | iteration: iteration,
            candidates: state.candidates ++ [entry],
            history: state.history ++ [event],
            merge_due: state.merge_due - 1,
            total_merges_tested: state.total_merges_tested + 1
        }

        notify_candidate_added(opts, state, entry, valset, iteration)

        notify(opts, :on_merge_accepted, %{
          iteration: iteration,
          new_candidate_idx: entry.id,
          parent_ids: proposal.parent_ids
        })

        notify(opts, :on_candidate_accepted, %{
          iteration: iteration,
          new_candidate_idx: entry.id,
          new_score: minibatch_result.aggregate_score,
          parent_ids: proposal.parent_ids
        })

        {:ok, state}

      {:error, {:budget_exhausted, _, _, _} = reason, state} ->
        {:stop, reason, state}
    end
  end

  defp reject_merge(proposal, result, parent_best, reason, iteration, state) do
    event = %{
      iteration: iteration,
      status: :rejected,
      operation: :merge,
      parent_ids: proposal.parent_ids,
      ancestor: proposal.ancestor,
      component_sources: proposal.component_sources,
      validation_instances: proposal.validation_instances,
      parent_scores: proposal.parent_scores,
      candidate: proposal.candidate,
      reason: reason,
      minibatch_parent_score: parent_best,
      minibatch_candidate_score: result.aggregate_score,
      candidate_side_information: result.side_information
    }

    %{
      state
      | iteration: iteration,
        rejected: state.rejected ++ [event],
        history: state.history ++ [event]
    }
  end

  defp strongest_parent_result(proposal) do
    {_parent_id, scores} =
      proposal.parent_ids
      |> Enum.map(fn parent_id ->
        scores =
          Enum.map(proposal.validation_instances, fn validation_id ->
            proposal.parent_scores |> Map.fetch!(parent_id) |> Map.fetch!(validation_id)
          end)

        {parent_id, scores}
      end)
      |> Enum.max_by(fn {_parent_id, scores} -> Enum.sum(scores) end)

    Result.new(List.duplicate(nil, length(scores)), scores)
  end

  defp merge_scheduled?(state, opts) do
    Keyword.get(opts, :use_merge, false) and state.merge_due > 0 and
      state.last_iteration_found_candidate
  end

  defp schedule_merge(state, opts) do
    if Keyword.get(opts, :use_merge, false) and
         state.total_merges_tested < Keyword.get(opts, :max_merge_invocations, 5),
       do: state.merge_due + 1,
       else: state.merge_due
  end

  defp accept_candidate(
         adapter,
         valset,
         candidate,
         parent,
         components,
         next_component,
         parent_result,
         proposed_result,
         iteration,
         state,
         opts,
         acceptance
       ) do
    case evaluate_validation(
           adapter,
           valset,
           candidate,
           length(state.candidates),
           [parent.id],
           iteration,
           state,
           opts
         ) do
      {:ok, validation, state} ->
        entry = %Entry{
          id: length(state.candidates),
          candidate: candidate,
          validation: validation,
          parent_ids: [parent.id],
          next_component: next_component,
          discovered_at: state.budget.metric_calls
        }

        event = %{
          iteration: iteration,
          status: :accepted,
          candidate_id: entry.id,
          parent_ids: [parent.id],
          component: legacy_component(components),
          components: components,
          minibatch_parent_score: parent_result.aggregate_score,
          minibatch_candidate_score: proposed_result.aggregate_score,
          acceptance: acceptance,
          validation_score: validation.aggregate_score
        }

        state = track_validation_outputs(state, entry)

        state = %{
          state
          | iteration: iteration,
            candidates: state.candidates ++ [entry],
            history: state.history ++ [event],
            last_iteration_found_candidate: true,
            merge_due: schedule_merge(state, opts)
        }

        notify_candidate_added(opts, state, entry, valset, iteration)

        notify(opts, :on_candidate_accepted, %{
          iteration: iteration,
          new_candidate_idx: entry.id,
          new_score: proposed_result.aggregate_score,
          parent_ids: [parent.id],
          components: components
        })

        {:ok, state}

      {:error, {:budget_exhausted, _, _, _} = reason, state} ->
        {:stop, reason, state}
    end
  end

  defp reject(
         state,
         iteration,
         parent,
         components,
         reason,
         parent_result,
         proposed_result,
         candidate
       ) do
    event = %{
      iteration: iteration,
      status: :rejected,
      parent_ids: [parent.id],
      component: legacy_component(components),
      components: components,
      candidate: candidate,
      reason: reason,
      minibatch_parent_score: score(parent_result),
      minibatch_candidate_score: score(proposed_result),
      parent_side_information: side_information(parent_result),
      candidate_side_information: side_information(proposed_result)
    }

    %{
      state
      | iteration: iteration,
        rejected: state.rejected ++ [event],
        history: state.history ++ [event]
    }
  end

  defp evaluate_validation(
         adapter,
         valset,
         candidate,
         target_candidate_id,
         parent_ids,
         iteration,
         state,
         opts
       ) do
    ids =
      EvaluationPolicy.validation_ids(
        state.evaluation_policy,
        valset,
        if(state.candidates == [], do: nil, else: state),
        target_candidate_id
      )

    batch = Enum.map(ids, &Enum.fetch!(valset, &1))

    case evaluate(adapter, batch, candidate, false, :full, state, opts, %{
           iteration: iteration,
           candidate_idx: target_candidate_id,
           parent_ids: parent_ids,
           is_seed_candidate: target_candidate_id == 0
         }) do
      {:ok, result, state} ->
        result = %{result | metadata: Map.put(result.metadata, :validation_ids, ids)}
        {:ok, result, state}

      error ->
        error
    end
  end

  defp maybe_skip_perfect(result, parent, iteration, state, opts) do
    if Keyword.get(opts, :skip_perfect_score, false) and
         Enum.all?(result.scores, &(&1 >= Keyword.fetch!(opts, :perfect_score))) do
      notify(opts, :on_evaluation_skipped, %{
        iteration: iteration,
        candidate_idx: parent.id,
        reason: :all_scores_perfect,
        scores: result.scores,
        is_seed_candidate: parent.id == 0
      })

      {:skip, state}
    else
      :ok
    end
  end

  defp track_validation_outputs(%State{best_outputs_valset: nil} = state, _entry), do: state

  defp track_validation_outputs(%State{} = state, %Entry{} = entry) do
    ids = result_validation_ids(entry.validation)

    best_outputs =
      [ids, entry.validation.scores, entry.validation.outputs]
      |> Enum.zip()
      |> Enum.reduce(state.best_outputs_valset, fn
        {_validation_id, _score, nil}, best_outputs ->
          best_outputs

        {validation_id, score, output}, best_outputs ->
          previous = best_validation_score(state.candidates, validation_id)
          update_best_output(best_outputs, validation_id, entry.id, output, score, previous)
      end)

    %{state | best_outputs_valset: best_outputs}
  end

  defp update_best_output(outputs, validation_id, candidate_id, output, _score, :none),
    do: Map.put(outputs, validation_id, [{candidate_id, output}])

  defp update_best_output(outputs, validation_id, candidate_id, output, score, previous)
       when score > previous,
       do: Map.put(outputs, validation_id, [{candidate_id, output}])

  defp update_best_output(outputs, validation_id, candidate_id, output, score, score) do
    Map.update(outputs, validation_id, [{candidate_id, output}], fn existing ->
      existing ++ [{candidate_id, output}]
    end)
  end

  defp update_best_output(outputs, _validation_id, _candidate_id, _output, _score, _previous),
    do: outputs

  defp best_validation_score(candidates, validation_id) do
    candidates
    |> Enum.flat_map(fn entry ->
      entry.validation
      |> result_validation_ids()
      |> Enum.zip(entry.validation.scores)
    end)
    |> Enum.reduce(:none, fn
      {^validation_id, score}, :none -> score
      {^validation_id, score}, best -> max(score, best)
      {_other_id, _score}, best -> best
    end)
  end

  defp evaluate(adapter, batch, candidate, capture_traces, kind, state, opts, event) do
    cond do
      capture_traces ->
        evaluate_fresh(adapter, batch, candidate, true, kind, state, opts, event)

      Keyword.get(opts, :cache_evaluation, true) ->
        evaluate_cached(adapter, batch, candidate, kind, state, opts, event)

      true ->
        evaluate_fresh(adapter, batch, candidate, false, kind, state, opts, event)
    end
  end

  defp evaluate_cached(adapter, batch, candidate, kind, state, opts, event) do
    backend = evaluation_cache_backend(state.cache)
    {hits, missing_indexes} = backend.lookup(state.cache, candidate, batch)

    if missing_indexes == [] do
      result = backend.assemble(batch, hits, [], nil)

      case Budget.record_evaluation(state.budget, 0, kind) do
        {:ok, budget} ->
          notify(opts, :on_evaluation_skipped, %{
            iteration: event.iteration,
            candidate_idx: event.candidate_idx,
            reason: :cache_hit,
            scores: result.scores,
            is_seed_candidate: event.is_seed_candidate
          })

          notify_budget_updated(opts, state, budget, 0, event.iteration)
          {:ok, result, %{state | budget: budget}}

        {:error, reason, _budget} ->
          {:error, reason, state}
      end
    else
      missing_batch = Enum.map(missing_indexes, &Enum.fetch!(batch, &1))

      reservation =
        Adapter.metric_call_reservation(adapter, missing_batch, candidate, capture_traces: false)

      with :ok <- Budget.authorize_evaluation(state.budget, reservation, kind) do
        notify_evaluation_start(opts, batch, false, event)

        missing_result =
          Evaluation.evaluate(adapter, missing_batch, candidate, capture_traces: false)

        result = backend.assemble(batch, hits, missing_indexes, missing_result)
        actual_calls = metric_calls(missing_result, length(missing_batch))

        case record_with_reservation(state.budget, actual_calls, reservation, kind) do
          {:ok, budget} ->
            cache = backend.put(state.cache, candidate, missing_batch, missing_result)
            notify_budget_updated(opts, state, budget, actual_calls, event.iteration)
            notify_evaluation_end(opts, result, event)
            {:ok, result, %{state | budget: budget, cache: cache}}

          {:error, reason, budget} ->
            {:error, reason, %{state | budget: budget}}
        end
      else
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp evaluate_fresh(adapter, batch, candidate, capture_traces, kind, state, opts, event) do
    reservation =
      Adapter.metric_call_reservation(
        adapter,
        batch,
        candidate,
        capture_traces: capture_traces
      )

    with :ok <- Budget.authorize_evaluation(state.budget, reservation, kind) do
      notify_evaluation_start(opts, batch, capture_traces, event)
      result = Evaluation.evaluate(adapter, batch, candidate, capture_traces: capture_traces)
      actual_calls = metric_calls(result, length(batch))

      case record_with_reservation(state.budget, actual_calls, reservation, kind) do
        {:ok, budget} ->
          cache_result = capture_traces or Keyword.get(opts, :cache_evaluation, true)
          cache = maybe_cache_result(state.cache, candidate, batch, result, cache_result)
          notify_budget_updated(opts, state, budget, actual_calls, event.iteration)
          notify_evaluation_end(opts, result, event)
          {:ok, result, %{state | budget: budget, cache: cache}}

        {:error, reason, budget} ->
          {:error, reason, %{state | budget: budget}}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp maybe_cache_result(cache, candidate, batch, result, true),
    do: evaluation_cache_backend(cache).put(cache, candidate, batch, result)

  defp maybe_cache_result(cache, _candidate, _batch, _result, false), do: cache

  defp record_with_reservation(budget, actual_calls, reservation, kind)
       when actual_calls <= reservation,
       do: Budget.record_evaluation(budget, actual_calls, kind)

  defp record_with_reservation(budget, actual_calls, reservation, kind) do
    {:ok, budget} = Budget.record_evaluation(budget, reservation, kind)

    {:error, {:metric_call_report_exceeds_reservation, actual_calls, reservation}, budget}
  end

  defp notify_evaluation_start(opts, batch, capture_traces, event) do
    notify(opts, :on_evaluation_start, %{
      iteration: event.iteration,
      candidate_idx: event.candidate_idx,
      batch_size: length(batch),
      capture_traces: capture_traces,
      parent_ids: event.parent_ids,
      inputs: batch,
      is_seed_candidate: event.is_seed_candidate
    })
  end

  defp metric_calls(%Result{metadata: metadata}, fallback) do
    case Map.get(metadata, :metric_calls, Map.get(metadata, "metric_calls")) do
      calls when is_integer(calls) and calls >= 0 -> calls
      _ -> fallback
    end
  end

  defp notify_evaluation_end(opts, result, event) do
    notify(opts, :on_evaluation_end, %{
      iteration: event.iteration,
      candidate_idx: event.candidate_idx,
      scores: result.scores,
      has_trajectories: has_trajectories?(result),
      parent_ids: event.parent_ids,
      outputs: result.outputs,
      trajectories: result.trajectories,
      objective_scores: result.objective_scores,
      is_seed_candidate: event.is_seed_candidate
    })
  end

  defp has_trajectories?(%Result{trajectories: trajectories}) do
    Enum.any?(trajectories, fn {_component, values} -> values != [] end)
  end

  defp notify_budget_updated(opts, old_state, budget, _delta, iteration) do
    remaining =
      case budget.max_metric_calls do
        :infinity -> nil
        limit -> max(limit - budget.metric_calls, 0)
      end

    notify(opts, :on_budget_updated, %{
      iteration: iteration,
      metric_calls_used: budget.metric_calls,
      metric_calls_delta: budget.metric_calls - old_state.budget.metric_calls,
      metric_calls_remaining: remaining
    })
  end

  defp propose_components_with_budget(
         proposer,
         parent,
         components,
         dataset,
         minibatch_ids,
         parent_result,
         next_component,
         iteration,
         state,
         opts
       ) do
    reservation = reflection_call_reservation(components, dataset, state.combee_policy)
    id = reservation_id(:reflection, iteration)

    with {:ok, ledger} <-
           BudgetLedger.reserve(state.budget_ledger, state.budget, id, %{
             reflection_calls: reservation
           }) do
      context = %Proposal.Context{
        slot: 0,
        iteration: iteration,
        parent_id: parent.id,
        minibatch_ids: minibatch_ids,
        parent_result: parent_result,
        action: :reflect,
        components: components,
        next_component: next_component,
        dataset: dataset
      }

      state = %{
        state
        | budget_ledger: ledger,
          pending_proposal_batch: Proposal.new_batch(:reflection, [context])
      }

      checkpoint!(state, opts)
      state = mark_batch_started!(state, opts)

      result =
        Enum.reduce_while(
          components,
          {:ok, %{}, [], state},
          fn component, {:ok, replacements, reports, state} ->
            case propose_component_with_budget(
                   proposer,
                   parent.candidate,
                   component,
                   dataset,
                   iteration,
                   state,
                   opts
                 ) do
              {:ok, text, report, state} ->
                {:cont,
                 {:ok, Map.put(replacements, component, text), append_report(reports, report),
                  state}}

              {:error, {:budget_exhausted, _, _, _} = reason, _report, state} ->
                {:halt, {:error, reason, state}}

              {:error, reason, _report, state} ->
                {:halt, {:error, {:component_proposal_error, reason, components}, state}}
            end
          end
        )

      finish_sequential_reflection(result, id, opts)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp finish_sequential_reflection(result, id, opts) do
    state = elem(result, tuple_size(result) - 1)
    {_reservation, ledger} = BudgetLedger.release(state.budget_ledger, id)
    state = %{state | budget_ledger: ledger, pending_proposal_batch: nil}
    checkpoint!(state, opts)
    put_elem(result, tuple_size(result) - 1, state)
  end

  defp propose_component_with_budget(
         proposer,
         candidate,
         component,
         dataset,
         iteration,
         state,
         opts
       ) do
    records = Map.get(dataset, component, [])
    reservation = ComBee.reflection_call_reservation(records, state.combee_policy)

    case Budget.authorize_reflections(state.budget, reservation) do
      :ok ->
        case ComBee.propose(
               proposer,
               candidate,
               component,
               records,
               iteration,
               state.combee_policy
             ) do
          {:ok, text, calls, report} ->
            state = record_reflection_result(state, calls, reservation, report, opts)
            {:ok, text, report, state}

          {:error, reason, calls, report} ->
            state = record_reflection_result(state, calls, reservation, report, opts)
            {:error, reason, report, state}
        end

      {:error, reason} ->
        {:error, reason, nil, state}
    end
  end

  defp record_reflection_result(state, calls, reservation, report, opts) do
    if calls > reservation do
      raise ArgumentError,
            "GEPA reflection report #{calls} exceeds preauthorization #{reservation}"
    end

    state = %{state | budget: Budget.record_reflections(state.budget, calls)}
    record_combee_reports(state, append_report([], report), opts)
  end

  defp record_combee_reports(state, reports, opts) do
    Enum.reduce(reports || [], state, fn report, state ->
      notify(opts, :on_combee_aggregation, %{
        iteration: report.iteration,
        component: report.component,
        report: report
      })

      %{state | combee_reports: state.combee_reports ++ [report]}
    end)
  end

  defp append_report(reports, nil), do: reports
  defp append_report(reports, report), do: reports ++ [report]

  defp reflection_call_reservation(components, dataset, combee_policy) do
    Enum.reduce(components, 0, fn component, total ->
      total +
        ComBee.reflection_call_reservation(Map.get(dataset, component, []), combee_policy)
    end)
  end

  defp build_reflective_dataset(adapter, parent, result, components) do
    {:ok, Adapter.make_reflective_dataset(adapter, parent.candidate, result, components)}
  rescue
    error -> {:error, {:reflective_dataset_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:reflective_dataset_throw, kind, reason}}
  end

  defp ensure_combee_policy!(%State{combee_policy: stored} = state, requested) do
    if stored.identity == requested.identity do
      state
    else
      raise ArgumentError,
            "GEPA resume ComBee policy mismatch: stored #{inspect(stored.identity)}, " <>
              "requested #{inspect(requested.identity)}"
    end
  end

  defp next_component(parent, opts) do
    if Keyword.get(opts, :module_selector, :round_robin) == :round_robin,
      do: parent.next_component + 1,
      else: parent.next_component
  end

  defp advance_component_cursor(state, candidate_id, next_component, opts) do
    if Keyword.get(opts, :module_selector, :round_robin) == :round_robin do
      candidates =
        List.update_at(state.candidates, candidate_id, &%{&1 | next_component: next_component})

      %{state | candidates: candidates}
    else
      state
    end
  end

  defp legacy_component([component]), do: component
  defp legacy_component(components), do: components

  defp frontier_candidates(candidates),
    do: Enum.map(candidates, &{&1.id, &1.validation})

  defp aggregate_scores(candidates),
    do: Map.new(candidates, &{&1.id, &1.validation.aggregate_score})

  defp result_validation_ids(%Result{scores: scores, metadata: metadata}) do
    Map.get(
      metadata,
      :validation_ids,
      Map.get(metadata, "validation_ids", indexes(length(scores)))
    )
  end

  defp indexes(0), do: []
  defp indexes(size), do: Enum.to_list(0..(size - 1))

  defp sample_batch(trainset, size, rng_state) do
    {decorated, rng_state} =
      trainset
      |> Enum.with_index()
      |> Enum.map_reduce(rng_state, fn {example, id}, rng_state ->
        {key, rng_state} = :rand.uniform_s(rng_state)
        {{key, id, example}, rng_state}
      end)

    sampled = decorated |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(size)
    batch = Enum.map(sampled, &elem(&1, 2))
    ids = Enum.map(sampled, &elem(&1, 1))
    {batch, ids, rng_state}
  end

  defp checkpoint!(state, opts) do
    emit_progress(state)

    case Keyword.get(opts, :checkpoint_fn) do
      nil ->
        :ok

      callback when is_function(callback, 1) ->
        case callback.(dump_state(state)) do
          :ok ->
            :ok

          other ->
            raise ArgumentError,
                  "GEPA checkpoint callback must return :ok, got: #{inspect(other)}"
        end
    end

    notify(opts, :on_state_saved, %{iteration: state.iteration, run_dir: nil})
  end

  defp check_stopper(state, opts) do
    case Keyword.get(opts, :stopper) do
      nil ->
        {:continue, state}

      policy ->
        stopper_state = state.stopper_state || Stopper.new(policy, stopper_opts(opts))

        context = %{
          iteration: state.iteration,
          metric_calls: state.budget.metric_calls,
          full_evaluations: state.budget.full_evaluations,
          reflection_calls: state.budget.reflection_calls,
          candidate_count: length(state.candidates),
          best_score: best(state).validation.aggregate_score
        }

        case Stopper.check(policy, stopper_state, context, stopper_opts(opts)) do
          {:continue, stopper_state} ->
            {:continue, %{state | stopper_state: stopper_state}}

          {:stop, reasons, stopper_state} ->
            {:stop, {:stopper, reasons}, %{state | stopper_state: stopper_state}}
        end
    end
  end

  defp new_stopper_state(opts) do
    case Keyword.get(opts, :stopper) do
      nil -> nil
      policy -> Stopper.new(policy, stopper_opts(opts))
    end
  end

  defp dump_stopper_state(nil), do: nil
  defp dump_stopper_state(%Stopper.State{} = state), do: Stopper.dump(state)

  defp load_stopper_state(nil, opts), do: new_stopper_state(opts)

  defp load_stopper_state(checkpoint, opts) do
    if Keyword.get(opts, :stopper) do
      Stopper.load!(checkpoint, stopper_opts(opts))
    else
      raise ArgumentError, "GEPA resume state contains stopper state but no :stopper policy"
    end
  end

  defp stopper_opts(opts) do
    case Keyword.fetch(opts, :stopper_now) do
      {:ok, now} -> [now: now]
      :error -> []
    end
  end

  defp emit_progress(%State{} = state) do
    candidate = List.last(state.candidates)

    DSEx.Telemetry.execute(
      [:dsex, :optimizer, :progress],
      %{
        completed_generations: state.iteration,
        candidate_count: length(state.candidates),
        metric_calls: state.budget.metric_calls,
        reflection_calls: state.budget.reflection_calls
      },
      %{
        optimizer: :gepa,
        candidate_id: if(candidate.id == 0, do: "baseline", else: "gepa-#{candidate.id}"),
        aggregate_score: candidate.validation.aggregate_score,
        stop_reason: state.stop_reason
      }
    )
  end

  defp notify_iteration_end(opts, iteration, state, candidate_count) do
    notify(opts, :on_iteration_end, %{
      iteration: iteration,
      state: state,
      proposal_accepted: length(state.candidates) > candidate_count
    })
  end

  defp notify_candidate_added(opts, state, entry, valset, iteration) do
    previous_candidates = Enum.drop(state.candidates, -1)

    previous_front =
      previous_candidates
      |> frontier_candidates()
      |> Frontier.candidate_ids(state.frontier_type)
      |> Enum.sort()

    new_front = state |> frontier() |> Enum.map(& &1.id) |> Enum.sort()

    notify(opts, :on_pareto_front_updated, %{
      iteration: iteration,
      new_front: new_front,
      displaced_candidates: previous_front -- new_front
    })

    notify_valset_evaluated(opts, state, entry, valset, iteration)
  end

  defp notify_valset_evaluated(opts, state, entry, valset, iteration) do
    ids = result_validation_ids(entry.validation)
    scores_by_val_id = ids |> Enum.zip(entry.validation.scores) |> Map.new()

    outputs_by_val_id =
      case entry.validation.outputs do
        [] -> nil
        outputs -> ids |> Enum.zip(outputs) |> Map.new()
      end

    notify(opts, :on_valset_evaluated, %{
      iteration: iteration,
      candidate_idx: entry.id,
      candidate: entry.candidate,
      scores_by_val_id: scores_by_val_id,
      average_score: entry.validation.aggregate_score,
      num_examples_evaluated: length(ids),
      total_valset_size: length(valset),
      parent_ids: entry.parent_ids,
      is_best_program: best(state).id == entry.id,
      outputs_by_val_id: outputs_by_val_id
    })
  end

  defp notify(opts, event, payload) do
    opts |> Keyword.get(:callbacks, []) |> Callback.notify(event, payload)
  end

  defp callback_config(opts) do
    Map.new(%{
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      minibatch_size:
        Keyword.get(opts, :effective_minibatch_size, Keyword.get(opts, :minibatch_size)),
      seed: Keyword.get(opts, :seed, 0),
      use_merge: Keyword.get(opts, :use_merge, false),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      candidate_selection_strategy: Keyword.get(opts, :candidate_selection_strategy, :pareto),
      module_selector: Keyword.get(opts, :module_selector, :round_robin),
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, false),
      perfect_score: Keyword.get(opts, :perfect_score),
      track_best_outputs: Keyword.get(opts, :track_best_outputs, false),
      cache_evaluation: Keyword.get(opts, :cache_evaluation, true),
      cache_evaluation_storage: Keyword.get(opts, :cache_evaluation_storage, :memory),
      max_metric_calls: Keyword.get(opts, :max_metric_calls, :infinity),
      max_full_evaluations: Keyword.get(opts, :max_full_evaluations, :infinity),
      max_reflection_calls: Keyword.get(opts, :max_reflection_calls, :infinity),
      proposal_concurrency: Keyword.get(opts, :proposal_concurrency, 1),
      proposal_timeout: Keyword.get(opts, :proposal_timeout, :infinity),
      combee: opts |> Keyword.fetch!(:combee_policy) |> ComBee.metadata()
    })
  end

  defp load_state!(
         %{"schema_version" => schema_version} = dumped,
         seed_candidate,
         opts
       )
       when schema_version in [1, 3, 4, 5] do
    budget = dumped |> Map.fetch!("budget") |> Budget.load!()

    budget =
      if schema_version == 1 do
        %{budget | max_reflection_calls: Keyword.get(opts, :max_reflection_calls, :infinity)}
      else
        budget
      end

    state = %State{
      iteration: Map.fetch!(dumped, "iteration"),
      candidates: Enum.map(Map.fetch!(dumped, "candidates"), &load_entry!/1),
      rejected: restore(Map.get(dumped, "rejected", [])),
      history: restore(Map.get(dumped, "history", [])),
      cache: load_evaluation_cache(Map.get(dumped, "cache", []), opts),
      budget: budget,
      rng_state: dumped |> Map.fetch!("rng_state") |> load_rng!(),
      merge_due: Map.get(dumped, "merge_due", 0),
      total_merges_tested: Map.get(dumped, "total_merges_tested", 0),
      merge_attempts:
        dumped |> Map.get("merge_attempts", %{ancestors: [], descriptions: []}) |> restore(),
      last_iteration_found_candidate: Map.get(dumped, "last_iteration_found_candidate", false),
      frontier_type: dumped |> Map.get("frontier_type", :instance) |> normalize_frontier_type!(),
      evaluation_policy: load_evaluation_policy(dumped, opts),
      best_outputs_valset: dumped |> Map.get("best_outputs_valset") |> load_best_outputs!(),
      stopper_state: dumped |> Map.get("stopper_state") |> load_stopper_state(opts),
      budget_ledger: dumped |> Map.get("budget_ledger", []) |> BudgetLedger.load!(),
      pending_proposal_batch:
        dumped
        |> Map.get("pending_proposal_batch")
        |> Proposal.load!(&load_result!/1),
      proposal_policy:
        load_proposal_policy(dumped, schema_version, Keyword.fetch!(opts, :proposal_policy)),
      combee_policy:
        load_combee_policy(dumped, schema_version, Keyword.fetch!(opts, :combee_policy)),
      combee_reports: dumped |> Map.get("combee_reports", []) |> Enum.map(&ComBee.load_report/1),
      stop_reason: restore(Map.get(dumped, "stop_reason"))
    }

    unless hd(state.candidates).candidate == seed_candidate do
      raise ArgumentError, "GEPA resume state does not match the seed candidate"
    end

    requested_metric_limit = Keyword.get(opts, :max_metric_calls, state.budget.max_metric_calls)

    requested_full_limit =
      Keyword.get(opts, :max_full_evaluations, state.budget.max_full_evaluations)

    requested_reflection_limit =
      Keyword.get(opts, :max_reflection_calls, state.budget.max_reflection_calls)

    unless requested_metric_limit == state.budget.max_metric_calls and
             requested_full_limit == state.budget.max_full_evaluations and
             requested_reflection_limit == state.budget.max_reflection_calls do
      raise ArgumentError, "GEPA resume budget limits do not match"
    end

    validate_pending_ledger!(state)
    validate_checkpoint_integrity!(dumped, schema_version)

    %{state | stop_reason: nil}
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid GEPA engine resume state: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp load_state!(
         %{"schema_version" => 2, "phase" => "evolution", "candidates" => candidates} = dumped,
         seed_candidate,
         opts
       )
       when is_list(candidates) and candidates != [] do
    if Keyword.fetch!(opts, :combee_policy).enabled do
      raise ArgumentError, "GEPA resume ComBee policy mismatch: legacy checkpoint is disabled"
    end

    id_to_index =
      candidates
      |> Enum.with_index()
      |> Map.new(fn {candidate, index} -> {Map.fetch!(candidate, "id"), index} end)

    entries =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} ->
        scores = Map.fetch!(candidate, "per_example_scores")
        named_candidate = legacy_named_candidate(candidate, seed_candidate)

        validation =
          Result.new(List.duplicate(nil, length(scores)), scores,
            side_information: legacy_side_information(candidate, named_candidate),
            metadata: %{legacy_checkpoint_migration: true, metric_calls: length(scores)}
          )

        parent = Map.get(candidate, "parent_id")

        %Entry{
          id: index,
          candidate: named_candidate,
          validation: validation,
          parent_ids: if(is_binary(parent), do: [Map.fetch!(id_to_index, parent)], else: []),
          next_component: max(index, 0),
          discovered_at:
            Enum.sum(
              Enum.map(Enum.take(candidates, index + 1), &length(&1["per_example_scores"]))
            )
        }
      end)

    metric_calls = Enum.sum(Enum.map(candidates, &length(&1["per_example_scores"])))
    full_evaluations = length(candidates)
    metric_limit = Keyword.get(opts, :max_metric_calls, :infinity)
    full_limit = Keyword.get(opts, :max_full_evaluations, :infinity)

    budget =
      Budget.load!(%{
        "max_metric_calls" => checkpoint_limit(metric_limit),
        "max_full_evaluations" => checkpoint_limit(full_limit),
        "max_reflection_calls" =>
          checkpoint_limit(Keyword.get(opts, :max_reflection_calls, :infinity)),
        "metric_calls" => metric_calls,
        "full_evaluations" => full_evaluations,
        "reflection_calls" => max(length(candidates) - 1, 0)
      })

    unless hd(entries).candidate == seed_candidate do
      raise ArgumentError, "legacy GEPA resume state does not match the seed candidate"
    end

    %State{
      iteration: length(entries) - 1,
      candidates: entries,
      rejected: [],
      history: [%{status: :legacy_checkpoint_migrated, candidates: length(entries)}],
      cache: new_evaluation_cache(opts),
      budget: budget,
      rng_state: dumped |> Map.fetch!("rng_state") |> load_rng!(),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      evaluation_policy:
        opts |> Keyword.get(:evaluation_policy, :full) |> EvaluationPolicy.resolve!(),
      stopper_state: new_stopper_state(opts),
      proposal_policy: Keyword.fetch!(opts, :proposal_policy),
      combee_policy: Keyword.fetch!(opts, :combee_policy),
      stop_reason: nil
    }
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid legacy GEPA resume state: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp load_state!(state, _seed_candidate, _opts),
    do: raise(ArgumentError, "invalid GEPA engine resume state: #{inspect(state)}")

  defp dump_entry(%Entry{} = entry) do
    %{
      "id" => entry.id,
      "candidate" => DSEx.Optimizer.Report.json_safe(entry.candidate),
      "validation" => dump_result(entry.validation),
      "parent_ids" => entry.parent_ids,
      "next_component" => entry.next_component,
      "discovered_at" => entry.discovered_at
    }
  end

  defp load_entry!(entry) do
    %Entry{
      id: Map.fetch!(entry, "id"),
      candidate: restore(Map.fetch!(entry, "candidate")),
      validation: entry |> Map.fetch!("validation") |> load_result!(),
      parent_ids: Map.get(entry, "parent_ids", []),
      next_component: Map.get(entry, "next_component", 0),
      discovered_at: Map.get(entry, "discovered_at", 0)
    }
  end

  defp dump_result(%Result{} = result) do
    %{
      "outputs" => Enum.map(result.outputs, &dump_runtime_term/1),
      "aggregate_score" => result.aggregate_score,
      "scores" => result.scores,
      "objective_scores" => DSEx.Optimizer.Report.json_safe(result.objective_scores),
      "trajectories" =>
        Map.new(result.trajectories, fn {component, trajectories} ->
          {component, Enum.map(trajectories, &dump_runtime_term/1)}
        end)
        |> DSEx.Optimizer.Report.json_safe(),
      "side_information" => DSEx.Optimizer.Report.json_safe(result.side_information),
      "metadata" => DSEx.Optimizer.Report.json_safe(result.metadata)
    }
  end

  defp load_result!(result) do
    %Result{
      outputs: Enum.map(Map.fetch!(result, "outputs"), &load_runtime_term/1),
      aggregate_score: Map.fetch!(result, "aggregate_score"),
      scores: Map.fetch!(result, "scores"),
      objective_scores: restore(Map.get(result, "objective_scores")),
      trajectories:
        result
        |> Map.fetch!("trajectories")
        |> restore()
        |> Map.new(fn {component, trajectories} ->
          {component, Enum.map(trajectories, &load_runtime_term/1)}
        end),
      side_information: result |> Map.fetch!("side_information") |> restore(),
      metadata: result |> Map.fetch!("metadata") |> restore()
    }
  end

  defp dump_best_outputs(nil), do: nil

  defp dump_best_outputs(best_outputs) do
    best_outputs
    |> Enum.sort_by(fn {validation_id, _outputs} -> inspect(validation_id) end)
    |> Enum.map(fn {validation_id, outputs} ->
      %{
        "validation_id" => dump_runtime_term(validation_id),
        "outputs" =>
          Enum.map(outputs, fn {candidate_id, output} ->
            %{"candidate_id" => candidate_id, "output" => dump_runtime_term(output)}
          end)
      }
    end)
  end

  defp load_best_outputs!(nil), do: nil

  defp load_best_outputs!(entries) when is_list(entries) do
    Map.new(entries, fn entry ->
      validation_id = entry |> Map.fetch!("validation_id") |> load_runtime_term()

      outputs =
        entry
        |> Map.fetch!("outputs")
        |> Enum.map(fn output ->
          {Map.fetch!(output, "candidate_id"),
           output |> Map.fetch!("output") |> load_runtime_term()}
        end)

      {validation_id, outputs}
    end)
  end

  defp load_best_outputs!(value) do
    raise ArgumentError, "invalid GEPA best validation outputs: #{inspect(value)}"
  end

  defp dump_cache(%DiskEvaluationCache{}), do: []

  defp dump_cache(cache) do
    Enum.map(cache, fn {{candidate_digest, example_digest}, %EvaluationCache.Entry{} = entry} ->
      %{
        "cache_version" => 2,
        "candidate_digest" => Base.encode16(candidate_digest, case: :lower),
        "example_digest" => Base.encode16(example_digest, case: :lower),
        "output" => dump_runtime_term(entry.output),
        "score" => entry.score,
        "objective_scores" => DSEx.Optimizer.Report.json_safe(entry.objective_scores)
      }
    end)
  end

  defp load_cache(entries) do
    Enum.reduce(entries, %{}, &load_cache_entry/2)
  end

  defp new_evaluation_cache(opts) do
    case Keyword.get(opts, :cache_evaluation_storage, :memory) do
      :memory -> %{}
      {:disk, run_dir} -> DiskEvaluationCache.new(run_dir)
    end
  end

  defp load_evaluation_cache(entries, opts) do
    case Keyword.get(opts, :cache_evaluation_storage, :memory) do
      :memory -> load_cache(entries)
      {:disk, run_dir} -> DiskEvaluationCache.new(run_dir)
    end
  end

  defp evaluation_cache_backend(%DiskEvaluationCache{}), do: DiskEvaluationCache
  defp evaluation_cache_backend(cache) when is_map(cache), do: EvaluationCache

  defp load_cache_entry(
         %{
           "cache_version" => 2,
           "candidate_digest" => candidate_digest,
           "example_digest" => example_digest,
           "output" => output,
           "score" => score
         } = entry,
         cache
       ) do
    key = {decode_digest!(candidate_digest), decode_digest!(example_digest)}

    Map.put(cache, key, %EvaluationCache.Entry{
      output: load_runtime_term(output),
      score: score,
      objective_scores: restore(Map.get(entry, "objective_scores"))
    })
  end

  defp load_cache_entry(entry, cache) do
    entry = restore(entry)
    candidate = fetch_any!(entry, :candidate)
    batch = fetch_any!(entry, :batch)
    result = entry |> fetch_any!(:result) |> normalize_string_keys() |> load_result!()
    EvaluationCache.put(cache, candidate, batch, result)
  end

  defp decode_digest!(digest) when is_binary(digest) do
    case Base.decode16(digest, case: :mixed) do
      {:ok, decoded} when byte_size(decoded) == 32 -> decoded
      _ -> raise ArgumentError, "invalid GEPA evaluation-cache digest"
    end
  end

  defp fetch_any!(map, key), do: Map.fetch!(map, key)

  defp normalize_string_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp dump_runtime_term(nil), do: nil

  defp dump_runtime_term(%DSEx.Prediction{} = prediction) do
    %{
      "__gepa_type__" => "prediction",
      "fields" => DSEx.Optimizer.Report.json_safe(prediction.fields),
      "completions" => DSEx.Optimizer.Report.json_safe(prediction.completions),
      "score" => prediction.score,
      "metadata" => DSEx.Optimizer.Report.json_safe(prediction.metadata)
    }
  end

  defp dump_runtime_term(%Trajectory{} = trajectory) do
    %{
      "__gepa_type__" => "trajectory",
      "state" => Trajectory.dump(trajectory)
    }
  end

  defp dump_runtime_term(term), do: DSEx.Optimizer.Report.json_safe(term)

  defp load_runtime_term(%{"__gepa_type__" => "prediction"} = state) do
    DSEx.Prediction.new(restore(Map.fetch!(state, "fields")),
      completions: restore(Map.get(state, "completions", [])),
      score: Map.get(state, "score"),
      metadata: restore(Map.get(state, "metadata", %{}))
    )
  end

  defp load_runtime_term(%{"__gepa_type__" => "trajectory", "state" => state}) do
    if state["type"] == "dsex_optimizer_trajectory" do
      Trajectory.load!(state)
    else
      state = restore(state)
      state = Map.update!(state, :prediction, &load_runtime_term/1)
      struct!(Trajectory, state)
    end
  end

  defp load_runtime_term(term), do: restore(term)

  defp legacy_named_candidate(candidate, seed_candidate) do
    parameters = candidate |> Map.fetch!("artifact") |> Map.fetch!("parameters")

    Map.new(seed_candidate, fn {component, fallback} ->
      value = Map.get(parameters, component, Map.get(parameters, to_string(component), fallback))
      {component, value}
    end)
  end

  defp legacy_side_information(candidate, named_candidate) do
    information = Map.get(candidate, "asi", []) ++ Map.get(candidate, "diagnostics", [])
    Map.new(named_candidate, fn {component, _text} -> {component, information} end)
  end

  defp checkpoint_limit(:infinity), do: "infinity"
  defp checkpoint_limit(limit), do: limit

  defp normalize_frontier_type!(type) when type in [:instance, :objective, :hybrid, :cartesian],
    do: type

  defp normalize_frontier_type!(type)
       when type in ["instance", "objective", "hybrid", "cartesian"],
       do: String.to_existing_atom(type)

  defp normalize_frontier_type!(type),
    do: raise(ArgumentError, "invalid GEPA frontier type in resume state: #{inspect(type)}")

  defp load_evaluation_policy(dumped, opts) do
    policy = opts |> Keyword.get(:evaluation_policy, :full) |> EvaluationPolicy.resolve!()

    case Map.get(dumped, "evaluation_policy") do
      nil ->
        policy

      stored ->
        if stored == Atom.to_string(policy),
          do: policy,
          else: raise(ArgumentError, "GEPA resume evaluation policy mismatch: #{inspect(stored)}")
    end
  end

  defp restore(value), do: DSEx.Optimizer.Report.restore_json_safe(value)

  defp dump_rng(rng_state) do
    {:exsss, [first | second]} = :rand.export_seed_s(rng_state)
    %{"algorithm" => "exsss", "words" => [first, second]}
  end

  defp load_rng!(%{"algorithm" => "exsss", "words" => [first, second]})
       when is_integer(first) and is_integer(second),
       do: :rand.seed_s({:exsss, [first | second]})

  defp load_rng!(value), do: raise(ArgumentError, "invalid GEPA RNG state: #{inspect(value)}")
  defp seed_rng(seed), do: :rand.seed_s(:exsss, {seed + 1, seed + 2, seed + 3})

  defp iteration_range(first, last) when first <= last, do: first..last
  defp iteration_range(_first, _last), do: []

  defp score(nil), do: nil
  defp score(%Result{aggregate_score: score}), do: score
  defp side_information(nil), do: %{}
  defp side_information(%Result{side_information: information}), do: information

  defp validate_inputs!(candidate, trainset, valset, opts) do
    if map_size(candidate) == 0, do: raise(ArgumentError, "GEPA seed candidate cannot be empty")
    if trainset == [], do: raise(ArgumentError, "GEPA trainset cannot be empty")
    if valset == [], do: raise(ArgumentError, "GEPA valset cannot be empty")

    max_iterations = Keyword.get(opts, :max_iterations, 10)
    minibatch_size = Keyword.get(opts, :minibatch_size, min(3, length(trainset)))
    seed = Keyword.get(opts, :seed, 0)

    unless is_integer(max_iterations) and max_iterations >= 0,
      do: raise(ArgumentError, ":max_iterations must be a non-negative integer")

    unless is_integer(minibatch_size) and minibatch_size > 0 and
             minibatch_size <= length(trainset),
           do: raise(ArgumentError, ":minibatch_size must fit within the trainset")

    unless is_integer(seed) and seed >= 0,
      do: raise(ArgumentError, ":seed must be a non-negative integer")

    use_merge = Keyword.get(opts, :use_merge, false)
    max_merge_invocations = Keyword.get(opts, :max_merge_invocations, 5)
    merge_val_overlap_floor = Keyword.get(opts, :merge_val_overlap_floor, 5)
    merge_subsample_size = Keyword.get(opts, :merge_subsample_size, 5)
    frontier_type = Keyword.get(opts, :frontier_type, :instance)
    cache_evaluation = Keyword.get(opts, :cache_evaluation, true)
    cache_evaluation_storage = Keyword.get(opts, :cache_evaluation_storage, :memory)
    skip_perfect_score = Keyword.get(opts, :skip_perfect_score, false)
    perfect_score = Keyword.get(opts, :perfect_score)
    track_best_outputs = Keyword.get(opts, :track_best_outputs, false)
    acceptance_policy = Keyword.get(opts, :acceptance_policy, Acceptance.default(:mutation))
    max_reflection_calls = Keyword.get(opts, :max_reflection_calls, :infinity)
    proposal_concurrency = Keyword.get(opts, :proposal_concurrency, 1)
    proposal_timeout = Keyword.get(opts, :proposal_timeout, :infinity)

    merge_acceptance_policy =
      Keyword.get(opts, :merge_acceptance_policy, Acceptance.default(:merge))

    case Callback.validate(Keyword.get(opts, :callbacks, [])) do
      {:ok, _callbacks} -> :ok
      {:error, message} -> raise ArgumentError, ":callbacks #{message}"
    end

    EvaluationPolicy.resolve!(Keyword.get(opts, :evaluation_policy, :full))
    CandidateSelector.validate!(Keyword.get(opts, :candidate_selection_strategy, :pareto))
    ModuleSelector.validate!(Keyword.get(opts, :module_selector, :round_robin))

    unless max_reflection_calls == :infinity or
             (is_integer(max_reflection_calls) and max_reflection_calls >= 0) do
      raise ArgumentError,
            ":max_reflection_calls must be a non-negative integer or :infinity"
    end

    unless proposal_concurrency == :auto or
             (is_integer(proposal_concurrency) and proposal_concurrency > 0) do
      raise ArgumentError, ":proposal_concurrency must be :auto or a positive integer"
    end

    unless proposal_timeout == :infinity or
             (is_integer(proposal_timeout) and proposal_timeout > 0) do
      raise ArgumentError, ":proposal_timeout must be :infinity or a positive integer"
    end

    unless is_boolean(use_merge), do: raise(ArgumentError, ":use_merge must be a boolean")

    unless is_boolean(cache_evaluation),
      do: raise(ArgumentError, ":cache_evaluation must be a boolean")

    unless valid_cache_storage?(cache_evaluation_storage) do
      raise ArgumentError,
            ":cache_evaluation_storage must be :memory or {:disk, run_dir}"
    end

    validate_policy_options!(skip_perfect_score, perfect_score, track_best_outputs)

    unless is_integer(max_merge_invocations) and max_merge_invocations >= 0,
      do: raise(ArgumentError, ":max_merge_invocations must be a non-negative integer")

    unless is_integer(merge_val_overlap_floor) and merge_val_overlap_floor > 0,
      do: raise(ArgumentError, ":merge_val_overlap_floor must be a positive integer")

    unless is_integer(merge_subsample_size) and merge_subsample_size > 0,
      do: raise(ArgumentError, ":merge_subsample_size must be a positive integer")

    unless frontier_type in [:instance, :objective, :hybrid, :cartesian],
      do:
        raise(
          ArgumentError,
          ":frontier_type must be :instance, :objective, :hybrid, or :cartesian"
        )

    validate_acceptance_policy!(acceptance_policy, :acceptance_policy)
    validate_acceptance_policy!(merge_acceptance_policy, :merge_acceptance_policy)
  end

  defp valid_cache_storage?(:memory), do: true
  defp valid_cache_storage?({:disk, run_dir}) when is_binary(run_dir), do: run_dir != ""
  defp valid_cache_storage?(_storage), do: false

  defp validate_policy_options!(skip_perfect_score, perfect_score, track_best_outputs) do
    unless is_boolean(skip_perfect_score),
      do: raise(ArgumentError, ":skip_perfect_score must be a boolean")

    unless is_boolean(track_best_outputs),
      do: raise(ArgumentError, ":track_best_outputs must be a boolean")

    unless is_nil(perfect_score) or is_number(perfect_score),
      do: raise(ArgumentError, ":perfect_score must be nil or a number")

    if skip_perfect_score and not is_number(perfect_score),
      do: raise(ArgumentError, ":perfect_score must be numeric when :skip_perfect_score is true")
  end

  defp validate_acceptance_policy!(policy, _name)
       when policy in [:strict_improvement, :equal_or_better],
       do: :ok

  defp validate_acceptance_policy!({:callback, callback}, _name)
       when is_function(callback, 1),
       do: :ok

  defp validate_acceptance_policy!(policy, name) do
    raise ArgumentError,
          "#{inspect(name)} must be :strict_improvement, :equal_or_better, or an Acceptance callback; got: #{inspect(policy)}"
  end
end

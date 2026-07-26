defmodule Imp.Optimizer.GEPA.Engine do
  @moduledoc false

  alias Imp.Optimizer.GEPA.{
    Acceptance,
    Adapter,
    BatchSampler,
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
    ProposalSelection,
    Random,
    Reflection,
    ReflectionStrategy,
    Result,
    Stopper
  }

  alias Imp.Optimizer.GEPA.EvaluationCache.Disk, as: DiskEvaluationCache
  alias Imp.Optimizer.Trajectory

  defmodule Entry do
    @moduledoc false
    @enforce_keys [:id, :candidate, :validation]
    defstruct [:id, :candidate, :validation, parent_ids: [], next_component: 0, discovered_at: 0]

    @type t :: %__MODULE__{}
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
              pending_validation: nil,
              proposal_policy: %{
                requested: 1,
                resolved: 1,
                timeout: :infinity,
                strategy_configuration: %{
                  sampling_strategy: :single,
                  selection_strategy: :all_improvements,
                  acceptance_policy: :strict_improvement
                }
              },
              combee_policy: nil,
              combee_reports: [],
              adapter_state: %{},
              batch_sampler: %BatchSampler{},
              reflection_strategy: nil,
              reflection_strategy_initial: nil,
              stop_reason: nil

    @type t :: %__MODULE__{}
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

    opts =
      Keyword.put(
        opts,
        :reflection_strategy,
        ReflectionStrategy.validate!(opts[:reflection_strategy])
      )

    validate_inputs!(seed_candidate, trainset, valset, opts)
    requested_minibatch_size = requested_minibatch_size(opts, length(trainset))

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
        Imp.Settings.snapshot() |> Map.fetch!(:async_max_workers),
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

    opts = Keyword.put(opts, :runtime_adapter, adapter)

    {state, adapter} =
      case Keyword.get(opts, :resume_state) do
        nil ->
          {initialize(adapter, seed_candidate, valset, opts), adapter}

        resume_state ->
          state = load_state!(resume_state, seed_candidate, opts)
          {state, Adapter.restore_state(adapter, state.adapter_state)}
      end

    opts = Keyword.put(opts, :runtime_adapter, adapter)

    state =
      state
      |> ensure_proposal_policy!(proposal_policy)
      |> ensure_combee_policy!(combee_policy)

    state = bind_sampler_before_profile(state, trainset, minibatch_size)
    state = recover_interrupted_validation!(state, opts)

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

    state = bind_sampler_after_profile(state, trainset, minibatch_size)

    strategy_path? = strategy_path?(opts, proposal_policy)

    state =
      if strategy_path? do
        state =
          if state.pending_proposal_batch do
            run_parallel_loop(
              adapter,
              trainset,
              valset,
              proposer,
              minibatch_size,
              max_iterations,
              state,
              Keyword.put(opts, :drain_pending_only, true)
            )
          else
            state
          end

        run_strategy_loop(
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
      end

    state = finalize_stop_reason(state, max_iterations, opts)

    state = snapshot_adapter_state(state, opts)
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
        case check_stopper(state, opts) do
          {:stop, reason, state} -> profile_stopped(state, opts, report, reason)
          {:continue, state} -> profile_stopped(state, opts, report, :max_iterations)
        end

      true ->
        batch_size = ComBee.BatchController.next_batch_size(report)
        iteration = state.iteration + 1
        state = reconfigure_profile_sampler(state, trainset, batch_size)
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

  defp bind_sampler_before_profile(state, trainset, minibatch_size) do
    sampler =
      if runtime_profile?(state.combee_policy) do
        BatchSampler.bind_trainset!(state.batch_sampler, trainset)
      else
        BatchSampler.bind!(state.batch_sampler, minibatch_size, trainset)
      end

    %{state | batch_sampler: sampler}
  end

  defp bind_sampler_after_profile(state, trainset, minibatch_size) do
    sampler =
      if runtime_profile?(state.combee_policy) do
        BatchSampler.reconfigure!(state.batch_sampler, minibatch_size, trainset)
      else
        BatchSampler.bind!(state.batch_sampler, minibatch_size, trainset)
      end

    %{state | batch_sampler: sampler}
  end

  defp reconfigure_profile_sampler(state, trainset, minibatch_size) do
    sampler = BatchSampler.reconfigure!(state.batch_sampler, minibatch_size, trainset)
    %{state | batch_sampler: sampler}
  end

  defp runtime_profile?(%ComBee.Policy{
         batch_controller: %ComBee.BatchController.Report{mode: :runtime}
       }),
       do: true

  defp runtime_profile?(_policy), do: false

  defp strategy_path?(opts, proposal_policy) do
    if Keyword.get(opts, :execution_profile, :beam_native) == :gepa_v0_1_4 do
      false
    else
      strategy_path_for_beam?(opts, proposal_policy)
    end
  end

  defp strategy_path_for_beam?(opts, proposal_policy) do
    configured? =
      Keyword.has_key?(opts, :sampling_strategy) or Keyword.has_key?(opts, :selection_strategy) or
        not is_nil(Keyword.get(opts, :reflection_strategy))

    default_speculative? =
      proposal_policy.resolved > 1 and
        Keyword.get(opts, :sampling_strategy, :single) == :single and
        Keyword.get(opts, :selection_strategy, :all_improvements) == :all_improvements and
        is_nil(Keyword.get(opts, :reflection_strategy))

    configured? and not default_speculative?
  end

  defp profile_deadline(%ComBee.BatchController.Report{profiling_timeout: :infinity}),
    do: :infinity

  defp profile_deadline(report) do
    remaining = max(report.profiling_timeout - ceil(report.elapsed_ms), 0)
    Coordinator.deadline(remaining)
  end

  defp profile_deadline_elapsed?(:infinity), do: false

  defp profile_deadline_elapsed?(deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  defp run_strategy_loop(
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

      true ->
        case check_stopper(state, opts) do
          {:stop, reason, state} ->
            state = %{state | stop_reason: reason}
            checkpoint!(state, opts)
            state

          {:continue, state} ->
            iteration = state.iteration + 1

            result =
              if merge_scheduled?(state, opts) do
                case attempt_merge(adapter, valset, iteration, state, opts) do
                  {:none, state} ->
                    run_strategy_iteration(
                      adapter,
                      trainset,
                      valset,
                      proposer,
                      minibatch_size,
                      iteration,
                      state,
                      opts
                    )

                  result ->
                    result
                end
              else
                run_strategy_iteration(
                  adapter,
                  trainset,
                  valset,
                  proposer,
                  minibatch_size,
                  iteration,
                  state,
                  opts
                )
              end

            case result do
              {:ok, state} ->
                run_strategy_loop(
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
                %{state | stop_reason: reason}
            end
        end
    end
  end

  defp run_strategy_iteration(
         adapter,
         trainset,
         valset,
         proposer,
         minibatch_size,
         iteration,
         state,
         opts
       ) do
    checkpoint!(state, opts)

    notify(opts, :on_iteration_start, %{
      iteration: iteration,
      state: state,
      trainset_loader: trainset
    })

    candidate_count = length(state.candidates)
    state = %{state | last_iteration_found_candidate: false}

    try do
      with {:ok, tasks, state} <-
             sample_strategy_tasks(trainset, minibatch_size, iteration, state, opts),
           {:ok, parent_results, state} <-
             evaluate_strategy_parents(adapter, trainset, tasks, state, opts),
           {:ok, prepared, state} <-
             prepare_strategy_reflections(tasks, parent_results, state, adapter, opts),
           {:ok, reflected, state} <-
             execute_strategy_reflections(prepared, proposer, state, opts),
           {:ok, proposals, state} <-
             evaluate_strategy_children(adapter, trainset, reflected, state, opts),
           {:ok, state} <-
             select_and_add_strategy_proposals(adapter, valset, proposals, state, opts) do
        state = %{state | iteration: iteration}
        notify_iteration_end(opts, iteration, state, candidate_count)
        checkpoint!(state, opts)
        {:ok, state}
      else
        {:stop, reason, state} ->
          state = %{state | iteration: iteration, stop_reason: reason}
          notify_iteration_end(opts, iteration, state, candidate_count)
          checkpoint!(state, opts)
          {:stop, reason, state}

        {:ambiguous_evaluation, kind, reason, stacktrace, state} ->
          handle_ambiguous_strategy_evaluation(
            kind,
            reason,
            stacktrace,
            iteration,
            candidate_count,
            state,
            opts
          )
      end
    rescue
      exception ->
        continue? = not Keyword.get(opts, :raise_on_exception, true)

        notify(opts, :on_error, %{
          iteration: iteration,
          exception: exception,
          will_continue: continue?
        })

        if continue? do
          state = %{state | iteration: iteration}
          notify_iteration_end(opts, iteration, state, candidate_count)
          checkpoint!(state, opts)
          {:ok, state}
        else
          reraise exception, __STACKTRACE__
        end
    end
  end

  defp handle_ambiguous_strategy_evaluation(
         kind,
         reason,
         stacktrace,
         iteration,
         candidate_count,
         state,
         opts
       ) do
    continue? = not Keyword.get(opts, :raise_on_exception, true)
    exception = if kind == :error, do: reason, else: {kind, reason}

    notify(opts, :on_error, %{
      iteration: iteration,
      exception: exception,
      will_continue: continue?
    })

    if continue? do
      state = %{state | iteration: iteration}
      notify_iteration_end(opts, iteration, state, candidate_count)
      checkpoint!(state, opts)
      {:ok, state}
    else
      :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp sample_strategy_tasks(trainset, minibatch_size, iteration, state, opts) do
    strategy = Keyword.get(opts, :sampling_strategy, :single)
    width = state.proposal_policy.resolved

    {parents, mutations} =
      case strategy do
        :single ->
          {1, 1}

        {:same_parent, n} ->
          {1, min(n, width)}

        {:independent, n} ->
          {min(n, width), 1}

        {:pxn, p, n} ->
          parents = min(p, width)
          {parents, min(n, max(1, div(width, parents)))}
      end

    {groups, state} =
      sample_strategy_groups(parents, mutations, trainset, minibatch_size, state, opts)

    tasks =
      groups
      |> Enum.flat_map(fn {parent, batches} ->
        Enum.map(batches, &{parent, &1})
      end)
      |> Enum.with_index()
      |> Enum.map(fn {{parent, {batch, ids}}, slot} ->
        %{
          slot: slot,
          iteration: iteration,
          parent: parent,
          minibatch: batch,
          minibatch_ids: ids
        }
      end)

    {:ok, tasks, state}
  end

  defp sample_strategy_groups(count, mutations, trainset, minibatch_size, state, opts) do
    Enum.map_reduce(1..count, state, fn _index, state ->
      {parent, rng_state} =
        opts
        |> Keyword.get(:candidate_selection_strategy, :pareto)
        |> CandidateSelector.select(state)

      {batches, batch_sampler, rng_state} =
        BatchSampler.next_batches(
          state.batch_sampler,
          trainset,
          minibatch_size,
          mutations,
          state.iteration,
          rng_state
        )

      {{parent, batches}, %{state | batch_sampler: batch_sampler, rng_state: rng_state}}
    end)
  end

  defp evaluate_strategy_parents(adapter, trainset, tasks, state, opts) do
    unique = Enum.uniq_by(tasks, &{&1.parent.candidate, &1.minibatch_ids})

    Enum.each(tasks, fn task ->
      notify(opts, :on_candidate_selected, %{
        iteration: task.iteration,
        candidate_idx: task.parent.id,
        candidate: task.parent.candidate,
        score: task.parent.validation.aggregate_score
      })

      notify(opts, :on_minibatch_sampled, %{
        iteration: task.iteration,
        minibatch_ids: task.minibatch_ids,
        trainset_size: length(trainset)
      })

      notify_evaluation_start(opts, task.minibatch, true, %{
        iteration: task.iteration,
        candidate_idx: task.parent.id,
        parent_ids: task.parent.parent_ids,
        is_seed_candidate: task.parent.id == 0
      })
    end)

    reservation =
      Enum.sum(
        Enum.map(unique, fn task ->
          Adapter.metric_call_reservation(
            adapter,
            task.minibatch,
            task.parent.candidate,
            capture_traces: true
          )
        end)
      )

    with :ok <- Budget.authorize_evaluation(state.budget, reservation, :minibatch) do
      items = Enum.map(unique, &{&1.parent.candidate, &1.minibatch})

      case guarded_batch_evaluate(
             adapter,
             items,
             [
               capture_traces: true,
               deadline: Coordinator.deadline(Keyword.get(opts, :proposal_timeout, :infinity))
             ],
             fn _kind, _reason ->
               consume_ambiguous_evaluation(
                 state,
                 reservation,
                 :minibatch,
                 hd(tasks).iteration,
                 opts
               )
             end
           ) do
        {:ok, results} ->
          actual =
            Enum.sum(Enum.zip_with(results, unique, &metric_calls(&1, length(&2.minibatch))))

          case record_with_reservation(state.budget, actual, reservation, :minibatch) do
            {:ok, budget} ->
              keyed =
                unique
                |> Enum.zip(results)
                |> Map.new(fn {task, result} ->
                  {{task.parent.candidate, task.minibatch_ids}, result}
                end)

              cache =
                Enum.reduce(unique, state.cache, fn task, cache ->
                  result = Map.fetch!(keyed, {task.parent.candidate, task.minibatch_ids})
                  maybe_cache_result(cache, task.parent.candidate, task.minibatch, result, true)
                end)

              Enum.each(tasks, fn task ->
                result = Map.fetch!(keyed, {task.parent.candidate, task.minibatch_ids})

                notify_evaluation_end(opts, result, %{
                  iteration: task.iteration,
                  candidate_idx: task.parent.id,
                  parent_ids: task.parent.parent_ids,
                  is_seed_candidate: task.parent.id == 0
                })
              end)

              notify_budget_updated(opts, state, budget, actual, hd(tasks).iteration)
              {:ok, keyed, %{state | budget: budget, cache: cache}}

            {:error, reason, budget} ->
              {:stop, reason, %{state | budget: budget}}
          end

        {:ambiguous_evaluation, _kind, _reason, _stacktrace, _state} = ambiguous ->
          ambiguous
      end
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp prepare_strategy_reflections(tasks, parent_results, state, adapter, opts) do
    Enum.reduce(tasks, {:ok, [], state}, fn task, {:ok, prepared, state} ->
      result = Map.fetch!(parent_results, {task.parent.candidate, task.minibatch_ids})

      cond do
        incomplete_evaluation?(result) ->
          notify(opts, :on_evaluation_skipped, %{
            iteration: task.iteration,
            candidate_idx: task.parent.id,
            reason: incomplete_evaluation_reason(result),
            scores: result.scores,
            is_seed_candidate: task.parent.id == 0
          })

          {:ok, prepared, state}

        not has_trajectories?(result) ->
          notify(opts, :on_evaluation_skipped, %{
            iteration: task.iteration,
            candidate_idx: task.parent.id,
            reason: :no_trajectories,
            scores: result.scores,
            is_seed_candidate: task.parent.id == 0
          })

          {:ok, prepared, state}

        perfect_result?(result, opts) ->
          notify(opts, :on_evaluation_skipped, %{
            iteration: task.iteration,
            candidate_idx: task.parent.id,
            reason: :all_scores_perfect,
            scores: result.scores,
            is_seed_candidate: task.parent.id == 0
          })

          {:ok, prepared, state}

        true ->
          components =
            ModuleSelector.select(
              Keyword.get(opts, :module_selector, :round_robin),
              state,
              result.trajectories,
              result.scores,
              task.parent.id,
              task.parent.candidate
            )

          next_component = next_component(task.parent, opts)
          state = advance_component_cursor(state, task.parent.id, next_component, opts)

          case make_strategy_reflective_dataset(
                 adapter,
                 task.parent.candidate,
                 result,
                 components,
                 opts
               ) do
            {:ok, dataset} ->
              notify(opts, :on_reflective_dataset_built, %{
                iteration: task.iteration,
                candidate_idx: task.parent.id,
                components: components,
                dataset: dataset
              })

              notify(opts, :on_proposal_start, %{
                iteration: task.iteration,
                parent_candidate: task.parent.candidate,
                components: components,
                reflective_dataset: dataset,
                aggregation: ComBee.metadata(state.combee_policy)
              })

              context =
                task
                |> Map.merge(%{
                  parent_result: result,
                  components: components,
                  next_component: next_component,
                  dataset: dataset
                })

              {:ok, prepared ++ [context], state}

            {:error, kind, reason} ->
              notify(opts, :on_error, %{
                iteration: task.iteration,
                exception: if(kind == :error, do: reason, else: {kind, reason}),
                will_continue: true
              })

              event = %{
                iteration: task.iteration,
                status: :rejected,
                operation: :mutation,
                stage: :reflective_dataset,
                source_candidate_id: task.parent.id,
                candidate: task.parent.candidate,
                parent_ids: [task.parent.id],
                components: components,
                minibatch_ids: task.minibatch_ids,
                minibatch_parent_score: result.aggregate_score,
                minibatch_candidate_score: nil,
                metric_calls_charged: 0,
                reflection_calls_charged: 0,
                reason: strategy_stage_failure(:reflective_dataset, kind, reason)
              }

              {:ok, prepared, append_strategy_stage_rejection(state, event, opts)}
          end
      end
    end)
  end

  defp make_strategy_reflective_dataset(adapter, candidate, result, components, opts) do
    {:ok, Adapter.make_reflective_dataset(adapter, candidate, result, components)}
  rescue
    exception ->
      if Keyword.get(opts, :raise_on_exception, true) do
        reraise exception, __STACKTRACE__
      else
        {:error, :error, exception}
      end
  catch
    kind, reason ->
      if Keyword.get(opts, :raise_on_exception, true) do
        :erlang.raise(kind, reason, __STACKTRACE__)
      else
        {:error, kind, reason}
      end
  end

  defp execute_strategy_reflections([], _proposer, state, _opts), do: {:ok, [], state}

  defp execute_strategy_reflections(prepared, proposer, state, opts) do
    case state.reflection_strategy do
      nil -> execute_proposer_reflections(prepared, proposer, state, opts)
      strategy -> execute_reflection_strategy(prepared, strategy, state, opts)
    end
  end

  defp execute_proposer_reflections(prepared, proposer, state, opts) do
    reservation =
      Enum.sum(
        Enum.map(prepared, fn context ->
          reflection_call_reservation(context.components, context.dataset, state.combee_policy)
        end)
      )

    case Budget.authorize_reflections(state.budget, reservation) do
      {:error, reason} ->
        {:stop, reason, state}

      :ok ->
        outputs =
          Coordinator.run(
            prepared,
            state.proposal_policy.timeout,
            max(state.proposal_policy.resolved, 1),
            fn context ->
              Reflection.execute(proposer, context.parent, context, state.combee_policy)
            end
          )

        raise_on_parallel_worker_error!(prepared, outputs, opts)

        {reflected, calls, state} =
          prepared
          |> Enum.zip(outputs)
          |> Enum.reduce({[], 0, state}, fn {context, output}, {reflected, calls, state} ->
            case output do
              {:ok, %{status: :ok, replacements: replacements} = result}
              when map_size(replacements) > 0 ->
                notify(opts, :on_proposal_end, %{
                  iteration: context.iteration,
                  new_instructions: replacements,
                  prompts: %{},
                  raw_lm_outputs: %{},
                  aggregation_reports: result.aggregation_reports
                })

                state = record_combee_reports(state, result.aggregation_reports, opts)

                {reflected ++ [Map.merge(context, result)], calls + result.reflection_calls,
                 state}

              {:ok, %{status: :ok} = result} ->
                state = record_combee_reports(state, result.aggregation_reports, opts)
                {reflected, calls + result.reflection_calls, state}

              {:ok, %{status: :error} = result} ->
                state = record_combee_reports(state, result.aggregation_reports, opts)
                state = reject_strategy_error(state, context, result.error, opts)
                {reflected, calls + result.reflection_calls, state}

              {:error, reason} ->
                state = reject_strategy_error(state, context, reason, opts)
                {reflected, calls + 1, state}
            end
          end)

        if calls > reservation do
          raise ArgumentError,
                "GEPA reflection report #{calls} exceeds preauthorization #{reservation}"
        end

        {:ok, reflected, %{state | budget: Budget.record_reflections(state.budget, calls)}}
    end
  end

  defp execute_reflection_strategy(prepared, strategy, state, opts) do
    case Budget.authorize_reflections(state.budget, length(prepared)) do
      {:error, reason} ->
        {:stop, reason, state}

      :ok ->
        jobs =
          Enum.map(prepared, fn context ->
            {context.parent.candidate, context.dataset, context.components}
          end)

        {results, successor} = reflect_strategy_jobs(strategy, jobs)

        if Keyword.get(opts, :raise_on_exception, true) do
          case Enum.find(results, &match?({:error, _}, &1)) do
            {:error, reason} -> raise_parallel_worker_error(reason)
            nil -> :ok
          end
        end

        {reflected, calls, state} =
          prepared
          |> Enum.zip(results)
          |> Enum.reduce({[], 0, state}, fn {context, result}, {reflected, calls, state} ->
            case result do
              {:ok, raw_proposal} ->
                case normalize_reflection_proposal(raw_proposal, context.parent.candidate) do
                  {:ok, proposal} ->
                    if map_size(proposal.new_texts) == 0 do
                      {reflected, calls + 1, state}
                    else
                      metadata = sanitize_reflection_metadata(proposal.metadata)

                      notify(opts, :on_proposal_end, %{
                        iteration: context.iteration,
                        new_instructions: proposal.new_texts,
                        prompts: proposal.prompts,
                        raw_lm_outputs: proposal.raw_lm_outputs,
                        aggregation_reports: [],
                        metadata: metadata
                      })

                      reflected_context =
                        Map.merge(context, %{
                          replacements: proposal.new_texts,
                          candidate: Map.merge(context.parent.candidate, proposal.new_texts),
                          reflection_calls: 1,
                          aggregation_reports: [],
                          reflection_metadata: metadata,
                          prompts: proposal.prompts,
                          raw_lm_outputs: proposal.raw_lm_outputs
                        })

                      {reflected ++ [reflected_context], calls + 1, state}
                    end

                  {:error, reason} ->
                    {reflected, calls + 1, reject_strategy_error(state, context, reason, opts)}
                end

              {:error, reason} ->
                {reflected, calls + 1, reject_strategy_error(state, context, reason, opts)}
            end
          end)

        if calls > length(prepared) do
          raise ArgumentError,
                "GEPA reflection strategy reported #{calls} calls after preauthorizing #{length(prepared)}"
        end

        state = %{
          state
          | reflection_strategy: successor,
            budget: Budget.record_reflections(state.budget, calls)
        }

        {:ok, reflected, state}
    end
  end

  defp reflect_strategy_jobs(strategy, jobs) do
    batch_result =
      try do
        ReflectionStrategy.reflect_many(strategy, jobs)
      rescue
        error ->
          {:batch_exception, {:reflection_batch_exception, error, __STACKTRACE__}}
      catch
        kind, reason ->
          {:batch_exception, {:reflection_batch_throw, kind, reason, __STACKTRACE__}}
      end

    case batch_result do
      :unsupported ->
        reflect_strategy_jobs_one_by_one(strategy, jobs)

      {:batch_exception, _reason} ->
        reflect_strategy_jobs_one_by_one(strategy, jobs)

      {:ok, results, successor} when is_list(results) ->
        if valid_strategy_batch?(results, jobs, strategy, successor) do
          normalize_strategy_results(results, strategy, successor)
        else
          retry_strategy_jobs(strategy, successor, jobs)
        end

      {:ok, results, successor} ->
        _ = results
        retry_strategy_jobs(strategy, successor, jobs)

      {:error, _reason} ->
        reflect_strategy_jobs_one_by_one(strategy, jobs)
    end
  end

  defp valid_strategy_batch?(results, jobs, fallback, successor) do
    length(results) == length(jobs) and
      match?({:ok, _successor}, safe_reflection_batch_successor(fallback, successor)) and
      Enum.zip(results, jobs)
      |> Enum.all?(fn {result, {candidate, _dataset, _components}} ->
        valid_strategy_batch_entry?(result, candidate, fallback)
      end)
  end

  defp valid_strategy_batch_entry?(result, candidate, fallback) do
    case normalize_strategy_result(result, fallback) do
      {:ok, proposal, _successor} ->
        _proposal = normalize_reflection_proposal!(proposal, candidate)
        true

      {:error, _reason} ->
        false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp retry_strategy_jobs(strategy, successor, jobs) do
    retry_strategy =
      case safe_reflection_batch_successor(strategy, successor) do
        {:ok, retry_strategy} -> retry_strategy
        :error -> strategy
      end

    reflect_strategy_jobs_one_by_one(retry_strategy, jobs)
  end

  defp safe_reflection_batch_successor(strategy, successor) do
    {:ok, reflection_batch_successor(strategy, successor)}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp reflection_batch_successor(strategy, nil), do: strategy

  defp reflection_batch_successor(_strategy, successor),
    do: ReflectionStrategy.validate!(successor)

  defp reflect_strategy_jobs_one_by_one(strategy, jobs) do
    {results, successor} =
      Enum.map_reduce(jobs, strategy, fn {candidate, dataset, components}, current ->
        case call_reflection_strategy(current, candidate, dataset, components) do
          {:ok, proposal, next} -> {{:ok, proposal}, next}
          {:error, reason} -> {{:error, reason}, current}
        end
      end)

    {results, successor}
  end

  defp call_reflection_strategy(strategy, candidate, dataset, components) do
    strategy
    |> ReflectionStrategy.reflect(candidate, dataset, components)
    |> normalize_strategy_result(strategy)
  rescue
    error -> {:error, {:reflection_strategy_exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:reflection_strategy_throw, kind, reason, __STACKTRACE__}}
  end

  defp normalize_strategy_results(results, fallback, successor_override) do
    normalized =
      Enum.map(results, fn result ->
        try do
          normalize_strategy_result(result, fallback)
        rescue
          error -> {:error, {:invalid_reflection_successor, Exception.message(error)}}
        end
      end)

    successor =
      if successor_override do
        ReflectionStrategy.validate!(successor_override)
      else
        normalized
        |> Enum.reverse()
        |> Enum.find_value(fallback, fn
          {:ok, _proposal, next} -> next
          _error -> nil
        end)
      end

    {Enum.map(normalized, fn
       {:ok, proposal, _next} -> {:ok, proposal}
       {:error, reason} -> {:error, reason}
     end), successor}
  end

  defp normalize_strategy_result({:ok, proposal, next}, _fallback),
    do: {:ok, proposal, ReflectionStrategy.validate!(next)}

  defp normalize_strategy_result({:error, reason}, _fallback), do: {:error, reason}

  defp normalize_strategy_result({proposal, next}, _fallback),
    do: {:ok, proposal, ReflectionStrategy.validate!(next)}

  defp normalize_strategy_result(other, fallback), do: {:ok, other, fallback}

  defp normalize_reflection_proposal!(proposal, candidate) when is_map(proposal) do
    new_texts = Map.get(proposal, :new_texts, Map.get(proposal, "new_texts", %{}))
    prompts = Map.get(proposal, :prompts, Map.get(proposal, "prompts", %{}))
    raw = Map.get(proposal, :raw_lm_outputs, Map.get(proposal, "raw_lm_outputs", %{}))
    metadata = Map.get(proposal, :metadata, Map.get(proposal, "metadata", %{}))

    unless is_map(new_texts) and is_map(prompts) and is_map(raw) and is_map(metadata) do
      raise ArgumentError, "GEPA reflection proposal fields must be maps"
    end

    Enum.each(new_texts, fn {component, text} ->
      unless Map.has_key?(candidate, component) and is_binary(text) do
        raise ArgumentError,
              "GEPA reflection proposal must contain binary text for existing named components"
      end
    end)

    %{new_texts: new_texts, prompts: prompts, raw_lm_outputs: raw, metadata: metadata}
  end

  defp normalize_reflection_proposal!(proposal, _candidate) do
    raise ArgumentError,
          "GEPA reflection strategy must return a proposal map, got: #{inspect(proposal)}"
  end

  defp normalize_reflection_proposal(proposal, candidate) do
    {:ok, normalize_reflection_proposal!(proposal, candidate)}
  rescue
    error -> {:error, {:invalid_reflection_proposal, Exception.message(error)}}
  end

  defp sanitize_reflection_metadata(metadata) do
    Map.new(metadata, fn {key, value} ->
      key = to_string(key)

      if String.starts_with?(key, ["prompt:", "raw_lm_output:"]),
        do: {"reflection_meta:" <> key, value},
        else: {key, value}
    end)
  end

  defp reject_strategy_error(state, context, reason, opts) do
    reason = serializable_failure(reason)

    notify(opts, :on_error, %{
      iteration: context.iteration,
      exception: reason,
      will_continue: true
    })

    original_iteration = state.iteration

    state =
      reject(
        state,
        context.iteration,
        context.parent,
        context.components,
        {:proposal_error, reason},
        context.parent_result,
        nil,
        nil
      )

    %{state | iteration: original_iteration}
  end

  defp evaluate_strategy_children(_adapter, _trainset, [], state, _opts),
    do: {:ok, [], state}

  defp evaluate_strategy_children(adapter, _trainset, reflected, state, opts) do
    reservation =
      Enum.sum(
        Enum.map(reflected, fn context ->
          Adapter.metric_call_reservation(
            adapter,
            context.minibatch,
            context.candidate,
            capture_traces: true
          )
        end)
      )

    with :ok <- Budget.authorize_evaluation(state.budget, reservation, :minibatch) do
      Enum.each(reflected, fn context ->
        notify_evaluation_start(opts, context.minibatch, true, %{
          iteration: context.iteration,
          candidate_idx: nil,
          parent_ids: [context.parent.id],
          is_seed_candidate: false
        })
      end)

      case guarded_batch_evaluate(
             adapter,
             Enum.map(reflected, &{&1.candidate, &1.minibatch}),
             [
               capture_traces: true,
               deadline: Coordinator.deadline(Keyword.get(opts, :proposal_timeout, :infinity))
             ],
             fn _kind, _reason ->
               consume_ambiguous_evaluation(
                 state,
                 reservation,
                 :minibatch,
                 hd(reflected).iteration,
                 opts
               )
             end
           ) do
        {:ok, results} ->
          actual =
            Enum.sum(Enum.zip_with(results, reflected, &metric_calls(&1, length(&2.minibatch))))

          case record_with_reservation(state.budget, actual, reservation, :minibatch) do
            {:ok, budget} ->
              {proposals, cache} =
                reflected
                |> Enum.zip(results)
                |> Enum.map_reduce(state.cache, fn {context, result}, cache ->
                  notify_evaluation_end(opts, result, %{
                    iteration: context.iteration,
                    candidate_idx: nil,
                    parent_ids: [context.parent.id],
                    is_seed_candidate: false
                  })

                  proposal = %{
                    slot: context.slot,
                    candidate: context.candidate,
                    parent: context.parent,
                    parent_ids: [context.parent.id],
                    components: context.components,
                    next_component: context.next_component,
                    before: context.parent_result,
                    after: result,
                    before_score: Enum.sum(context.parent_result.scores),
                    after_score: Enum.sum(result.scores),
                    margin: Enum.sum(result.scores) - Enum.sum(context.parent_result.scores),
                    minibatch_ids: context.minibatch_ids
                  }

                  {proposal,
                   maybe_cache_result(cache, context.candidate, context.minibatch, result, true)}
                end)

              notify_budget_updated(opts, state, budget, actual, hd(reflected).iteration)
              {:ok, proposals, %{state | budget: budget, cache: cache}}

            {:error, reason, budget} ->
              {:stop, reason, %{state | budget: budget}}
          end

        {:ambiguous_evaluation, _kind, _reason, _stacktrace, _state} = ambiguous ->
          ambiguous
      end
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp select_and_add_strategy_proposals(_adapter, _valset, [], state, _opts),
    do: {:ok, state}

  defp select_and_add_strategy_proposals(adapter, valset, proposals, state, opts) do
    policy = Keyword.get(opts, :acceptance_policy, Acceptance.default(:mutation))

    verdicts =
      Map.new(proposals, fn proposal ->
        verdict =
          decide_acceptance(policy, proposal.before, proposal.after, %{
            operation: :mutation,
            iteration: state.iteration + 1,
            parent_id: proposal.parent.id,
            components: proposal.components,
            candidate: proposal.candidate,
            proposal: proposal,
            state: state
          })

        {proposal.slot, verdict}
      end)

    strategy = Keyword.get(opts, :selection_strategy, :all_improvements)
    selected = ProposalSelection.select(strategy, proposals, state, verdicts)
    {selected, duplicates} = dedupe_strategy_candidates(selected)
    selected_slots = MapSet.new(selected, & &1.slot)
    duplicate_slots = MapSet.new(duplicates, fn {proposal, _reason} -> proposal.slot end)

    state =
      Enum.reduce(duplicates, state, fn {proposal, reason}, state ->
        reject_strategy_proposal(state, proposal, reason, opts)
      end)

    state =
      Enum.reduce(proposals, state, fn proposal, state ->
        cond do
          MapSet.member?(selected_slots, proposal.slot) ->
            state

          MapSet.member?(duplicate_slots, proposal.slot) ->
            state

          match?({:accept, _}, Map.fetch!(verdicts, proposal.slot)) ->
            reject_strategy_proposal(
              state,
              proposal,
              {:not_selected, strategy},
              opts
            )

          true ->
            {:reject, reason} = Map.fetch!(verdicts, proposal.slot)
            reject_strategy_proposal(state, proposal, reason, opts)
        end
      end)

    if selected == [] do
      {:ok, state}
    else
      with {:ok, evaluated, state} <-
             batch_strategy_validations(adapter, valset, selected, verdicts, state, opts) do
        {evaluated, incomplete} =
          Enum.split_with(evaluated, &complete_evaluation?(&1.validation))

        state =
          Enum.reduce(incomplete, state, fn item, state ->
            reject_strategy_proposal(
              state,
              item.proposal,
              {:validation_error, incomplete_evaluation_reason(item.validation)},
              opts
            )
          end)

        state =
          Enum.reduce(evaluated, state, fn evaluated, state ->
            add_strategy_candidate(state, evaluated, valset, opts)
          end)

        {:ok, state}
      end
    end
  end

  defp dedupe_strategy_candidates(selected) do
    {kept, _slots, _candidates, duplicates} =
      Enum.reduce(selected, {[], MapSet.new(), MapSet.new(), []}, fn proposal,
                                                                     {kept, slots, candidates,
                                                                      duplicates} ->
        key = :erlang.term_to_binary(proposal.candidate, [:deterministic])

        cond do
          MapSet.member?(slots, proposal.slot) ->
            {kept, slots, candidates,
             duplicates ++ [{proposal, {:duplicate_proposal_selection, proposal.slot}}]}

          MapSet.member?(candidates, key) ->
            {kept, MapSet.put(slots, proposal.slot), candidates,
             duplicates ++ [{proposal, {:duplicate_candidate, :selected_this_iteration}}]}

          true ->
            {kept ++ [proposal], MapSet.put(slots, proposal.slot), MapSet.put(candidates, key),
             duplicates}
        end
      end)

    {kept, duplicates}
  end

  defp reject_strategy_proposal(state, proposal, reason, opts) do
    notify(opts, :on_candidate_rejected, %{
      iteration: state.iteration + 1,
      old_score: proposal.before_score,
      new_score: proposal.after_score,
      reason: reason,
      components: proposal.components
    })

    original_iteration = state.iteration

    state =
      reject(
        state,
        state.iteration + 1,
        proposal.parent,
        proposal.components,
        reason,
        proposal.before,
        proposal.after,
        proposal.candidate
      )

    %{state | iteration: original_iteration}
  end

  defp batch_strategy_validations(adapter, valset, selected, verdicts, state, opts) do
    backend = evaluation_cache_backend(state.cache)
    cache? = Keyword.get(opts, :cache_evaluation, true)
    base_candidate_id = length(state.candidates)

    plans =
      selected
      |> Enum.with_index()
      |> Enum.map(fn {proposal, index} ->
        candidate_id = base_candidate_id + index

        ids =
          EvaluationPolicy.validation_ids(
            state.evaluation_policy,
            valset,
            state,
            candidate_id
          )

        batch = Enum.map(ids, &Enum.fetch!(valset, &1))

        {hits, missing_indexes} =
          if cache?,
            do: backend.lookup(state.cache, proposal.candidate, batch),
            else: {%{}, indexes(length(batch))}

        missing_batch = Enum.map(missing_indexes, &Enum.fetch!(batch, &1))

        reservation =
          Adapter.metric_call_reservation(
            adapter,
            missing_batch,
            proposal.candidate,
            capture_traces: true
          )

        %{
          proposal: proposal,
          candidate_id: candidate_id,
          ids: ids,
          batch: batch,
          hits: hits,
          missing_indexes: missing_indexes,
          missing_batch: missing_batch,
          reservation: reservation,
          acceptance: elem(Map.fetch!(verdicts, proposal.slot), 1)
        }
      end)

    case preauthorize_strategy_validations(state.budget, plans) do
      {:error, reason} ->
        {:stop, reason, state}

      :ok ->
        fresh_plans = Enum.filter(plans, &(&1.missing_indexes != []))

        Enum.each(fresh_plans, fn plan ->
          notify_evaluation_start(opts, plan.missing_batch, true, %{
            iteration: state.iteration + 1,
            candidate_idx: plan.candidate_id,
            parent_ids: plan.proposal.parent_ids,
            is_seed_candidate: false
          })
        end)

        fresh_results =
          if fresh_plans == [] do
            {:ok, []}
          else
            guarded_batch_evaluate(
              adapter,
              Enum.map(fresh_plans, &{&1.proposal.candidate, &1.missing_batch}),
              [
                capture_traces: true,
                deadline: Coordinator.deadline(Keyword.get(opts, :evaluation_timeout, :infinity))
              ],
              fn kind, reason ->
                consume_ambiguous_validations(state, plans, kind, reason, opts)
              end
            )
          end

        with {:ok, fresh_results} <- fresh_results do
          fresh_by_slot =
            fresh_plans
            |> Enum.zip(fresh_results)
            |> Map.new(fn {plan, result} -> {plan.proposal.slot, result} end)

          {evaluated, state, _discovery} =
            Enum.reduce(plans, {[], state, state.budget.metric_calls}, fn plan,
                                                                          {evaluated, state,
                                                                           discovery} ->
              fresh = Map.get(fresh_by_slot, plan.proposal.slot)

              validation =
                if cache? do
                  backend.assemble(plan.batch, plan.hits, plan.missing_indexes, fresh)
                else
                  fresh
                end

              validation =
                %{validation | metadata: Map.put(validation.metadata, :validation_ids, plan.ids)}

              actual = metric_calls(fresh, length(plan.missing_batch))

              {:ok, budget} =
                record_with_reservation(state.budget, actual, plan.reservation, :full)

              cache =
                if (cache? and fresh) && complete_evaluation?(fresh) do
                  backend.put(state.cache, plan.proposal.candidate, plan.missing_batch, fresh)
                else
                  state.cache
                end

              if fresh do
                notify_evaluation_end(opts, validation, %{
                  iteration: state.iteration + 1,
                  candidate_idx: plan.candidate_id,
                  parent_ids: plan.proposal.parent_ids,
                  is_seed_candidate: false
                })
              else
                notify(opts, :on_evaluation_skipped, %{
                  iteration: state.iteration + 1,
                  candidate_idx: plan.candidate_id,
                  reason: :cache_hit,
                  scores: validation.scores,
                  is_seed_candidate: false
                })
              end

              notify_budget_updated(opts, state, budget, actual, state.iteration + 1)
              state = %{state | budget: budget, cache: cache}

              item = %{
                proposal: plan.proposal,
                validation: validation,
                discovered_at: discovery,
                acceptance: plan.acceptance
              }

              {evaluated ++ [item], state, discovery + actual}
            end)

          {:ok, evaluated, state}
        end
    end
  end

  defp preauthorize_strategy_validations(budget, plans) do
    Enum.reduce_while(plans, {:ok, budget}, fn plan, {:ok, shadow} ->
      case Budget.record_evaluation(shadow, plan.reservation, :full) do
        {:ok, shadow} -> {:cont, {:ok, shadow}}
        {:error, reason, _shadow} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _shadow} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp guarded_batch_evaluate(adapter, items, evaluation_opts, on_ambiguous) do
    {:ok, Evaluation.batch_evaluate(adapter, items, evaluation_opts)}
  rescue
    exception ->
      stacktrace = __STACKTRACE__
      {:ambiguous_evaluation, :error, exception, stacktrace, on_ambiguous.(:error, exception)}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      {:ambiguous_evaluation, kind, reason, stacktrace, on_ambiguous.(kind, reason)}
  end

  defp consume_ambiguous_evaluation(state, reservation, kind, iteration, opts) do
    {:ok, budget} = Budget.record_evaluation(state.budget, reservation, kind)
    notify_budget_updated(opts, state, budget, reservation, iteration)
    %{state | budget: budget}
  end

  defp consume_ambiguous_validations(state, plans, kind, reason, opts) do
    budget =
      Enum.reduce(plans, state.budget, fn plan, budget ->
        {:ok, budget} = Budget.record_evaluation(budget, plan.reservation, :full)
        budget
      end)

    calls = Enum.sum(Enum.map(plans, & &1.reservation))
    notify_budget_updated(opts, state, budget, calls, state.iteration + 1)

    state = %{state | budget: budget}

    if Keyword.get(opts, :raise_on_exception, true) do
      state
    else
      failure = strategy_stage_failure(:validation, kind, reason)

      Enum.reduce(plans, state, fn plan, state ->
        proposal = plan.proposal

        event = %{
          iteration: state.iteration + 1,
          status: :rejected,
          operation: :mutation,
          stage: :validation,
          target_candidate_id: plan.candidate_id,
          candidate: proposal.candidate,
          parent_ids: proposal.parent_ids,
          components: proposal.components,
          validation_instances: plan.ids,
          minibatch_parent_score: proposal.before_score,
          minibatch_candidate_score: proposal.after_score,
          metric_calls_charged: plan.reservation,
          reflection_calls_charged: 0,
          reason: failure
        }

        append_strategy_stage_rejection(state, event, opts)
      end)
    end
  end

  defp append_strategy_stage_rejection(state, event, opts) do
    notify(opts, :on_candidate_rejected, %{
      iteration: event.iteration,
      candidate_idx: Map.get(event, :target_candidate_id),
      source_candidate_id: Map.get(event, :source_candidate_id),
      old_score: event.minibatch_parent_score,
      new_score: event.minibatch_candidate_score,
      stage: event.stage,
      reason: event.reason,
      components: event.components
    })

    %{
      state
      | rejected: state.rejected ++ [event],
        history: state.history ++ [event]
    }
  end

  defp strategy_stage_failure(
         stage,
         :error,
         %{
           __exception__: true,
           __struct__: exception_type
         } = exception
       ) do
    {:strategy_stage_error, stage, {:exception, exception_type, Exception.message(exception)}}
  end

  defp strategy_stage_failure(stage, kind, reason) do
    {:strategy_stage_error, stage, {kind, inspect(reason)}}
  end

  defp add_strategy_candidate(state, evaluated, valset, opts) do
    proposal = evaluated.proposal

    entry = %Entry{
      id: length(state.candidates),
      candidate: proposal.candidate,
      validation: evaluated.validation,
      parent_ids: proposal.parent_ids,
      next_component: proposal.next_component,
      discovered_at: evaluated.discovered_at
    }

    event = %{
      iteration: state.iteration + 1,
      status: :accepted,
      candidate_id: entry.id,
      parent_ids: proposal.parent_ids,
      components: proposal.components,
      minibatch_parent_score: proposal.before_score,
      minibatch_candidate_score: proposal.after_score,
      acceptance: evaluated.acceptance,
      validation_score: evaluated.validation.aggregate_score
    }

    state = track_validation_outputs(state, entry)

    state = %{
      state
      | candidates: state.candidates ++ [entry],
        history: state.history ++ [event],
        last_iteration_found_candidate: true,
        merge_due: schedule_merge(state, opts)
    }

    notify_candidate_added(opts, state, entry, valset, state.iteration + 1)

    notify(opts, :on_candidate_accepted, %{
      iteration: state.iteration + 1,
      new_candidate_idx: entry.id,
      new_score: proposal.after_score,
      parent_ids: proposal.parent_ids,
      components: proposal.components
    })

    state
  end

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

      Keyword.get(opts, :drain_pending_only, false) and is_nil(state.pending_proposal_batch) ->
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

  defp parallel_batch_width(state, max_iterations, opts) do
    available = min(state.proposal_policy.resolved, max_iterations - state.iteration)

    if not is_nil(Keyword.get(opts, :stopper)) or
         not is_nil(Keyword.get(opts, :max_reflection_cost)),
       do: min(available, 1),
       else: available
  end

  defp prepare_parent_batch(state, adapter, trainset, minibatch_size, max_iterations, opts) do
    count = parallel_batch_width(state, max_iterations, opts)

    {contexts, state, deferred_stop_reason} =
      Enum.reduce_while(0..(count - 1), {[], state, nil}, fn slot, {contexts, state, _reason} ->
        iteration = state.iteration + slot + 1

        {parent, rng_state} =
          opts
          |> Keyword.get(:candidate_selection_strategy, :pareto)
          |> CandidateSelector.select(state)

        {[{batch, minibatch_ids}], batch_sampler, rng_state} =
          BatchSampler.next_batches(
            state.batch_sampler,
            trainset,
            minibatch_size,
            1,
            iteration - 1,
            rng_state
          )

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
             {contexts ++ [context],
              %{
                state
                | rng_state: rng_state,
                  batch_sampler: batch_sampler,
                  budget_ledger: ledger
              }, nil}}

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

    items =
      Enum.map(contexts, fn context ->
        parent = Enum.fetch!(state.candidates, context.parent_id)
        examples = Enum.map(context.minibatch_ids, &Enum.fetch!(trainset, &1))
        {parent.candidate, examples}
      end)

    outputs = batch_evaluate_speculatively(adapter, items, contexts, state, opts)

    raise_on_parallel_worker_error!(contexts, outputs, opts)

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
            context = %{
              context
              | action: :error,
                error: serializable_failure(reason),
                parent_ambiguous: true
            }

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

    output_list =
      Coordinator.run(runnable, state.proposal_policy.timeout, fn context ->
        parent = Enum.fetch!(state.candidates, context.parent_id)
        Reflection.execute(proposer, parent, context, state.combee_policy)
      end)

    raise_on_parallel_worker_error!(runnable, output_list, opts)

    outputs =
      Map.new(Enum.zip(Enum.map(runnable, fn context -> context.slot end), output_list))

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
                  error: serializable_failure(output.error)
              }

              {contexts ++ [context], state, stop_reason}

            {:error, reason} ->
              context = %{
                context
                | action: :error,
                  error: serializable_failure(reason),
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

    output_list =
      if runnable == [] do
        []
      else
        items =
          Enum.map(runnable, fn context ->
            examples = Enum.map(context.minibatch_ids, &Enum.fetch!(trainset, &1))
            {context.candidate, examples}
          end)

        batch_evaluate_speculatively(adapter, items, runnable, state, opts)
      end

    raise_on_parallel_worker_error!(runnable, output_list, opts)

    outputs =
      Map.new(Enum.zip(Enum.map(runnable, fn context -> context.slot end), output_list))

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
              %{
                context
                | action: :error,
                  error: serializable_failure(reason),
                  child_ambiguous: true
              }
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

  defp raise_on_parallel_worker_error!(contexts, outputs, opts) do
    if Keyword.get(opts, :raise_on_exception, true) do
      failures =
        contexts
        |> Enum.zip(outputs)
        |> Enum.flat_map(fn {context, output} ->
          case parallel_worker_failure(output) do
            {:error, reason} -> [{context, reason}]
            :ok -> []
          end
        end)

      failure =
        Enum.find(failures, fn {_context, reason} -> reason != :cancelled end) ||
          List.first(failures)

      case failure do
        nil ->
          :ok

        {context, reason} ->
          notify(opts, :on_error, %{
            iteration: context.iteration,
            exception: reason,
            will_continue: false
          })

          raise_parallel_worker_error(reason)
      end
    else
      :ok
    end
  end

  defp parallel_worker_failure({:error, reason}), do: {:error, reason}

  defp parallel_worker_failure({:ok, %{status: :error, error: reason}}),
    do: {:error, reason}

  defp parallel_worker_failure(_output), do: :ok

  defp batch_evaluate_speculatively(adapter, items, contexts, state, _opts) do
    if adapter_batch_callback?(adapter) do
      result =
        Coordinator.run([items], state.proposal_policy.timeout, 1, fn batch ->
          capture_parallel_evaluation(fn ->
            Evaluation.batch_evaluate(
              adapter,
              batch,
              capture_traces: true,
              deadline: Coordinator.current_deadline()
            )
          end)
        end)

      case result do
        [{:ok, {:evaluation_ok, results}}] -> Enum.map(results, &{:ok, &1})
        [{:ok, {:evaluation_error, reason}}] -> List.duplicate({:error, reason}, length(contexts))
        [{:error, reason}] -> List.duplicate({:error, reason}, length(contexts))
      end
    else
      Coordinator.run(
        items,
        state.proposal_policy.timeout,
        state.proposal_policy.resolved,
        fn item ->
          capture_parallel_evaluation(fn ->
            adapter
            |> Evaluation.batch_evaluate([item],
              capture_traces: true,
              deadline: Coordinator.current_deadline()
            )
            |> hd()
          end)
        end
      )
      |> Enum.map(&unwrap_parallel_evaluation/1)
    end
  end

  defp adapter_batch_callback?(%module{}), do: function_exported?(module, :batch_evaluate, 3)

  defp capture_parallel_evaluation(fun) do
    {:evaluation_ok, fun.()}
  rescue
    exception -> {:evaluation_error, {:evaluation_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:evaluation_error, {:evaluation_throw, kind, reason, __STACKTRACE__}}
  end

  defp unwrap_parallel_evaluation({:ok, {:evaluation_ok, result}}), do: {:ok, result}
  defp unwrap_parallel_evaluation({:ok, {:evaluation_error, reason}}), do: {:error, reason}
  defp unwrap_parallel_evaluation({:error, reason}), do: {:error, reason}

  defp raise_parallel_worker_error({:exception, exception, stacktrace}),
    do: :erlang.raise(:error, exception, stacktrace)

  defp raise_parallel_worker_error({:exception, message}) when is_binary(message),
    do: raise(RuntimeError, message)

  defp raise_parallel_worker_error({:proposal_exception, exception, stacktrace}),
    do: :erlang.raise(:error, exception, stacktrace)

  defp raise_parallel_worker_error({:proposal_exception, message}) when is_binary(message),
    do: raise(RuntimeError, message)

  defp raise_parallel_worker_error({:reflection_strategy_exception, exception, stacktrace}),
    do: :erlang.raise(:error, exception, stacktrace)

  defp raise_parallel_worker_error({:reflection_strategy_exception, message})
       when is_binary(message),
       do: raise(RuntimeError, message)

  defp raise_parallel_worker_error({:reflection_batch_exception, exception, stacktrace}),
    do: :erlang.raise(:error, exception, stacktrace)

  defp raise_parallel_worker_error({:reflection_batch_exception, message})
       when is_binary(message),
       do: raise(RuntimeError, message)

  defp raise_parallel_worker_error({:evaluation_exception, exception, stacktrace}),
    do: :erlang.raise(:error, exception, stacktrace)

  defp raise_parallel_worker_error({:combee_first_level_failed, _index, reason}),
    do: raise_parallel_worker_error(reason)

  defp raise_parallel_worker_error({:combee_final_aggregation_failed, reason}),
    do: raise_parallel_worker_error(reason)

  defp raise_parallel_worker_error({:proposal_throw, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp raise_parallel_worker_error({:proposal_throw, kind, reason}),
    do: :erlang.raise(kind, reason, [])

  defp raise_parallel_worker_error({:reflection_strategy_throw, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp raise_parallel_worker_error({:reflection_strategy_throw, kind, reason}),
    do: :erlang.raise(kind, reason, [])

  defp raise_parallel_worker_error({:reflection_batch_throw, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp raise_parallel_worker_error({:reflection_batch_throw, kind, reason}),
    do: :erlang.raise(kind, reason, [])

  defp raise_parallel_worker_error({:evaluation_throw, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp raise_parallel_worker_error({kind, reason}) when kind in [:error, :exit, :throw],
    do: :erlang.raise(kind, reason, [])

  defp raise_parallel_worker_error(reason) do
    raise RuntimeError, "GEPA speculative proposal worker failed: #{inspect(reason)}"
  end

  defp serializable_failure({:combee_first_level_failed, index, reason}),
    do: {:combee_first_level_failed, index, serializable_failure(reason)}

  defp serializable_failure({:combee_final_aggregation_failed, reason}),
    do: {:combee_final_aggregation_failed, serializable_failure(reason)}

  defp serializable_failure({:proposal_exception, exception, _stacktrace}),
    do: {:proposal_exception, Exception.message(exception)}

  defp serializable_failure({:reflection_strategy_exception, exception, _stacktrace}),
    do: {:reflection_strategy_exception, Exception.message(exception)}

  defp serializable_failure({:reflection_batch_exception, exception, _stacktrace}),
    do: {:reflection_batch_exception, Exception.message(exception)}

  defp serializable_failure({:evaluation_exception, exception, _stacktrace}),
    do: {:evaluation_exception, Exception.message(exception)}

  defp serializable_failure({:proposal_throw, kind, reason, _stacktrace}),
    do: {:proposal_throw, kind, reason}

  defp serializable_failure({:reflection_strategy_throw, kind, reason, _stacktrace}),
    do: {:reflection_strategy_throw, kind, reason}

  defp serializable_failure({:reflection_batch_throw, kind, reason, _stacktrace}),
    do: {:reflection_batch_throw, kind, reason}

  defp serializable_failure({:evaluation_throw, kind, reason, _stacktrace}),
    do: {:evaluation_throw, kind, reason}

  defp serializable_failure(reason), do: reason

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

    case decide_acceptance(policy, context.parent_result, context.child_result, %{
           operation: :mutation,
           iteration: context.iteration,
           parent_id: parent.id,
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

  defp prepare_validation!(state, candidate, ids, metric_calls, event, opts) do
    pending = %{
      "status" => "prepared",
      "iteration" => event.iteration,
      "target_candidate_id" => event.candidate_idx,
      "parent_ids" => event.parent_ids,
      "candidate" => Imp.Optimizer.Report.encode_term(candidate),
      "validation_ids" => ids,
      "metric_calls" => metric_calls
    }

    state = %{state | pending_validation: pending}
    checkpoint!(state, opts)
    state
  end

  defp start_validation!(state, opts) do
    state = put_in(state.pending_validation["status"], "started")
    checkpoint!(state, opts)
    state
  end

  defp complete_validation!(%State{pending_validation: %{"status" => "started"}} = state),
    do: %{state | pending_validation: nil}

  defp complete_validation!(%State{pending_validation: nil} = state), do: state

  defp complete_validation!(_state) do
    raise ArgumentError, "GEPA full validation completion does not match its durable checkpoint"
  end

  defp recover_interrupted_validation!(%State{pending_validation: nil} = state, _opts), do: state

  defp recover_interrupted_validation!(%State{pending_validation: pending} = state, opts) do
    {budget, reason} = recover_validation_budget!(state.budget, pending)

    event = %{
      iteration: pending["iteration"],
      status: :rejected,
      operation: :validation,
      candidate_id: pending["target_candidate_id"],
      parent_ids: pending["parent_ids"],
      candidate: Imp.Optimizer.Report.decode_term(pending["candidate"]),
      validation_instances: pending["validation_ids"],
      reason: reason
    }

    state = %{
      state
      | budget: budget,
        iteration: max(state.iteration, pending["iteration"]),
        rejected: state.rejected ++ [event],
        history: state.history ++ [event],
        last_iteration_found_candidate: false,
        pending_validation: nil
    }

    checkpoint!(state, opts)
    state
  end

  defp recover_validation_budget!(budget, %{"status" => "prepared"}) do
    {budget, {:interrupted_validation, :discarded_before_dispatch}}
  end

  defp recover_validation_budget!(budget, %{"status" => "started"} = pending) do
    metric_calls = Map.get(pending, "metric_calls", length(pending["validation_ids"]))

    case Budget.record_evaluation(budget, metric_calls, :full) do
      {:ok, budget} ->
        {budget, {:interrupted_validation, :ambiguous_external_effects}}

      {:error, {:budget_exhausted, _resource, _requested, _limit}, _budget} ->
        {budget, {:interrupted_validation, :discarded_before_authorization}}

      {:error, reason, _budget} ->
        raise ArgumentError,
              "GEPA interrupted validation cannot be conservatively charged: #{inspect(reason)}"
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
          workers = Imp.Settings.snapshot() |> Map.fetch!(:async_max_workers)
          max(1, div(workers, minibatch_size))

        value ->
          value
      end

    %{
      requested: requested,
      resolved: resolved,
      timeout: timeout,
      strategy_configuration: strategy_configuration(opts)
    }
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
      "timeout" => if(policy.timeout == :infinity, do: "infinity", else: policy.timeout),
      "strategy_configuration" => Imp.Optimizer.Report.encode_term(policy.strategy_configuration)
    }
  end

  defp load_proposal_policy(dumped, 4, requested) do
    stored = Map.fetch!(dumped, "proposal_policy")

    loaded = %{
      requested: if(stored["requested"] == "auto", do: :auto, else: stored["requested"]),
      resolved: Map.fetch!(stored, "resolved"),
      timeout: if(stored["timeout"] == "infinity", do: :infinity, else: stored["timeout"]),
      strategy_configuration:
        case Map.fetch(stored, "strategy_configuration") do
          {:ok, configuration} -> Imp.Optimizer.Report.decode_term(configuration)
          :error -> requested.strategy_configuration
        end
    }

    loaded
  end

  defp load_proposal_policy(dumped, 5, requested),
    do: load_proposal_policy(dumped, 4, requested)

  defp load_proposal_policy(dumped, 6, requested),
    do: load_proposal_policy(dumped, 4, requested)

  defp load_proposal_policy(dumped, 7, requested),
    do: load_proposal_policy(dumped, 4, requested)

  defp strategy_configuration(opts) do
    configuration = %{
      sampling_strategy:
        opts
        |> Keyword.get(:sampling_strategy, :single)
        |> strategy_value_identity(),
      selection_strategy:
        opts
        |> Keyword.get(:selection_strategy, :all_improvements)
        |> strategy_value_identity(),
      acceptance_policy:
        opts
        |> Keyword.get(:acceptance_policy, Acceptance.default(:mutation))
        |> strategy_value_identity()
    }

    case Keyword.get(opts, :execution_profile, :beam_native) do
      :beam_native ->
        configuration

      profile ->
        Map.merge(configuration, %{
          execution_profile: profile,
          reflection_failure_policy:
            Keyword.get(opts, :reflection_failure_policy, :single_attempt_fail_closed),
          rng_algorithm: Keyword.get(opts, :rng_algorithm, :beam_native)
        })
    end
  end

  defp strategy_value_identity({:callback, callback}) when is_function(callback) do
    digest = callback |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))
    {:callback, Base.encode16(digest, case: :lower)}
  end

  defp strategy_value_identity(value), do: value

  defp load_combee_policy(dumped, 4, _requested) do
    dumped |> Map.fetch!("combee_policy") |> ComBee.load_policy!()
  end

  defp load_combee_policy(dumped, 5, requested),
    do: load_combee_policy(dumped, 4, requested)

  defp load_combee_policy(dumped, 6, requested),
    do: load_combee_policy(dumped, 4, requested)

  defp load_combee_policy(dumped, 7, requested),
    do: load_combee_policy(dumped, 4, requested)

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

  defp validate_checkpoint_integrity!(dumped, 4) do
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

  defp validate_checkpoint_integrity!(dumped, 5),
    do: validate_checkpoint_integrity!(dumped, 4)

  defp validate_checkpoint_integrity!(dumped, 6),
    do: validate_checkpoint_integrity!(dumped, 4)

  defp validate_checkpoint_integrity!(dumped, 7),
    do: validate_checkpoint_integrity!(dumped, 4)

  defp dump_pending_validation(nil), do: nil

  defp dump_pending_validation(pending) when is_map(pending), do: pending

  defp validation_integrity(pending),
    do: Proposal.checkpoint_integrity(pending, %{}, %{})

  defp load_pending_validation!(dumped) do
    case {Map.fetch(dumped, "pending_validation"),
          Map.fetch(dumped, "pending_validation_integrity")} do
      {:error, :error} ->
        nil

      {{:ok, pending}, {:ok, integrity}} ->
        unless integrity == validation_integrity(pending) do
          raise ArgumentError, "GEPA pending validation checkpoint integrity mismatch"
        end

        validate_pending_validation!(pending)

      _other ->
        raise ArgumentError, "GEPA pending validation checkpoint is incomplete"
    end
  end

  defp validate_pending_validation!(nil), do: nil

  defp validate_pending_validation!(pending) when is_map(pending) do
    legacy_keys = ~w(status iteration target_candidate_id parent_ids candidate validation_ids)
    current_keys = legacy_keys ++ ["metric_calls"]

    unless MapSet.new(Map.keys(pending)) in [MapSet.new(legacy_keys), MapSet.new(current_keys)] do
      raise ArgumentError, "GEPA pending validation has unexpected or missing keys"
    end

    unless pending["status"] in ["prepared", "started"] and
             is_integer(pending["iteration"]) and pending["iteration"] >= 0 and
             is_integer(pending["target_candidate_id"]) and
             pending["target_candidate_id"] >= 0 and is_list(pending["parent_ids"]) and
             is_list(pending["validation_ids"]) and
             (is_nil(pending["metric_calls"]) or
                (is_integer(pending["metric_calls"]) and pending["metric_calls"] >= 0)) do
      raise ArgumentError, "GEPA pending validation has invalid fields"
    end

    pending
  end

  defp validate_pending_validation!(_pending) do
    raise ArgumentError, "GEPA pending validation must be a map or nil"
  end

  defp run_iteration(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts) do
    notify(opts, :on_iteration_start, %{iteration: iteration, state: state})
    candidate_count = length(state.candidates)

    result =
      try do
        iterate(adapter, trainset, valset, proposer, minibatch_size, iteration, state, opts)
      rescue
        exception ->
          handle_iteration_exception(exception, __STACKTRACE__, iteration, state, opts)
      catch
        kind, reason ->
          handle_iteration_exception(
            {kind, reason},
            __STACKTRACE__,
            iteration,
            state,
            opts,
            kind,
            reason
          )
      end

    case result do
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

  defp handle_iteration_exception(
         exception,
         stacktrace,
         iteration,
         state,
         opts,
         kind \\ :error,
         reason \\ nil
       ) do
    continue? = not Keyword.get(opts, :raise_on_exception, true)

    notify(opts, :on_error, %{
      iteration: iteration,
      exception: exception,
      will_continue: continue?
    })

    if continue? do
      {:ok, %{state | iteration: iteration, last_iteration_found_candidate: false}}
    else
      if kind == :error,
        do: reraise(exception, stacktrace),
        else: :erlang.raise(kind, reason, stacktrace)
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

    reflection_strategy_state =
      ReflectionStrategy.dump(
        state.reflection_strategy,
        state.reflection_strategy_initial,
        state.budget.reflection_calls
      )

    checkpoint = %{
      "schema_version" => 7,
      "iteration" => state.iteration,
      "candidates" => Enum.map(state.candidates, &dump_entry/1),
      "rejected" => Imp.Optimizer.Report.encode_term(state.rejected),
      "history" => Imp.Optimizer.Report.encode_term(state.history),
      "cache" => dump_cache(state.cache),
      "budget" => Budget.dump(state.budget),
      "rng_state" => dump_rng(state.rng_state),
      "merge_due" => state.merge_due,
      "total_merges_tested" => state.total_merges_tested,
      "merge_attempts" => Imp.Optimizer.Report.encode_term(state.merge_attempts),
      "last_iteration_found_candidate" => state.last_iteration_found_candidate,
      "frontier_type" => state.frontier_type,
      "evaluation_policy" => Atom.to_string(state.evaluation_policy),
      "best_outputs_valset" => dump_best_outputs(state.best_outputs_valset),
      "stopper_state" => dump_stopper_state(state.stopper_state),
      "budget_ledger" => ledger,
      "pending_proposal_batch" => pending,
      "pending_validation" => dump_pending_validation(state.pending_validation),
      "pending_validation_integrity" => validation_integrity(state.pending_validation),
      "proposal_policy" => policy,
      "combee_policy" => combee_policy,
      "combee_reports" => Enum.map(state.combee_reports, &ComBee.dump_report/1),
      "adapter_state" => Imp.Optimizer.Report.encode_term(state.adapter_state),
      "batch_sampler" => BatchSampler.dump(state.batch_sampler),
      "reflection_strategy_state" => reflection_strategy_state,
      "stop_reason" => Imp.Optimizer.Report.encode_term(state.stop_reason)
    }

    Map.put(
      checkpoint,
      "pending_proposal_integrity",
      Proposal.checkpoint_integrity(pending, ledger, policy, combee_policy)
    )
  end

  defp initialize(adapter, seed_candidate, valset, opts) do
    reflection_strategy = Keyword.get(opts, :reflection_strategy)

    state = %State{
      cache: new_evaluation_cache(opts),
      budget:
        Budget.new(
          max_metric_calls: Keyword.get(opts, :max_metric_calls, :infinity),
          max_full_evaluations: Keyword.get(opts, :max_full_evaluations, :infinity),
          max_reflection_calls: Keyword.get(opts, :max_reflection_calls, :infinity)
        ),
      rng_state:
        Random.new(
          Keyword.get(opts, :seed, 0),
          Keyword.get(opts, :rng_algorithm, :beam_native)
        ),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      evaluation_policy:
        opts |> Keyword.get(:evaluation_policy, :full) |> EvaluationPolicy.resolve!(),
      best_outputs_valset: if(Keyword.get(opts, :track_best_outputs, false), do: %{}),
      stopper_state: new_stopper_state(opts),
      proposal_policy: Keyword.fetch!(opts, :proposal_policy),
      combee_policy: Keyword.fetch!(opts, :combee_policy),
      batch_sampler:
        BatchSampler.new(
          Keyword.get(opts, :batch_sampler, :epoch_shuffled),
          Keyword.fetch!(opts, :effective_minibatch_size)
        ),
      reflection_strategy: reflection_strategy,
      reflection_strategy_initial: reflection_strategy
    }

    case evaluate_validation(adapter, valset, seed_candidate, 0, [], 0, state, opts) do
      {:ok, validation, state} ->
        entry = %Entry{
          id: 0,
          candidate: seed_candidate,
          validation: validation,
          discovered_at: 0
        }

        state =
          state
          |> complete_validation!()
          |> track_validation_outputs(entry)
          |> Map.put(:candidates, [entry])

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

    {parent, rng_state} =
      opts
      |> Keyword.get(:candidate_selection_strategy, :pareto)
      |> CandidateSelector.select(state)

    {[{batch, minibatch_ids}], batch_sampler, rng_state} =
      BatchSampler.next_batches(
        state.batch_sampler,
        trainset,
        minibatch_size,
        1,
        iteration - 1,
        rng_state
      )

    state = %{state | batch_sampler: batch_sampler, rng_state: rng_state}

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
         :ok <- maybe_skip_incomplete(parent_result, parent, iteration, state, opts),
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
           evaluate_changed_candidate(
             adapter,
             batch,
             parent.candidate,
             proposed_candidate,
             components,
             parent_result,
             state,
             opts,
             %{
               iteration: iteration,
               candidate_idx: nil,
               parent_ids: [parent.id],
               is_seed_candidate: false
             }
           ) do
      policy = Keyword.get(opts, :acceptance_policy, Acceptance.default(:mutation))

      case decide_acceptance(policy, parent_result, proposed_result, %{
             operation: :mutation,
             iteration: iteration,
             parent_id: parent.id,
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
        reject_or_raise_proposal_error(state, parent, components, reason, iteration, opts)

      {:error, {:no_op_candidate, components, parent_result}, state} ->
        notify(opts, :on_candidate_rejected, %{
          iteration: iteration,
          old_score: parent_result.aggregate_score,
          new_score: parent_result.aggregate_score,
          reason: :no_op_candidate,
          components: components
        })

        {:ok,
         reject(
           state,
           iteration,
           parent,
           components,
           :no_op_candidate,
           parent_result,
           parent_result,
           parent.candidate
         )}

      {:error, reason, state} ->
        reject_or_raise_proposal_error(state, parent, [], reason, iteration, opts)

      {:error, reason} ->
        reject_or_raise_proposal_error(state, parent, [], reason, iteration, opts)
    end
  end

  defp evaluate_changed_candidate(
         adapter,
         batch,
         candidate,
         proposed_candidate,
         components,
         parent_result,
         state,
         opts,
         metadata
       ) do
    if candidate == proposed_candidate and Keyword.get(opts, :reject_identical_candidate, false) do
      {:error, {:no_op_candidate, components, parent_result}, state}
    else
      evaluate(adapter, batch, proposed_candidate, false, :minibatch, state, opts, metadata)
    end
  end

  defp reject_or_raise_proposal_error(state, parent, components, reason, iteration, opts) do
    raise? = Keyword.get(opts, :raise_on_exception, true)
    callback_reason = if raise?, do: reason, else: serializable_failure(reason)

    notify(opts, :on_error, %{
      iteration: iteration,
      exception: callback_reason,
      will_continue: not raise?
    })

    if raise? do
      raise_parallel_worker_error(reason)
    else
      {:ok,
       reject(
         state,
         iteration,
         parent,
         components,
         {:proposal_error, callback_reason},
         nil,
         nil,
         nil
       )}
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

        case decide_acceptance(policy, parent_result, result, %{
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

      {:error, reason, state} ->
        reject_or_raise_merge_error(state, proposal, reason, iteration, opts)
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
    discovered_at = state.budget.metric_calls

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
          discovered_at: discovered_at
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

        state = state |> complete_validation!() |> track_validation_outputs(entry)

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

      {:error, reason, state} ->
        reject_or_raise_merge_error(state, proposal, {:validation_error, reason}, iteration, opts)
    end
  end

  defp reject_or_raise_merge_error(state, proposal, reason, iteration, opts) do
    raise? = Keyword.get(opts, :raise_on_exception, true)

    notify(opts, :on_error, %{
      iteration: iteration,
      exception: reason,
      will_continue: not raise?
    })

    if raise? do
      raise_parallel_worker_error(reason)
    else
      notify(opts, :on_merge_rejected, %{
        iteration: iteration,
        parent_ids: proposal.parent_ids,
        reason: {:evaluation_error, reason}
      })

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
        reason: {:evaluation_error, reason}
      }

      {:ok,
       %{
         state
         | iteration: iteration,
           rejected: state.rejected ++ [event],
           history: state.history ++ [event]
       }}
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
    discovered_at = state.budget.metric_calls

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
          discovered_at: discovered_at
        }

        event = %{
          iteration: iteration,
          status: :accepted,
          candidate_id: entry.id,
          parent_ids: [parent.id],
          components: components,
          minibatch_parent_score: parent_result.aggregate_score,
          minibatch_candidate_score: proposed_result.aggregate_score,
          acceptance: acceptance,
          validation_score: validation.aggregate_score
        }

        state = state |> complete_validation!() |> track_validation_outputs(entry)

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

      {:error, reason, state} ->
        reject_or_raise_proposal_error(
          state,
          parent,
          components,
          {:validation_error, reason},
          iteration,
          opts
        )
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

    metric_calls =
      Adapter.metric_call_reservation(adapter, batch, candidate, capture_traces: false)

    event = %{
      iteration: iteration,
      candidate_idx: target_candidate_id,
      parent_ids: parent_ids,
      is_seed_candidate: target_candidate_id == 0,
      deadline: Coordinator.deadline(Keyword.get(opts, :evaluation_timeout, :infinity))
    }

    state =
      if state.candidates == [] or state.proposal_policy.resolved != 1 do
        state
      else
        state
        |> prepare_validation!(candidate, ids, metric_calls, event, opts)
        |> start_validation!(opts)
      end

    case evaluate(adapter, batch, candidate, false, :full, state, opts, event) do
      {:ok, result, state} ->
        result = %{result | metadata: Map.put(result.metadata, :validation_ids, ids)}

        if complete_evaluation?(result) do
          {:ok, result, state}
        else
          {:error, incomplete_evaluation_reason(result), %{state | pending_validation: nil}}
        end

      {:error, reason, state} ->
        {:error, reason, %{state | pending_validation: nil}}
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

  defp maybe_skip_incomplete(result, parent, iteration, state, opts) do
    if incomplete_evaluation?(result) do
      notify(opts, :on_evaluation_skipped, %{
        iteration: iteration,
        candidate_idx: parent.id,
        reason: incomplete_evaluation_reason(result),
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

        case evaluate_singleton_batch(
               adapter,
               candidate,
               missing_batch,
               false,
               event[:deadline],
               opts
             ) do
          {:ok, missing_result} ->
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

          {:error, reason} ->
            record_ambiguous_singleton_failure(state, reservation, kind, reason, event, opts)
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

      case evaluate_singleton_batch(
             adapter,
             candidate,
             batch,
             capture_traces,
             event[:deadline],
             opts
           ) do
        {:ok, result} ->
          actual_calls = metric_calls(result, length(batch))

          case record_with_reservation(state.budget, actual_calls, reservation, kind) do
            {:ok, budget} ->
              cache_result = Keyword.get(opts, :cache_evaluation, true)
              cache = maybe_cache_result(state.cache, candidate, batch, result, cache_result)
              notify_budget_updated(opts, state, budget, actual_calls, event.iteration)
              notify_evaluation_end(opts, result, event)
              {:ok, result, %{state | budget: budget, cache: cache}}

            {:error, reason, budget} ->
              {:error, reason, %{state | budget: budget}}
          end

        {:error, reason} ->
          record_ambiguous_singleton_failure(state, reservation, kind, reason, event, opts)
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp evaluate_singleton_batch(adapter, candidate, batch, capture_traces, deadline, opts) do
    result =
      adapter
      |> Evaluation.batch_evaluate([{candidate, batch}],
        capture_traces: capture_traces,
        deadline: deadline
      )
      |> hd()

    {:ok, result}
  rescue
    error in Imp.OperationalSafetyError ->
      reraise error, __STACKTRACE__

    error ->
      if Keyword.get(opts, :raise_on_exception, true) do
        reraise error, __STACKTRACE__
      else
        {:error, {:evaluation_exception, Exception.message(error)}}
      end
  catch
    kind, reason ->
      if Keyword.get(opts, :raise_on_exception, true) do
        :erlang.raise(kind, reason, __STACKTRACE__)
      else
        {:error, {:evaluation_throw, kind, inspect(reason)}}
      end
  end

  defp record_ambiguous_singleton_failure(state, reservation, kind, reason, event, opts) do
    case record_with_reservation(state.budget, reservation, reservation, kind) do
      {:ok, budget} ->
        notify_budget_updated(opts, state, budget, reservation, event.iteration)
        {:error, reason, %{state | budget: budget}}

      {:error, budget_reason, budget} ->
        {:error, budget_reason, %{state | budget: budget}}
    end
  end

  defp maybe_cache_result(cache, candidate, batch, result, true) do
    if complete_evaluation?(result),
      do: evaluation_cache_backend(cache).put(cache, candidate, batch, result),
      else: cache
  end

  defp maybe_cache_result(cache, _candidate, _batch, _result, false), do: cache

  defp acceptance_completeness(result) when is_struct(result, Result) do
    if incomplete_evaluation?(result),
      do: {:reject, incomplete_evaluation_reason(result)},
      else: :complete
  end

  defp decide_acceptance(policy, before, result, context) do
    case acceptance_completeness(result) do
      :complete -> Acceptance.decide(policy, before, result, context)
      verdict -> verdict
    end
  end

  defp complete_evaluation?(%Result{} = result), do: not incomplete_evaluation?(result)

  defp incomplete_evaluation?(%Result{metadata: metadata}) do
    complete? = Map.get(metadata, :complete?, Map.get(metadata, "complete?", true))
    complete? == false
  end

  defp incomplete_evaluation_reason(%Result{metadata: metadata}) do
    failures = Map.get(metadata, :failures, Map.get(metadata, "failures", :unknown))
    {:incomplete_evaluation, failures}
  end

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

  defp metric_calls(nil, _fallback), do: 0

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
    reservation =
      reflection_call_reservation(components, dataset, state.combee_policy) *
        reflection_attempt_limit(opts)

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
    base_reservation = ComBee.reflection_call_reservation(records, state.combee_policy)
    reservation = base_reservation * reflection_attempt_limit(opts)

    case Budget.authorize_reflections(state.budget, reservation) do
      :ok ->
        case propose_with_failure_policy(
               proposer,
               candidate,
               component,
               records,
               iteration,
               state.combee_policy,
               reflection_attempt_limit(opts)
             ) do
          {:ok, text, calls, report} ->
            state = record_reflection_result(state, calls, reservation, report, opts)
            {:ok, text, report, state}

          {:error, reason, calls, report} ->
            state = record_reflection_result(state, calls, reservation, report, opts)

            case operational_safety_error(reason) do
              nil -> {:error, reason, report, state}
              %Imp.OperationalSafetyError{} = error -> raise error
            end
        end

      {:error, reason} ->
        {:error, reason, nil, state}
    end
  end

  defp propose_with_failure_policy(
         proposer,
         candidate,
         component,
         records,
         iteration,
         policy,
         attempts_left,
         calls \\ 0
       ) do
    case ComBee.propose(proposer, candidate, component, records, iteration, policy) do
      {:ok, text, attempt_calls, report} ->
        {:ok, text, calls + attempt_calls, report}

      {:error, reason, attempt_calls, report} ->
        if attempts_left > 1 and is_nil(operational_safety_error(reason)) do
          propose_with_failure_policy(
            proposer,
            candidate,
            component,
            records,
            iteration,
            policy,
            attempts_left - 1,
            calls + attempt_calls
          )
        else
          {:error, reason, calls + attempt_calls, report}
        end
    end
  end

  defp reflection_attempt_limit(opts) do
    case Keyword.get(opts, :reflection_failure_policy, :single_attempt_fail_closed) do
      :single_attempt_fail_closed -> 1
      :gepa_v0_1_4_batch_then_single_retry -> 2
    end
  end

  defp operational_safety_error(value), do: find_operational_safety(value)

  defp find_operational_safety(%Imp.OperationalSafetyError{} = error), do: error

  defp find_operational_safety(%_{} = struct),
    do: struct |> Map.from_struct() |> find_operational_safety()

  defp find_operational_safety(map) when is_map(map) do
    Enum.find_value(map, fn {_key, value} -> find_operational_safety(value) end)
  end

  defp find_operational_safety(list) when is_list(list),
    do: Enum.find_value(list, &find_operational_safety/1)

  defp find_operational_safety(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.find_value(&find_operational_safety/1)

  defp find_operational_safety(_value), do: nil

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

  defp checkpoint!(state, opts) do
    emit_progress(state)
    checkpoint_state = snapshot_adapter_state(state, opts)

    case Keyword.get(opts, :checkpoint_fn) do
      nil ->
        :ok

      callback when is_function(callback, 1) ->
        case callback.(dump_state(checkpoint_state)) do
          :ok ->
            :ok

          other ->
            raise ArgumentError,
                  "GEPA checkpoint callback must return :ok, got: #{inspect(other)}"
        end
    end

    notify(opts, :on_state_saved, %{iteration: state.iteration, run_dir: nil})
  end

  defp snapshot_adapter_state(state, opts) do
    case Keyword.get(opts, :runtime_adapter) do
      nil -> state
      adapter -> %{state | adapter_state: Adapter.snapshot_state(adapter)}
    end
  end

  defp check_stopper(state, opts) do
    case Keyword.get(opts, :max_reflection_cost) do
      nil ->
        check_configured_stopper(state, opts)

      limit ->
        cost = reflection_cost(state, opts)

        if cost >= limit,
          do: {:stop, {:max_reflection_cost, cost, limit}, state},
          else: check_configured_stopper(state, opts)
    end
  end

  defp finalize_stop_reason(%State{stop_reason: reason} = state, _max_iterations, _opts)
       when not is_nil(reason),
       do: state

  defp finalize_stop_reason(%State{} = state, max_iterations, opts) do
    case check_stopper(state, opts) do
      {:stop, reason, state} ->
        %{state | stop_reason: reason}

      {:continue, state} when state.iteration >= max_iterations ->
        %{state | stop_reason: :max_iterations}

      {:continue, state} ->
        state
    end
  end

  defp check_configured_stopper(state, opts) do
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
          best_score: best(state).validation.aggregate_score,
          semantic_outcome: semantic_outcome(state)
        }

        case Stopper.check(policy, stopper_state, context, stopper_opts(opts)) do
          {:continue, stopper_state} ->
            {:continue, %{state | stopper_state: stopper_state}}

          {:stop, reasons, stopper_state} ->
            {:stop, {:stopper, reasons}, %{state | stopper_state: stopper_state}}
        end
    end
  end

  defp reflection_cost(state, opts) do
    source = state.reflection_strategy || Keyword.get(opts, :reflection_cost_source)

    case ReflectionStrategy.observable_cost(source) do
      {:ok, cost} ->
        cost

      :unobservable ->
        raise ArgumentError,
              ":max_reflection_cost requires a reflection strategy or LM with observable total_cost"

      {:error, {:invalid_reflection_cost, cost}} ->
        raise ArgumentError,
              "GEPA reflection cost source must report a non-negative number, got: #{inspect(cost)}"
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

  defp semantic_outcome(%State{iteration: 0}), do: :none

  defp semantic_outcome(%State{} = state) do
    latest_event = List.last(state.history)

    cond do
      is_map(latest_event) and latest_event.iteration == state.iteration and
          latest_event.status == :accepted ->
        :accepted

      is_map(latest_event) and latest_event.iteration == state.iteration and
        latest_event.status == :rejected and
          match?({:proposal_error, _reason}, latest_event.reason) ->
        :proposal_error

      is_map(latest_event) and latest_event.iteration == state.iteration and
          latest_event.status == :rejected ->
        :rejected

      true ->
        :none
    end
  end

  defp emit_progress(%State{candidates: []}), do: :ok

  defp emit_progress(%State{} = state) do
    candidate = List.last(state.candidates)

    Imp.Telemetry.execute(
      [:imp, :optimizer, :progress],
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
      execution_profile: Keyword.get(opts, :execution_profile, :beam_native),
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
      rng_algorithm: Keyword.get(opts, :rng_algorithm, :beam_native),
      reflection_failure_policy:
        Keyword.get(opts, :reflection_failure_policy, :single_attempt_fail_closed),
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
       when schema_version in [4, 5, 6, 7] do
    versioned_keys =
      case schema_version do
        4 -> []
        5 -> ["adapter_state"]
        6 -> ["adapter_state", "batch_sampler", "reflection_strategy_state"]
        7 -> ["adapter_state", "batch_sampler", "reflection_strategy_state"]
      end

    require_checkpoint_keys!(
      dumped,
      ~w(schema_version iteration candidates rejected history cache budget rng_state merge_due total_merges_tested merge_attempts last_iteration_found_candidate frontier_type evaluation_policy best_outputs_valset stopper_state budget_ledger pending_proposal_batch proposal_policy combee_policy combee_reports stop_reason pending_proposal_integrity) ++
        versioned_keys,
      ~w(pending_validation pending_validation_integrity),
      "GEPA engine checkpoint"
    )

    validate_resume_seed!(dumped, seed_candidate)

    budget = dumped |> Map.fetch!("budget") |> Budget.load!()

    configured_strategy = Keyword.get(opts, :reflection_strategy)

    combee_policy =
      load_combee_policy(dumped, schema_version, Keyword.fetch!(opts, :combee_policy))

    requested_batch_sampler = Keyword.get(opts, :batch_sampler, :epoch_shuffled)

    batch_sampler =
      case schema_version do
        7 ->
          dumped
          |> Map.fetch!("batch_sampler")
          |> BatchSampler.load!(requested_batch_sampler)

        6 ->
          unless requested_batch_sampler == :epoch_shuffled do
            raise ArgumentError,
                  "custom GEPA batch samplers cannot resume schema 6 checkpoints"
          end

          dumped
          |> Map.fetch!("batch_sampler")
          |> BatchSampler.load_legacy!(combee_policy.effective_batch_size)

        legacy when legacy in [4, 5] ->
          unless requested_batch_sampler == :epoch_shuffled do
            raise ArgumentError,
                  "custom GEPA batch samplers cannot resume schema #{legacy} checkpoints"
          end

          BatchSampler.new(combee_policy.effective_batch_size)
      end

    reflection_strategy =
      if schema_version in [6, 7] do
        ReflectionStrategy.load(
          Map.fetch!(dumped, "reflection_strategy_state"),
          configured_strategy,
          budget.reflection_calls
        )
      else
        ReflectionStrategy.load(nil, configured_strategy, budget.reflection_calls)
      end

    state = %State{
      iteration: Map.fetch!(dumped, "iteration"),
      candidates: Enum.map(Map.fetch!(dumped, "candidates"), &load_entry!/1),
      rejected: dumped |> Map.fetch!("rejected") |> restore(),
      history: dumped |> Map.fetch!("history") |> restore(),
      cache: dumped |> Map.fetch!("cache") |> load_evaluation_cache(opts),
      budget: budget,
      rng_state: dumped |> Map.fetch!("rng_state") |> load_rng!(),
      merge_due: Map.fetch!(dumped, "merge_due"),
      total_merges_tested: Map.fetch!(dumped, "total_merges_tested"),
      merge_attempts: dumped |> Map.fetch!("merge_attempts") |> restore(),
      last_iteration_found_candidate: Map.fetch!(dumped, "last_iteration_found_candidate"),
      frontier_type: dumped |> Map.fetch!("frontier_type") |> normalize_frontier_type!(),
      evaluation_policy: load_evaluation_policy(dumped, opts),
      best_outputs_valset: dumped |> Map.fetch!("best_outputs_valset") |> load_best_outputs!(),
      stopper_state: dumped |> Map.fetch!("stopper_state") |> load_stopper_state(opts),
      budget_ledger: dumped |> Map.fetch!("budget_ledger") |> BudgetLedger.load!(),
      pending_proposal_batch:
        dumped
        |> Map.fetch!("pending_proposal_batch")
        |> Proposal.load!(&load_result!/1),
      pending_validation: load_pending_validation!(dumped),
      proposal_policy:
        load_proposal_policy(dumped, schema_version, Keyword.fetch!(opts, :proposal_policy)),
      combee_policy: combee_policy,
      combee_reports: dumped |> Map.fetch!("combee_reports") |> Enum.map(&ComBee.load_report/1),
      adapter_state: dumped |> Map.get("adapter_state", %{}) |> restore_adapter_state!(),
      batch_sampler: batch_sampler,
      reflection_strategy: reflection_strategy,
      reflection_strategy_initial: configured_strategy,
      stop_reason: dumped |> Map.fetch!("stop_reason") |> restore()
    }

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

  defp load_state!(state, _seed_candidate, _opts),
    do: raise(ArgumentError, "invalid GEPA engine resume state: #{inspect(state)}")

  defp validate_resume_seed!(%{"candidates" => [%{"candidate" => candidate} | _]}, seed) do
    unless restore(candidate) == seed do
      raise ArgumentError, "GEPA resume state does not match the seed candidate"
    end

    :ok
  end

  defp validate_resume_seed!(_dumped, _seed) do
    raise ArgumentError, "GEPA resume state does not match the seed candidate"
  end

  defp restore_adapter_state!(state) when is_map(state), do: restore(state)

  defp restore_adapter_state!(state) do
    raise ArgumentError, "GEPA adapter checkpoint state must be a map, got: #{inspect(state)}"
  end

  defp dump_entry(%Entry{} = entry) do
    %{
      "id" => entry.id,
      "candidate" => Imp.Optimizer.Report.encode_term(entry.candidate),
      "validation" => dump_result(entry.validation),
      "parent_ids" => entry.parent_ids,
      "next_component" => entry.next_component,
      "discovered_at" => entry.discovered_at
    }
  end

  defp load_entry!(entry) do
    require_exact_keys!(
      entry,
      ~w(id candidate validation parent_ids next_component discovered_at),
      "GEPA candidate entry"
    )

    %Entry{
      id: Map.fetch!(entry, "id"),
      candidate: restore(Map.fetch!(entry, "candidate")),
      validation: entry |> Map.fetch!("validation") |> load_result!(),
      parent_ids: Map.fetch!(entry, "parent_ids"),
      next_component: Map.fetch!(entry, "next_component"),
      discovered_at: Map.fetch!(entry, "discovered_at")
    }
  end

  defp dump_result(%Result{} = result) do
    %{
      "outputs" => Enum.map(result.outputs, &dump_runtime_term/1),
      "aggregate_score" => result.aggregate_score,
      "scores" => result.scores,
      "objective_scores" => Imp.Optimizer.Report.encode_term(result.objective_scores),
      "trajectories" =>
        Map.new(result.trajectories, fn {component, trajectories} ->
          {component, Enum.map(trajectories, &dump_runtime_term/1)}
        end)
        |> Imp.Optimizer.Report.encode_term(),
      "side_information" => Imp.Optimizer.Report.encode_term(result.side_information),
      "metadata" => Imp.Optimizer.Report.encode_term(result.metadata)
    }
  end

  defp load_result!(result) do
    require_exact_keys!(
      result,
      ~w(outputs aggregate_score scores objective_scores trajectories side_information metadata),
      "GEPA evaluation result"
    )

    %Result{
      outputs: Enum.map(Map.fetch!(result, "outputs"), &load_runtime_term/1),
      aggregate_score: Map.fetch!(result, "aggregate_score"),
      scores: Map.fetch!(result, "scores"),
      objective_scores: result |> Map.fetch!("objective_scores") |> restore(),
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
    cache
    |> Enum.sort_by(fn {{candidate_digest, example_digest}, _entry} ->
      {candidate_digest, example_digest}
    end)
    |> Enum.map(fn {{candidate_digest, example_digest}, %EvaluationCache.Entry{} = entry} ->
      %{
        "cache_version" => 2,
        "candidate_digest" => Base.encode16(candidate_digest, case: :lower),
        "example_digest" => Base.encode16(example_digest, case: :lower),
        "output" => dump_runtime_term(entry.output),
        "score" => entry.score,
        "objective_scores" => Imp.Optimizer.Report.encode_term(entry.objective_scores)
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
    require_exact_keys!(
      entry,
      ~w(cache_version candidate_digest example_digest output score objective_scores),
      "GEPA evaluation-cache entry"
    )

    key = {decode_digest!(candidate_digest), decode_digest!(example_digest)}

    Map.put(cache, key, %EvaluationCache.Entry{
      output: load_runtime_term(output),
      score: score,
      objective_scores: entry |> Map.fetch!("objective_scores") |> restore()
    })
  end

  defp load_cache_entry(entry, _cache),
    do: raise(ArgumentError, "invalid GEPA evaluation-cache entry: #{inspect(entry)}")

  defp decode_digest!(digest) when is_binary(digest) do
    case Base.decode16(digest, case: :mixed) do
      {:ok, decoded} when byte_size(decoded) == 32 -> decoded
      _ -> raise ArgumentError, "invalid GEPA evaluation-cache digest"
    end
  end

  defp dump_runtime_term(nil), do: nil

  defp dump_runtime_term(%Imp.Prediction{} = prediction) do
    %{
      "__gepa_type__" => "prediction",
      "fields" => Imp.Optimizer.Report.encode_term(prediction.fields),
      "completions" => Imp.Optimizer.Report.encode_term(prediction.completions),
      "score" => prediction.score,
      "metadata" => Imp.Optimizer.Report.encode_term(prediction.metadata)
    }
  end

  defp dump_runtime_term(%Trajectory{} = trajectory) do
    %{
      "__gepa_type__" => "trajectory",
      "state" => Trajectory.dump(trajectory)
    }
  end

  defp dump_runtime_term(term), do: Imp.Optimizer.Report.encode_term(term)

  defp load_runtime_term(%{"__gepa_type__" => "prediction"} = state) do
    require_exact_keys!(
      state,
      ~w(__gepa_type__ fields completions score metadata),
      "GEPA runtime prediction"
    )

    Imp.Prediction.new(restore(Map.fetch!(state, "fields")),
      completions: state |> Map.fetch!("completions") |> restore(),
      score: Map.fetch!(state, "score"),
      metadata: state |> Map.fetch!("metadata") |> restore()
    )
  end

  defp load_runtime_term(%{"__gepa_type__" => "trajectory", "state" => state}) do
    Trajectory.load!(state)
  end

  defp load_runtime_term(term), do: restore(term)

  defp normalize_frontier_type!(type) when type in [:instance, :objective, :hybrid, :cartesian],
    do: type

  defp normalize_frontier_type!(type)
       when type in ["instance", "objective", "hybrid", "cartesian"],
       do: String.to_existing_atom(type)

  defp normalize_frontier_type!(type),
    do: raise(ArgumentError, "invalid GEPA frontier type in resume state: #{inspect(type)}")

  defp load_evaluation_policy(dumped, opts) do
    policy = opts |> Keyword.get(:evaluation_policy, :full) |> EvaluationPolicy.resolve!()
    stored = Map.fetch!(dumped, "evaluation_policy")

    if stored == Atom.to_string(policy),
      do: policy,
      else: raise(ArgumentError, "GEPA resume evaluation policy mismatch: #{inspect(stored)}")
  end

  defp restore(value), do: Imp.Optimizer.Report.decode_term(value)

  defp require_exact_keys!(map, keys, context) when is_map(map) do
    unless MapSet.new(Map.keys(map)) == MapSet.new(keys) do
      raise ArgumentError, "#{context} has unexpected or missing keys"
    end

    :ok
  end

  defp require_checkpoint_keys!(map, required, optional, context) when is_map(map) do
    keys = MapSet.new(Map.keys(map))
    required = MapSet.new(required)
    optional = MapSet.new(optional)

    unless MapSet.subset?(required, keys) and
             MapSet.subset?(keys, MapSet.union(required, optional)) do
      raise ArgumentError, "#{context} has unexpected or missing keys"
    end

    :ok
  end

  defp dump_rng(rng_state), do: Random.dump(rng_state)
  defp load_rng!(value), do: Random.load!(value)

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
    BatchSampler.validate_strategy!(Keyword.get(opts, :batch_sampler, :epoch_shuffled))
    minibatch_size = requested_minibatch_size(opts, length(trainset))
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
    max_reflection_cost = Keyword.get(opts, :max_reflection_cost)
    reflection_strategy = Keyword.get(opts, :reflection_strategy)
    raise_on_exception = Keyword.get(opts, :raise_on_exception, true)
    proposal_concurrency = Keyword.get(opts, :proposal_concurrency, 1)
    proposal_timeout = Keyword.get(opts, :proposal_timeout, :infinity)
    sampling_strategy = Keyword.get(opts, :sampling_strategy, :single)
    selection_strategy = Keyword.get(opts, :selection_strategy, :all_improvements)
    execution_profile = Keyword.get(opts, :execution_profile, :beam_native)
    rng_algorithm = Keyword.get(opts, :rng_algorithm, :beam_native)

    reflection_failure_policy =
      Keyword.get(opts, :reflection_failure_policy, :single_attempt_fail_closed)

    merge_acceptance_policy =
      Keyword.get(opts, :merge_acceptance_policy, Acceptance.default(:merge))

    case Callback.validate(Keyword.get(opts, :callbacks, [])) do
      {:ok, _callbacks} -> :ok
      {:error, message} -> raise ArgumentError, ":callbacks #{message}"
    end

    EvaluationPolicy.resolve!(Keyword.get(opts, :evaluation_policy, :full))
    CandidateSelector.validate!(Keyword.get(opts, :candidate_selection_strategy, :pareto))
    ModuleSelector.validate!(Keyword.get(opts, :module_selector, :round_robin))
    validate_sampling_strategy!(sampling_strategy)
    ProposalSelection.validate!(selection_strategy)
    ReflectionStrategy.validate!(reflection_strategy)

    unless execution_profile in [:beam_native, :gepa_v0_1_4],
      do: raise(ArgumentError, ":execution_profile must be :beam_native or :gepa_v0_1_4")

    unless rng_algorithm in [:beam_native, :python_v3],
      do: raise(ArgumentError, ":rng_algorithm must be :beam_native or :python_v3")

    unless reflection_failure_policy in [
             :single_attempt_fail_closed,
             :gepa_v0_1_4_batch_then_single_retry
           ],
           do: raise(ArgumentError, "invalid :reflection_failure_policy")

    if execution_profile == :gepa_v0_1_4 do
      unless rng_algorithm == :python_v3 and
               reflection_failure_policy == :gepa_v0_1_4_batch_then_single_retry and
               Keyword.get(opts, :candidate_selection_strategy, :pareto) == :pareto and
               Keyword.get(opts, :module_selector, :round_robin) == :round_robin and
               sampling_strategy == :single and selection_strategy == :all_improvements and
               proposal_concurrency == 1 and not use_merge and not cache_evaluation and
               skip_perfect_score and perfect_score == 1.0 and frontier_type == :instance and
               Keyword.get(opts, :evaluation_policy, :full) == :full do
        raise ArgumentError, "GEPA v0.1.4 execution profile options are inconsistent"
      end
    end

    unless max_reflection_calls == :infinity or
             (is_integer(max_reflection_calls) and max_reflection_calls >= 0) do
      raise ArgumentError,
            ":max_reflection_calls must be a non-negative integer or :infinity"
    end

    unless is_nil(max_reflection_cost) or
             (is_number(max_reflection_cost) and max_reflection_cost >= 0) do
      raise ArgumentError, ":max_reflection_cost must be nil or a non-negative number"
    end

    if max_reflection_cost &&
         not ReflectionStrategy.cost_observable?(
           reflection_strategy || Keyword.get(opts, :reflection_cost_source)
         ) do
      raise ArgumentError,
            ":max_reflection_cost requires a reflection strategy or LM with observable total_cost"
    end

    unless is_boolean(raise_on_exception),
      do: raise(ArgumentError, ":raise_on_exception must be a boolean")

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

  defp requested_minibatch_size(opts, trainset_size) do
    strategy = Keyword.get(opts, :batch_sampler, :epoch_shuffled)

    BatchSampler.strategy_minibatch_size(strategy, Keyword.get(opts, :minibatch_size)) ||
      min(3, trainset_size)
  end

  defp validate_sampling_strategy!(:single), do: :ok
  defp validate_sampling_strategy!({:same_parent, n}) when is_integer(n) and n > 0, do: :ok
  defp validate_sampling_strategy!({:independent, n}) when is_integer(n) and n > 0, do: :ok

  defp validate_sampling_strategy!({:pxn, p, n})
       when is_integer(p) and p > 0 and is_integer(n) and n > 0,
       do: :ok

  defp validate_sampling_strategy!(strategy) do
    raise ArgumentError,
          ":sampling_strategy must be :single, {:same_parent, n}, {:independent, n}, " <>
            "or {:pxn, p, n}; got: #{inspect(strategy)}"
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

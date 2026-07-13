defmodule DSEx.Optimizer.GEPA.Engine do
  @moduledoc false

  alias DSEx.Optimizer.GEPA.{
    Acceptance,
    Adapter,
    Budget,
    Callback,
    Candidate,
    Evaluation,
    EvaluationCache,
    EvaluationPolicy,
    Frontier,
    Merge,
    Result,
    Stopper
  }

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
              stopper_state: nil,
              stop_reason: nil
  end

  @type proposer :: (Candidate.t(), Candidate.component_name(), [map()], non_neg_integer() ->
                       String.t() | {:ok, String.t()} | {:error, term()})

  @spec run(Adapter.t(), Candidate.t(), [term()], [term()], proposer(), keyword()) :: State.t()
  def run(adapter, seed_candidate, trainset, valset, proposer, opts \\ [])
      when is_list(trainset) and is_list(valset) and is_function(proposer, 4) and is_list(opts) do
    seed_candidate = Candidate.validate!(seed_candidate)
    validate_inputs!(seed_candidate, trainset, valset, opts)

    notify(opts, :on_optimization_start, %{
      seed_candidate: seed_candidate,
      trainset_size: length(trainset),
      valset_size: length(valset),
      config: callback_config(opts)
    })

    state =
      case Keyword.get(opts, :resume_state) do
        nil -> initialize(adapter, seed_candidate, valset, opts)
        resume_state -> load_state!(resume_state, seed_candidate, opts)
      end

    max_iterations = Keyword.get(opts, :max_iterations, 10)
    minibatch_size = Keyword.get(opts, :minibatch_size, min(3, length(trainset)))

    state =
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
    %{
      "schema_version" => 1,
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
      "stopper_state" => dump_stopper_state(state.stopper_state),
      "stop_reason" => DSEx.Optimizer.Report.json_safe(state.stop_reason)
    }
  end

  defp initialize(adapter, seed_candidate, valset, opts) do
    state = %State{
      budget:
        Budget.new(
          max_metric_calls: Keyword.get(opts, :max_metric_calls, :infinity),
          max_full_evaluations: Keyword.get(opts, :max_full_evaluations, :infinity)
        ),
      rng_state: seed_rng(Keyword.get(opts, :seed, 0)),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      evaluation_policy:
        opts |> Keyword.get(:evaluation_policy, :full) |> EvaluationPolicy.resolve!(),
      stopper_state: new_stopper_state(opts)
    }

    case evaluate_validation(adapter, valset, seed_candidate, 0, [], 0, state, opts) do
      {:ok, validation, state} ->
        entry = %Entry{
          id: 0,
          candidate: seed_candidate,
          validation: validation,
          discovered_at: state.budget.metric_calls
        }

        state = %{state | candidates: [entry]}
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
      sample_parent(state.candidates, state.frontier_type, state.rng_state)

    state = %{state | rng_state: rng_state}
    {component, next_component} = select_component(parent)

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
         reflective_dataset <-
           Adapter.make_reflective_dataset(
             adapter,
             parent.candidate,
             parent_result,
             [component]
           ),
         :ok <-
           notify(opts, :on_reflective_dataset_built, %{
             iteration: iteration,
             candidate_idx: parent.id,
             components: [component],
             dataset: reflective_dataset
           }),
         :ok <-
           notify(opts, :on_proposal_start, %{
             iteration: iteration,
             parent_candidate: parent.candidate,
             components: [component],
             reflective_dataset: reflective_dataset
           }),
         {:ok, text, state} <-
           propose_with_budget(
             proposer,
             parent.candidate,
             component,
             reflective_dataset,
             iteration,
             state
           ),
         :ok <-
           notify(opts, :on_proposal_end, %{
             iteration: iteration,
             new_instructions: %{component => text}
           }),
         proposed_candidate = Map.put(parent.candidate, component, text),
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
             component: component,
             candidate: proposed_candidate
           }) do
        {:accept, acceptance} ->
          accept_candidate(
            adapter,
            valset,
            proposed_candidate,
            parent,
            component,
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
            reason: reason
          })

          {:ok,
           reject(
             state,
             iteration,
             parent,
             component,
             reason,
             parent_result,
             proposed_result,
             proposed_candidate
           )}
      end
    else
      {:error, {:budget_exhausted, _, _, _} = reason, state} ->
        {:stop, reason, state}

      {:error, reason, state} ->
        notify(opts, :on_error, %{iteration: iteration, exception: reason, will_continue: true})

        {:ok,
         reject(state, iteration, parent, component, {:proposal_error, reason}, nil, nil, nil)}

      {:error, reason} ->
        notify(opts, :on_error, %{iteration: iteration, exception: reason, will_continue: true})

        {:ok,
         reject(state, iteration, parent, component, {:proposal_error, reason}, nil, nil, nil)}
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
         component,
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
          component: component,
          minibatch_parent_score: parent_result.aggregate_score,
          minibatch_candidate_score: proposed_result.aggregate_score,
          acceptance: acceptance,
          validation_score: validation.aggregate_score
        }

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
          parent_ids: [parent.id]
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
         component,
         reason,
         parent_result,
         proposed_result,
         candidate
       ) do
    event = %{
      iteration: iteration,
      status: :rejected,
      parent_ids: [parent.id],
      component: component,
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
    {hits, missing_indexes} = EvaluationCache.lookup(state.cache, candidate, batch)

    if missing_indexes == [] do
      result = EvaluationCache.assemble(batch, hits, [], nil)

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

      with :ok <- Budget.authorize_evaluation(state.budget, length(missing_batch), kind) do
        notify_evaluation_start(opts, batch, false, event)

        missing_result =
          Evaluation.evaluate(adapter, missing_batch, candidate, capture_traces: false)

        result = EvaluationCache.assemble(batch, hits, missing_indexes, missing_result)
        actual_calls = metric_calls(missing_result, length(missing_batch))

        case Budget.record_evaluation(state.budget, actual_calls, kind) do
          {:ok, budget} ->
            cache = EvaluationCache.put(state.cache, candidate, missing_batch, missing_result)
            notify_budget_updated(opts, state, budget, actual_calls, event.iteration)
            notify_evaluation_end(opts, result, event)
            {:ok, result, %{state | budget: budget, cache: cache}}

          {:error, reason, _budget} ->
            {:error, reason, state}
        end
      else
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp evaluate_fresh(adapter, batch, candidate, capture_traces, kind, state, opts, event) do
    with :ok <- Budget.authorize_evaluation(state.budget, length(batch), kind) do
      notify_evaluation_start(opts, batch, capture_traces, event)
      result = Evaluation.evaluate(adapter, batch, candidate, capture_traces: capture_traces)
      actual_calls = metric_calls(result, length(batch))

      case Budget.record_evaluation(state.budget, actual_calls, kind) do
        {:ok, budget} ->
          cache_result = capture_traces or Keyword.get(opts, :cache_evaluation, true)
          cache = maybe_cache_result(state.cache, candidate, batch, result, cache_result)
          notify_budget_updated(opts, state, budget, actual_calls, event.iteration)
          notify_evaluation_end(opts, result, event)
          {:ok, result, %{state | budget: budget, cache: cache}}

        {:error, reason, _budget} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp maybe_cache_result(cache, candidate, batch, result, true),
    do: EvaluationCache.put(cache, candidate, batch, result)

  defp maybe_cache_result(cache, _candidate, _batch, _result, false), do: cache

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

  defp propose(proposer, candidate, component, dataset, iteration) do
    records = Map.get(dataset, component, [])

    case proposer.(candidate, component, records, iteration) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      text when is_binary(text) -> {:ok, text}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_proposal, other}}
    end
  rescue
    error -> {:error, {:proposal_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:proposal_throw, kind, reason}}
  end

  defp propose_with_budget(proposer, candidate, component, dataset, iteration, state) do
    state = %{state | budget: Budget.record_reflection(state.budget)}

    case propose(proposer, candidate, component, dataset, iteration) do
      {:ok, text} -> {:ok, text, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp select_component(%Entry{candidate: candidate, next_component: cursor}) do
    components = candidate |> Map.keys() |> Enum.sort_by(&inspect/1)
    {Enum.at(components, rem(cursor, length(components))), cursor + 1}
  end

  defp sample_parent(candidates, frontier_type, rng_state) do
    {id, rng_state} =
      candidates
      |> frontier_candidates()
      |> Frontier.sample(frontier_type, rng_state)

    {Enum.find(candidates, &(&1.id == id)), rng_state}
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
      minibatch_size: Keyword.get(opts, :minibatch_size),
      seed: Keyword.get(opts, :seed, 0),
      use_merge: Keyword.get(opts, :use_merge, false),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      cache_evaluation: Keyword.get(opts, :cache_evaluation, true),
      max_metric_calls: Keyword.get(opts, :max_metric_calls, :infinity),
      max_full_evaluations: Keyword.get(opts, :max_full_evaluations, :infinity)
    })
  end

  defp load_state!(
         %{"schema_version" => 1} = dumped,
         seed_candidate,
         opts
       ) do
    state = %State{
      iteration: Map.fetch!(dumped, "iteration"),
      candidates: Enum.map(Map.fetch!(dumped, "candidates"), &load_entry!/1),
      rejected: restore(Map.get(dumped, "rejected", [])),
      history: restore(Map.get(dumped, "history", [])),
      cache: load_cache(Map.get(dumped, "cache", [])),
      budget: dumped |> Map.fetch!("budget") |> Budget.load!(),
      rng_state: dumped |> Map.fetch!("rng_state") |> load_rng!(),
      merge_due: Map.get(dumped, "merge_due", 0),
      total_merges_tested: Map.get(dumped, "total_merges_tested", 0),
      merge_attempts:
        dumped |> Map.get("merge_attempts", %{ancestors: [], descriptions: []}) |> restore(),
      last_iteration_found_candidate: Map.get(dumped, "last_iteration_found_candidate", false),
      frontier_type: dumped |> Map.get("frontier_type", :instance) |> normalize_frontier_type!(),
      evaluation_policy: load_evaluation_policy(dumped, opts),
      stopper_state: dumped |> Map.get("stopper_state") |> load_stopper_state(opts),
      stop_reason: restore(Map.get(dumped, "stop_reason"))
    }

    unless hd(state.candidates).candidate == seed_candidate do
      raise ArgumentError, "GEPA resume state does not match the seed candidate"
    end

    requested_metric_limit = Keyword.get(opts, :max_metric_calls, state.budget.max_metric_calls)

    requested_full_limit =
      Keyword.get(opts, :max_full_evaluations, state.budget.max_full_evaluations)

    unless requested_metric_limit == state.budget.max_metric_calls and
             requested_full_limit == state.budget.max_full_evaluations do
      raise ArgumentError, "GEPA resume budget limits do not match"
    end

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
      cache: %{},
      budget: budget,
      rng_state: dumped |> Map.fetch!("rng_state") |> load_rng!(),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      evaluation_policy:
        opts |> Keyword.get(:evaluation_policy, :full) |> EvaluationPolicy.resolve!(),
      stopper_state: new_stopper_state(opts),
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

  defp dump_runtime_term(%DSEx.Optimizer.Trajectory{} = trajectory) do
    %{
      "__gepa_type__" => "trajectory",
      "state" =>
        trajectory
        |> Map.from_struct()
        |> Map.update!(:prediction, &dump_runtime_term/1)
        |> DSEx.Optimizer.Report.json_safe()
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
    state = restore(state)
    state = Map.update!(state, :prediction, &load_runtime_term/1)
    struct!(DSEx.Optimizer.Trajectory, state)
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
    acceptance_policy = Keyword.get(opts, :acceptance_policy, Acceptance.default(:mutation))

    merge_acceptance_policy =
      Keyword.get(opts, :merge_acceptance_policy, Acceptance.default(:merge))

    case Callback.validate(Keyword.get(opts, :callbacks, [])) do
      {:ok, _callbacks} -> :ok
      {:error, message} -> raise ArgumentError, ":callbacks #{message}"
    end

    EvaluationPolicy.resolve!(Keyword.get(opts, :evaluation_policy, :full))

    unless is_boolean(use_merge), do: raise(ArgumentError, ":use_merge must be a boolean")

    unless is_boolean(cache_evaluation),
      do: raise(ArgumentError, ":cache_evaluation must be a boolean")

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

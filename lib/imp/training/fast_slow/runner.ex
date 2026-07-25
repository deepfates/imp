defmodule Imp.Training.FastSlow.Runner.Context do
  @moduledoc "Runtime-only backend and prefetched dataset context for a runner step."

  alias Imp.Training.FastSlow.DatasetState

  defstruct backend: nil, cycle: nil, minibatches: nil, resulting_dataset: nil

  @type t :: %__MODULE__{
          backend: term(),
          cycle: non_neg_integer() | nil,
          minibatches: [map()] | nil,
          resulting_dataset: DatasetState.t() | nil
        }
end

defmodule Imp.Training.FastSlow.Runner do
  @moduledoc """
  Executes the orchestration order of Algorithm 1 from "Learning, Fast and Slow"
  without binding to a provider.

  The returned context contains runtime-only prefetched data required to resume a
  failed effect. Persisted training invariants remain in `FastSlow.State`.
  `FastSlow.Backend.update_slow/5` is an external weight-update handoff; this
  module does not implement or verify CISPO.
  """

  alias Imp.Training.FastSlow.{
    AdvantageGroup,
    Config,
    DatasetState,
    Event,
    Lookahead,
    OperationIntent,
    PromptPopulation,
    ReuseCache,
    Rollout,
    State
  }

  alias Imp.Training.FastSlow.Runner.Context

  @type checkpoint_snapshot :: %{state: State.t(), runner_context: map()}
  @type checkpoint_fn :: (checkpoint_snapshot() -> term())
  @type result ::
          {:ok, State.t(), Context.t()}
          | {:error, term(), State.t(), Context.t()}

  @spec run(State.t(), module(), term(), keyword()) :: result()
  def run(%State{} = state, backend, context \\ %Context{}, options \\ [])
      when is_atom(backend) and is_list(options) do
    context = normalize_context(context)
    checkpoint_fn = Keyword.get(options, :checkpoint_fn)

    unless is_nil(checkpoint_fn) or is_function(checkpoint_fn, 1),
      do: raise(ArgumentError, ":checkpoint_fn must be nil or an arity-1 function")

    state
    |> State.validate!()
    |> do_run(backend, context, checkpoint_fn)
  end

  @doc "Builds a JSON-safe runtime-context checkpoint bound to the current lookahead."
  @spec dump_context!(Context.t(), State.t()) :: map()
  def dump_context!(%Context{} = context, %State{} = state) do
    validate_context_binding!(context, state)

    payload = %{
      "backend" => Config.persisted_safe!(context.backend),
      "cycle" => context.cycle,
      "minibatches" => context.minibatches,
      "resulting_dataset" =>
        if(context.resulting_dataset, do: dataset_payload(context.resulting_dataset), else: nil)
    }

    Map.put(payload, "digest", Config.digest(payload))
  end

  @doc "Loads and validates a runtime-context checkpoint against persisted state."
  @spec load_context!(map(), State.t()) :: Context.t()
  def load_context!(dump, %State{} = state) when is_map(dump) do
    dump = Config.persisted_safe!(dump)
    digest = Map.fetch!(dump, "digest")
    payload = Map.delete(dump, "digest")

    unless digest == Config.digest(payload),
      do: raise(ArgumentError, "runner context digest is invalid")

    dataset =
      case payload["resulting_dataset"] do
        nil ->
          nil

        %{"cursor" => cursor, "epoch" => epoch, "rng" => rng} ->
          DatasetState.new!(cursor, epoch, rng)

        _ ->
          raise ArgumentError, "runner context dataset is invalid"
      end

    context = %Context{
      backend: payload["backend"],
      cycle: payload["cycle"],
      minibatches: payload["minibatches"],
      resulting_dataset: dataset
    }

    validate_context_binding!(context, state)
    context
  end

  @doc "Returns the digest used to bind an actual prefetched minibatch to lookahead state."
  @spec batch_digest(map()) :: String.t()
  def batch_digest(batch), do: batch |> data_map!(:minibatch) |> Config.digest()

  @doc "Returns the digest used for exact cache matching of one problem input."
  @spec input_digest(map()) :: String.t()
  def input_digest(problem), do: problem |> data_map!(:problem) |> Config.digest()

  defp do_run(%State{stage: :terminal} = state, _backend, context, _checkpoint_fn),
    do: {:ok, state, context}

  defp do_run(%State{stage: :initialized} = state, backend, context, checkpoint_fn) do
    state |> State.set_stage(:fast) |> do_run(backend, context, checkpoint_fn)
  end

  defp do_run(%State{stage: :fast, lookahead: nil} = state, backend, context, checkpoint_fn) do
    prefetch(state, backend, context, checkpoint_fn)
  end

  defp do_run(%State{stage: :fast} = state, backend, context, checkpoint_fn) do
    with {:ok, context} <- require_cycle_context(state, context) do
      if state.prompt_population.revision == state.cycle do
        optimize_fast(state, backend, context, checkpoint_fn)
      else
        state |> State.set_stage(:slow) |> do_run(backend, context, checkpoint_fn)
      end
    else
      {:error, reason} -> {:error, reason, state, context}
    end
  end

  defp do_run(
         %State{stage: :slow, slow_step: step, t: t} = state,
         backend,
         context,
         checkpoint_fn
       )
       when step < t do
    with {:ok, context} <- require_cycle_context(state, context) do
      slow_step(state, backend, context, checkpoint_fn)
    else
      {:error, reason} -> {:error, reason, state, context}
    end
  end

  defp do_run(%State{stage: :slow, slow_step: t, t: t} = state, backend, context, checkpoint_fn) do
    if state.cycle + 1 == state.max_cycles do
      completed =
        State.complete(
          state,
          context.resulting_dataset,
          %{"cycles" => state.max_cycles}
        )

      {:ok, completed, clear_cycle(context)}
    else
      state
      |> State.next_cycle(context.resulting_dataset)
      |> do_run(backend, clear_cycle(context), checkpoint_fn)
    end
  end

  defp prefetch(state, backend, context, checkpoint_fn) do
    payload = %{
      "cycle" => state.cycle,
      "count" => state.t,
      "dataset" => dataset_payload(state.dataset)
    }

    with_effect(state, context, backend, "fast_slow.prefetch", payload, checkpoint_fn, fn intent,
                                                                                          state,
                                                                                          context ->
      case backend.prefetch(state, state.t, intent, context.backend) do
        {:ok, minibatches, %DatasetState{} = dataset, backend_context} ->
          with {:ok, normalized, identities} <- validate_prefetch(minibatches, state.t),
               :ok <-
                 validate_prefetch_progression(
                   backend,
                   state,
                   normalized,
                   dataset,
                   backend_context
                 ) do
            lookahead = Lookahead.new!(state.cycle, state.dataset.cursor, identities)
            state = State.put_lookahead(state, lookahead)

            context = %{
              context
              | backend: backend_context,
                cycle: state.cycle,
                minibatches: normalized,
                resulting_dataset: dataset
            }

            {:ok, state, context, %{"lookahead_digest" => lookahead.digest}}
          else
            {:error, reason} ->
              {:error, reason, state, %{context | backend: backend_context}}
          end

        {:error, reason, backend_context} ->
          {:error, reason, state, %{context | backend: backend_context}}

        other ->
          {:error, {:invalid_backend_result, :prefetch, other}, state, context}
      end
    end)
    |> continue(backend, checkpoint_fn)
  end

  defp optimize_fast(state, backend, context, checkpoint_fn) do
    payload = %{
      "cycle" => state.cycle,
      "theta_id" => state.current_theta_id,
      "seed_population_digest" => state.prompt_population.digest,
      "lookahead_digest" => state.lookahead.digest,
      "candidate_count" => state.k
    }

    with_effect(state, context, backend, "fast_slow.gepa", payload, checkpoint_fn, fn intent,
                                                                                      state,
                                                                                      context ->
      case backend.optimize_fast(state, context.minibatches, intent, context.backend) do
        {:ok, result, backend_context} when is_map(result) ->
          context = %{context | backend: backend_context}

          with {:ok, candidates, metadata, cached} <- validate_gepa(result, state) do
            cached = if(state.reuse_rollouts, do: cached, else: [])
            cache = ReuseCache.new!(state.cycle, state.current_theta_id, cached)

            state =
              state
              |> State.put_reuse_cache(cache)
              |> State.revise_prompts(candidates, metadata)

            {:ok, state, context, %{"population_digest" => state.prompt_population.digest}}
          else
            {:error, reason} -> {:error, reason, state, context}
          end

        {:error, reason, backend_context} ->
          {:error, reason, state, %{context | backend: backend_context}}

        other ->
          {:error, {:invalid_backend_result, :optimize_fast, other}, state, context}
      end
    end)
    |> continue(backend, checkpoint_fn)
  end

  defp slow_step(state, backend, context, checkpoint_fn) do
    minibatch = Enum.at(context.minibatches, state.slow_step)

    with {:ok, state, context, groups} <-
           build_groups(state, backend, context, checkpoint_fn, minibatch),
         {:ok, state, context} <-
           update_slow(state, backend, context, checkpoint_fn, minibatch, groups) do
      do_run(state, backend, context, checkpoint_fn)
    else
      {:error, reason, state, context} -> {:error, reason, state, context}
    end
  end

  defp build_groups(state, backend, context, checkpoint_fn, minibatch) do
    with {:ok, problems} <- problems(minibatch) do
      problems
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, state, context, []}, fn {problem, problem_index},
                                                         {:ok, state, context, groups} ->
        case build_group(
               state,
               backend,
               context,
               checkpoint_fn,
               minibatch,
               problem,
               problem_index
             ) do
          {:ok, state, context, group} ->
            {:cont, {:ok, state, context, groups ++ [group]}}

          {:error, reason, state, context} ->
            {:halt, {:error, reason, state, context}}
        end
      end)
    else
      {:error, reason} -> {:error, reason, state, context}
    end
  end

  defp build_group(state, backend, context, checkpoint_fn, minibatch, problem, problem_index) do
    with {:ok, problem_id, dataset_indices} <- problem_identity(problem) do
      group_id = group_id(state, minibatch, problem_id, problem_index)
      per_prompt = div(state.g, state.k)

      slots =
        for prompt_index <- 0..(state.k - 1), offset <- 0..(per_prompt - 1) do
          member_index = prompt_index * per_prompt + offset

          slot(
            state,
            minibatch,
            problem,
            problem_id,
            dataset_indices,
            group_id,
            prompt_index,
            member_index
          )
        end

      Enum.reduce_while(slots, {:ok, state, context}, fn slot, {:ok, state, context} ->
        case obtain_rollout(state, backend, context, checkpoint_fn, slot) do
          {:ok, state, context} -> {:cont, {:ok, state, context}}
          {:error, reason, state, context} -> {:halt, {:error, reason, state, context}}
        end
      end)
      |> case do
        {:ok, state, context} ->
          rollouts = State.validate_complete_group!(state, group_id)
          group = AdvantageGroup.new!(rollouts, group_id, state.cycle, state.g, state.k)
          {:ok, state, context, group}

        error ->
          error
      end
    else
      {:error, reason} -> {:error, reason, state, context}
    end
  end

  defp obtain_rollout(state, backend, context, checkpoint_fn, slot) do
    case completed_slot(state, slot) do
      %Rollout{} ->
        {:ok, state, context}

      nil ->
        case State.claim_cached(state, slot.problem_id, slot.input_digest, slot.prompt_digest) do
          {:ok, cached, state} ->
            rollout = Rollout.from_cached!(cached, slot, state)
            {:ok, State.put_rollout(state, rollout), context}

          :miss ->
            live_rollout(state, backend, context, checkpoint_fn, slot)
        end
    end
  end

  defp live_rollout(state, backend, context, checkpoint_fn, slot) do
    payload = %{
      "cycle" => state.cycle,
      "slow_step" => state.slow_step,
      "group_id" => slot.group_id,
      "member_index" => slot.member_index,
      "prompt_index" => slot.prompt_index,
      "theta_id" => state.current_theta_id,
      "input_digest" => slot.input_digest,
      "prompt_digest" => slot.prompt_digest
    }

    with_effect(state, context, backend, "fast_slow.rollout", payload, checkpoint_fn, fn intent,
                                                                                         state,
                                                                                         context ->
      case backend.generate_rollout(state, slot, intent, context.backend) do
        {:ok, result, backend_context} when is_map(result) ->
          context = %{context | backend: backend_context}

          try do
            rollout = complete_live_rollout!(slot, result)
            state = State.put_rollout(state, rollout)
            {:ok, state, context, %{"rollout_id" => rollout.id}}
          rescue
            error -> {:error, {:invalid_live_rollout, Exception.message(error)}, state, context}
          end

        {:error, reason, backend_context} ->
          {:error, reason, state, %{context | backend: backend_context}}

        other ->
          {:error, {:invalid_backend_result, :generate_rollout, other}, state, context}
      end
    end)
  end

  defp update_slow(state, backend, context, checkpoint_fn, minibatch, groups) do
    payload = %{
      "cycle" => state.cycle,
      "slow_step" => state.slow_step,
      "batch_id" => batch_id!(minibatch),
      "batch_digest" => batch_digest(minibatch),
      "theta_id" => state.current_theta_id,
      "population_digest" => state.prompt_population.digest,
      "group_ids" => Enum.map(groups, & &1.id)
    }

    with_effect(
      state,
      context,
      backend,
      "fast_slow.slow_update",
      payload,
      checkpoint_fn,
      fn intent, state, context ->
        case backend.update_slow(state, minibatch, groups, intent, context.backend) do
          {:ok, theta_payload, backend_context} ->
            state = State.complete_slow_step(state, theta_payload)

            {:ok, state, %{context | backend: backend_context},
             %{"theta_id" => state.current_theta_id}}

          {:error, reason, backend_context} ->
            {:error, reason, state, %{context | backend: backend_context}}

          other ->
            {:error, {:invalid_backend_result, :update_slow, other}, state, context}
        end
      end
    )
  end

  defp with_effect(state, context, backend, kind, payload, checkpoint_fn, effect) do
    intent = OperationIntent.new!(kind, state.cycle, payload)

    case ensure_intent(state, intent) do
      {:ok, state, existing?} ->
        with :ok <- replay_allowed(backend, intent, context, existing?),
             :ok <- checkpoint(checkpoint_fn, state, context) do
          try do
            case effect.(intent, state, context) do
              {:ok, state, context, result} ->
                state =
                  state
                  |> State.reconcile_intent(intent.id, :confirmed, result)
                  |> record_operation_event(intent, "operation.confirmed", "confirmed")

                case checkpoint(checkpoint_fn, state, context) do
                  :ok -> {:ok, state, context}
                  {:error, reason} -> {:error, reason, state, context}
                end

              {:error, reason, state, context} ->
                failed = retryable(state, intent, reason)
                _ = checkpoint(checkpoint_fn, failed, context)
                {:error, reason, failed, context}
            end
          rescue
            error ->
              failed = retryable(state, intent, {:exception, Exception.message(error)})

              _ = checkpoint(checkpoint_fn, failed, context)
              {:error, {:exception, error}, failed, context}
          end
        else
          {:error, reason} -> {:error, reason, state, context}
        end

      {:error, :exhausted, state} ->
        exhausted =
          state
          |> record_budget_exhausted()
          |> State.terminate(:budget_exhausted, %{
            "budget" => "operations",
            "limit" => state.budgets.limits["operations"],
            "used" => state.budgets.used["operations"]
          })

        _ = checkpoint(checkpoint_fn, exhausted, context)
        {:error, {:budget_exhausted, :operations}, exhausted, context}
    end
  end

  defp continue({:ok, state, context}, backend, checkpoint_fn),
    do: do_run(state, backend, context, checkpoint_fn)

  defp continue(error, _backend, _checkpoint_fn), do: error

  defp validate_prefetch(minibatches, expected) when is_list(minibatches) do
    if length(minibatches) == expected do
      try do
        normalized = Enum.map(minibatches, &data_map!(&1, :minibatch))

        identities =
          Enum.map(normalized, fn batch ->
            %{"id" => batch_id!(batch), "digest" => batch_digest(batch)}
          end)

        cond do
          identities |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() != expected ->
            {:error, :duplicate_prefetched_batch_id}

          true ->
            {:ok, normalized, identities}
        end
      rescue
        error -> {:error, {:invalid_prefetch, Exception.message(error)}}
      end
    else
      {:error, {:prefetch_count, expected, length(minibatches)}}
    end
  end

  defp validate_prefetch(other, expected),
    do: {:error, {:prefetch_count, expected, other}}

  defp validate_prefetch_progression(backend, state, batches, dataset, backend_context) do
    case backend.validate_prefetch_progression(state, batches, dataset, backend_context) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_resulting_dataset_progression, reason}}
      other -> {:error, {:invalid_backend_result, :validate_prefetch_progression, other}}
    end
  rescue
    error -> {:error, {:prefetch_progression_validation_failed, error}}
  end

  defp validate_gepa(result, state) do
    try do
      candidates = Map.fetch!(result, :candidates)

      metadata = %{
        candidate_ids: Map.fetch!(result, :candidate_ids),
        instance_scores: Map.fetch!(result, :instance_scores),
        instance_frontier: Map.fetch!(result, :instance_frontier),
        anchor_digest: Map.get(result, :anchor_digest, state.lookahead.digest)
      }

      if is_list(candidates) and length(candidates) == state.k do
        PromptPopulation.new!(
          state.cycle + 1,
          candidates,
          Map.merge(metadata, %{
            parent_digest: state.prompt_population.digest,
            lookahead_digest: state.lookahead.digest
          })
        )

        cached = Map.get(result, :cached_trajectories, [])

        if is_list(cached),
          do: {:ok, candidates, metadata, cached},
          else: {:error, :invalid_cached_trajectories}
      else
        {:error, {:gepa_candidate_count, state.k, length(List.wrap(candidates))}}
      end
    rescue
      error -> {:error, {:invalid_gepa_result, Exception.message(error)}}
    end
  end

  defp problems(batch) do
    case Map.get(batch, "problems") do
      problems when is_list(problems) and problems != [] ->
        try do
          {:ok, Enum.map(problems, &data_map!(&1, :problem))}
        rescue
          error -> {:error, {:invalid_problem, Exception.message(error)}}
        end

      _ ->
        {:error, {:invalid_minibatch, "problems must be a non-empty list"}}
    end
  end

  defp problem_identity(problem) do
    id = Map.get(problem, "id")
    indices = Map.get(problem, "dataset_indices")

    if is_binary(id) and id != "" and is_list(indices) and indices != [] and
         Enum.all?(indices, &(is_integer(&1) and &1 >= 0)) do
      {:ok, id, indices}
    else
      {:error, {:invalid_problem_identity, problem}}
    end
  end

  defp slot(state, minibatch, problem, problem_id, indices, group_id, prompt_index, member_index) do
    prompt = Enum.at(state.prompt_population.candidates, prompt_index)

    %{
      cycle: state.cycle,
      slow_step: state.slow_step,
      batch_id: batch_id!(minibatch),
      group_id: group_id,
      problem: problem,
      problem_id: problem_id,
      dataset_indices: indices,
      input_digest: input_digest(problem),
      prompt: prompt,
      prompt_digest: Config.digest(prompt),
      prompt_index: prompt_index,
      member_index: member_index,
      group_size: state.g,
      theta_id: state.current_theta_id,
      prompt_revision: state.prompt_population.revision,
      sampling_config_digest: state.sampling_config_digest
    }
  end

  defp rollout_attrs(slot, result) do
    %{
      cycle: slot.cycle,
      group_id: slot.group_id,
      problem_id: slot.problem_id,
      group_size: slot.group_size,
      member_index: slot.member_index,
      prompt_index: slot.prompt_index,
      theta_id: slot.theta_id,
      prompt_revision: slot.prompt_revision,
      dataset_indices: slot.dataset_indices,
      input_digest: slot.input_digest,
      prompt_digest: slot.prompt_digest,
      behavior_policy_id: slot.theta_id,
      sampling_config_digest: slot.sampling_config_digest,
      behavior_logprobs: Map.fetch!(result, :behavior_logprobs),
      response_token_ids: Map.fetch!(result, :response_token_ids),
      response_mask: Map.fetch!(result, :response_mask),
      source: :live,
      generated_at_step: slot.slow_step
    }
  end

  defp complete_live_rollout!(slot, result) do
    claim_id = claim_id(slot)

    rollout = Rollout.new!(rollout_attrs(slot, result))
    {:ok, rollout} = Rollout.claim(rollout, claim_id)

    Rollout.complete!(
      rollout,
      claim_id,
      Map.fetch!(result, :output),
      Map.fetch!(result, :score),
      Map.get(result, :metrics, %{})
    )
  end

  defp group_id(state, minibatch, problem_id, problem_index) do
    Config.digest(%{
      "kind" => "fast_slow_group",
      "cycle" => state.cycle,
      "slow_step" => state.slow_step,
      "batch_id" => batch_id!(minibatch),
      "problem_id" => problem_id,
      "problem_index" => problem_index
    })
  end

  defp claim_id(slot) do
    Config.digest(%{
      "kind" => "fast_slow_rollout_claim",
      "group_id" => slot.group_id,
      "member_index" => slot.member_index
    })
  end

  defp completed_slot(state, slot) do
    Enum.find(Map.values(state.rollout_ledger), fn rollout ->
      rollout.status == :complete and rollout.group_id == slot.group_id and
        rollout.member_index == slot.member_index and rollout.problem_id == slot.problem_id and
        rollout.prompt_index == slot.prompt_index
    end)
  end

  defp batch_id!(batch) do
    case Map.get(batch, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> raise ArgumentError, "prefetched minibatch requires a non-empty id"
    end
  end

  defp data_map!(value, _label) when is_map(value) and not is_struct(value),
    do: Config.persisted_safe!(value)

  defp data_map!(_value, label), do: raise(ArgumentError, "#{label} must be a data-only map")

  defp dataset_payload(dataset), do: dataset |> Map.from_struct() |> Config.persisted_safe!()

  defp ensure_intent(state, intent) do
    case Map.get(state.pending_operations, intent.id) do
      nil ->
        case State.charge_budget(state, :operations, 1) do
          {:ok, state} ->
            state =
              state
              |> State.put_intent(intent)
              |> record_operation_event(intent, "operation.intent", "unreconciled")

            {:ok, state, false}

          {:error, :exhausted} ->
            {:error, :exhausted, state}
        end

      %OperationIntent{} ->
        {:ok, state, true}
    end
  end

  defp retryable(state, intent, reason) do
    state
    |> State.reconcile_intent(intent.id, :retryable, error_result(reason))
    |> record_operation_event(intent, "operation.retryable", "retryable")
  end

  defp record_operation_event(state, intent, kind, reconciliation) do
    State.record_event(
      state,
      Event.new!(
        sequence: length(state.events),
        kind: kind,
        cycle: state.cycle,
        operation_id: intent.id,
        data: %{
          "operation_kind" => intent.kind,
          "reconciliation" => reconciliation
        }
      )
    )
  end

  defp record_budget_exhausted(state) do
    State.record_event(
      state,
      Event.new!(
        sequence: length(state.events),
        kind: "budget.exhausted",
        cycle: state.cycle,
        data: %{
          "budget" => "operations",
          "limit" => state.budgets.limits["operations"],
          "used" => state.budgets.used["operations"]
        }
      )
    )
  end

  defp replay_allowed(_backend, _intent, _context, false), do: :ok

  defp replay_allowed(backend, intent, context, true) do
    if backend.replay_safe?(intent, context.backend),
      do: :ok,
      else: {:error, {:ambiguous_external_outcome, intent.id}}
  rescue
    error -> {:error, {:replay_safety_check_failed, error}}
  end

  defp checkpoint(nil, _state, _context), do: :ok

  defp checkpoint(checkpoint_fn, state, context) do
    snapshot = %{state: state, runner_context: dump_context!(context, state)}

    case checkpoint_fn.(snapshot) do
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
      _ -> :ok
    end
  rescue
    error -> {:error, {:checkpoint_failed, error}}
  end

  defp error_result(reason), do: %{"error" => inspect(reason)}

  defp normalize_context(%Context{} = context), do: context
  defp normalize_context(backend_context), do: %Context{backend: backend_context}

  defp require_cycle_context(state, %Context{cycle: cycle, minibatches: batches} = context)
       when cycle == state.cycle and is_list(batches) do
    if length(batches) == state.t and context.resulting_dataset != nil,
      do: {:ok, context},
      else: {:error, :incomplete_runner_context}
  end

  defp require_cycle_context(_state, _context), do: {:error, :missing_runner_context}

  defp validate_context_binding!(
         %Context{cycle: nil, minibatches: nil, resulting_dataset: nil},
         state
       ) do
    if is_nil(state.lookahead),
      do: :ok,
      else: raise(ArgumentError, "runner context is missing lookahead data")
  end

  defp validate_context_binding!(%Context{} = context, %State{lookahead: %Lookahead{} = lookahead}) do
    identities =
      Enum.map(context.minibatches || [], fn batch ->
        batch = data_map!(batch, :minibatch)
        %{"id" => batch_id!(batch), "digest" => batch_digest(batch)}
      end)

    expected = Lookahead.new!(context.cycle, lookahead.dataset_cursor, identities)

    unless context.cycle == state_cycle(lookahead) and expected.digest == lookahead.digest and
             match?(%DatasetState{}, context.resulting_dataset) do
      raise ArgumentError, "runner context does not match persisted lookahead"
    end

    :ok
  end

  defp validate_context_binding!(_context, _state),
    do: raise(ArgumentError, "runner context shape does not match persisted state")

  defp state_cycle(lookahead), do: lookahead.cycle

  defp clear_cycle(context),
    do: %{context | cycle: nil, minibatches: nil, resulting_dataset: nil}
end

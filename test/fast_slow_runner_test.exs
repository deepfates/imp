defmodule Imp.Training.FastSlow.RunnerTest do
  use ExUnit.Case, async: true

  alias Imp.Training.FastSlow.{
    CachedTrajectory,
    Config,
    DatasetState,
    Runner,
    State
  }

  defmodule FakeBackend do
    @behaviour Imp.Training.FastSlow.Backend

    alias Imp.Training.FastSlow.{CachedTrajectory, Config, DatasetState, Runner}

    @impl true
    def prefetch(state, count, intent, context) do
      batches =
        for offset <- 0..(count - 1) do
          index = state.dataset.cursor + offset

          %{
            "id" => "cycle-#{state.cycle}-batch-#{offset}",
            "problems" => [
              %{
                "id" => "problem-#{index}",
                "dataset_indices" => [index],
                "query" => "question-#{index}"
              }
            ]
          }
        end

      dataset =
        DatasetState.new!(
          state.dataset.cursor + count,
          state.dataset.epoch,
          %{"offset" => state.dataset.cursor + count}
        )

      context =
        record(context, %{
          "kind" => "prefetch",
          "intent_id" => intent.id,
          "batch_ids" => Enum.map(batches, & &1["id"])
        })

      {:ok, batches, dataset, context}
    end

    @impl true
    def validate_prefetch_progression(state, batches, dataset, _context) do
      problem_count =
        Enum.reduce(batches, 0, fn batch, count ->
          count + length(batch["problems"])
        end)

      if dataset.cursor == state.dataset.cursor + problem_count,
        do: :ok,
        else: {:error, :cursor_mismatch}
    end

    @impl true
    def optimize_fast(state, batches, intent, context) do
      candidates = ["prompt-a", "prompt-b"]
      candidate_ids = Enum.map(candidates, &Config.digest/1)
      [left, right] = candidate_ids

      instance_scores = %{
        "problem-0" => %{left => 1.0, right => 0.0},
        "problem-1" => %{left => 0.0, right => 1.0}
      }

      instance_frontier = %{"problem-0" => [left], "problem-1" => [right]}
      [first_batch | _] = batches
      [first_problem | _] = first_batch["problems"]

      cached =
        CachedTrajectory.new!(
          cycle: state.cycle,
          theta_id: state.current_theta_id,
          problem_id: first_problem["id"],
          input_digest: Runner.input_digest(first_problem),
          prompt_digest: Config.digest(hd(candidates)),
          output: %{"answer" => "cached"},
          reward: 1.0,
          response_token_ids: [101],
          response_mask: [1],
          behavior_logprobs: [-0.01]
        )

      result = %{
        candidates: candidates,
        candidate_ids: candidate_ids,
        instance_scores: instance_scores,
        instance_frontier: instance_frontier,
        cached_trajectories: [cached]
      }

      context =
        record(context, %{
          "kind" => "gepa",
          "intent_id" => intent.id,
          "theta_id" => state.current_theta_id
        })

      {:ok, result, context}
    end

    @impl true
    def generate_rollout(_state, slot, intent, context) do
      if context["exception_rollout"] == [slot.slow_step, slot.member_index],
        do: raise("planned rollout exception")

      event = %{
        "kind" => "rollout",
        "slow_step" => slot.slow_step,
        "member_index" => slot.member_index,
        "prompt_index" => slot.prompt_index,
        "intent_id" => intent.id
      }

      context = record(context, event)

      if context["cancel_rollout"] == [slot.slow_step, slot.member_index] do
        {:error, :cancelled, context}
      else
        live_result(slot, intent, context)
      end
    end

    defp live_result(slot, intent, context) do
      result = %{
        output: %{"answer" => "live-#{slot.slow_step}-#{slot.member_index}"},
        score: (slot.member_index + 1) / slot.group_size,
        behavior_logprobs: [-0.1 - slot.member_index / 100],
        response_token_ids: [200 + slot.member_index],
        response_mask: [1],
        metrics: %{"intent" => intent.id}
      }

      {:ok, result, context}
    end

    @impl true
    def update_slow(state, batch, groups, intent, context) do
      [group] = groups

      event = %{
        "kind" => "slow",
        "slow_step" => state.slow_step,
        "batch_id" => batch["id"],
        "prompt_indices" => Enum.map(group.members, & &1["prompt_index"]),
        "sources" => Enum.map(group.members, & &1["source"]),
        "theta_id" => state.current_theta_id,
        "population_digest" => state.prompt_population.digest,
        "intent_id" => intent.id
      }

      context = record(context, event)

      if context["fail_slow_step"] == state.slow_step and not context["failed_once"] do
        {:error, {:planned_slow_failure, state.slow_step}, Map.put(context, "failed_once", true)}
      else
        payload = %{
          "version" => state.slow_step + 1,
          "parent_theta_id" => state.current_theta_id,
          "batch_id" => batch["id"]
        }

        {:ok, payload, context}
      end
    end

    @impl true
    def replay_safe?(intent, context) do
      context["allow_replay"] or
        (intent.kind == "fast_slow.slow_update" and context["failed_once"])
    end

    defp record(context, event), do: Map.update!(context, "events", &(&1 ++ [event]))
  end

  test "runs Algorithm 1 in order with exact allocation, cache reuse, and theta evolution" do
    parent = self()

    checkpoint_fn = fn %{state: state, runner_context: runner_context} ->
      pending = Enum.map(state.pending_operations, fn {_id, intent} -> intent.reconciliation end)
      send(parent, {:checkpoint, state.stage, state.slow_step, pending, runner_context})
      :ok
    end

    context = backend_context()

    {:ok, final, runtime} =
      Runner.run(initial_state(), FakeBackend, context, checkpoint_fn: checkpoint_fn)

    assert final.stage == :terminal
    assert final.terminal.reason == :completed
    assert final.lookahead.consumed_steps == 2
    assert final.dataset.cursor == 2
    assert final.prompt_population.candidates == ["prompt-a", "prompt-b"]
    assert length(final.prompt_population.candidates) == final.k

    assert Enum.map(final.theta_lineage, & &1.payload) == [
             %{"version" => 0},
             %{
               "batch_id" => "cycle-0-batch-0",
               "parent_theta_id" => Enum.at(final.theta_lineage, 0).id,
               "version" => 1
             },
             %{
               "batch_id" => "cycle-0-batch-1",
               "parent_theta_id" => Enum.at(final.theta_lineage, 1).id,
               "version" => 2
             }
           ]

    events = runtime.backend["events"]

    assert [
             %{"kind" => "prefetch", "batch_ids" => ["cycle-0-batch-0", "cycle-0-batch-1"]},
             %{"kind" => "gepa"}
             | _
           ] = events

    slow_events = Enum.filter(events, &(&1["kind"] == "slow"))

    assert [first_slow, second_slow] = slow_events

    assert %{
             "slow_step" => 0,
             "batch_id" => "cycle-0-batch-0",
             "prompt_indices" => [0, 0, 1, 1],
             "sources" => ["gepa_cache", "live", "live", "live"],
             "population_digest" => population_digest
           } = first_slow

    assert %{
             "slow_step" => 1,
             "batch_id" => "cycle-0-batch-1",
             "prompt_indices" => [0, 0, 1, 1],
             "sources" => ["live", "live", "live", "live"],
             "population_digest" => ^population_digest
           } = second_slow

    assert events |> Enum.count(&(&1["kind"] == "rollout")) == 7
    assert map_size(final.rollout_ledger) == 8

    assert Enum.count(final.rollout_ledger, fn {_id, rollout} -> rollout.source == :gepa_cache end) ==
             1

    assert_received {:checkpoint, :fast, 0, [:unreconciled], _}
    assert_received {:checkpoint, :slow, 0, [], _}
    assert final.pending_operations == %{}
    assert final.budgets.used["operations"] == 11

    assert Enum.frequencies_by(final.events, & &1.kind) == %{
             "operation.confirmed" => 11,
             "operation.intent" => 11
           }

    assert Enum.map(final.events, & &1.sequence) == Enum.to_list(0..21)
    assert State.validate!(final) == final
  end

  test "returns retryable state and runtime context, then resumes without repeating live slots" do
    context = backend_context(fail_slow_step: 1)

    assert {:error, {:planned_slow_failure, 1}, failed, runtime} =
             Runner.run(initial_state(), FakeBackend, context)

    assert failed.stage == :slow
    assert failed.slow_step == 1
    assert failed.lookahead.consumed_steps == 1
    assert map_size(failed.rollout_ledger) == 8
    used_before_resume = failed.budgets.used["operations"]

    assert [%{kind: "fast_slow.slow_update", reconciliation: :retryable, attempts: 1}] =
             Map.values(failed.pending_operations)

    live_before_resume = Enum.count(runtime.backend["events"], &(&1["kind"] == "rollout"))
    assert live_before_resume == 7

    assert {:ok, final, resumed} = Runner.run(failed, FakeBackend, runtime)
    assert final.stage == :terminal
    assert final.slow_step == 2
    assert final.pending_operations == %{}
    assert final.budgets.used["operations"] == used_before_resume
    assert Enum.count(final.events, &(&1.kind == "operation.retryable")) == 1
    assert Enum.count(resumed.backend["events"], &(&1["kind"] == "rollout")) == live_before_resume

    assert resumed.backend["events"]
           |> Enum.filter(&(&1["kind"] == "slow"))
           |> Enum.map(& &1["slow_step"]) == [0, 1, 1]
  end

  test "durably dumps and loads runtime context bound to actual lookahead digests" do
    context = backend_context(fail_slow_step: 1)
    {:error, _, failed, runtime} = Runner.run(initial_state(), FakeBackend, context)

    dump = Runner.dump_context!(runtime, failed)
    loaded = Runner.load_context!(dump, failed)
    assert loaded == runtime
    assert Runner.dump_context!(loaded, failed) == dump

    assert {:ok, final, _runtime} = Runner.run(failed, FakeBackend, loaded)
    assert final.stage == :terminal

    tampered = put_in(dump, ["minibatches", Access.at(0), "id"], "different")

    assert_raise ArgumentError, ~r/digest is invalid/, fn ->
      Runner.load_context!(tampered, failed)
    end
  end

  test "does not reuse GEPA trajectories when rollout reuse is disabled" do
    {:ok, final, runtime} =
      Runner.run(initial_state(reuse_rollouts: false), FakeBackend, backend_context())

    assert Enum.all?(final.rollout_ledger, fn {_id, rollout} -> rollout.source == :live end)
    assert Enum.count(runtime.backend["events"], &(&1["kind"] == "rollout")) == 8
  end

  test "cancellation and exceptions remain ambiguous and are never silently replayed" do
    cancellation = backend_context(cancel_rollout: {0, 1})

    assert {:error, :cancelled, cancelled, cancelled_runtime} =
             Runner.run(initial_state(), FakeBackend, cancellation)

    cancelled_count = length(cancelled_runtime.backend["events"])
    [cancelled_intent] = Map.values(cancelled.pending_operations)
    assert cancelled_intent.kind == "fast_slow.rollout"
    assert cancelled_intent.reconciliation == :retryable
    cancelled_intent_id = cancelled_intent.id

    assert {:error, {:ambiguous_external_outcome, ^cancelled_intent_id}, same, replay_runtime} =
             Runner.run(cancelled, FakeBackend, cancelled_runtime)

    assert same == cancelled
    assert length(replay_runtime.backend["events"]) == cancelled_count

    exception = backend_context(exception_rollout: {0, 1})

    assert {:error, {:exception, %RuntimeError{}}, raised, raised_runtime} =
             Runner.run(initial_state(), FakeBackend, exception)

    [raised_intent] = Map.values(raised.pending_operations)
    raised_intent_id = raised_intent.id

    assert {:error, {:ambiguous_external_outcome, ^raised_intent_id}, ^raised, _} =
             Runner.run(raised, FakeBackend, raised_runtime)
  end

  test "rejects backend prefetch cardinality before installing lookahead" do
    defmodule ShortPrefetchBackend do
      @behaviour Imp.Training.FastSlow.Backend

      defdelegate optimize_fast(state, batches, intent, context), to: FakeBackend
      defdelegate generate_rollout(state, slot, intent, context), to: FakeBackend
      defdelegate update_slow(state, batch, groups, intent, context), to: FakeBackend
      defdelegate replay_safe?(intent, context), to: FakeBackend
      defdelegate validate_prefetch_progression(state, batches, dataset, context), to: FakeBackend

      @impl true
      def prefetch(state, _count, _intent, context) do
        batch = %{"id" => "short", "problems" => []}
        {:ok, [batch], DatasetState.new!(state.dataset.cursor + 1, 0, %{}), context}
      end
    end

    assert {:error, {:prefetch_count, 2, 1}, failed, _runtime} =
             Runner.run(initial_state(), ShortPrefetchBackend, backend_context())

    assert failed.stage == :fast
    assert failed.lookahead == nil

    assert [%{kind: "fast_slow.prefetch", reconciliation: :retryable}] =
             Map.values(failed.pending_operations)
  end

  test "stops before dispatch when the durable operation budget is exhausted" do
    state = initial_state(budgets: %{"operations" => 2})

    assert {:error, {:budget_exhausted, :operations}, exhausted, runtime} =
             Runner.run(state, FakeBackend, backend_context())

    assert exhausted.stage == :terminal
    assert exhausted.terminal.reason == :budget_exhausted

    assert exhausted.terminal.details == %{
             "budget" => "operations",
             "limit" => 2,
             "used" => 2
           }

    assert exhausted.budgets.used == %{"operations" => 2}

    assert Enum.map(exhausted.events, &{&1.kind, &1.data["operation_kind"]}) == [
             {"operation.intent", "fast_slow.prefetch"},
             {"operation.confirmed", "fast_slow.prefetch"},
             {"operation.intent", "fast_slow.gepa"},
             {"operation.confirmed", "fast_slow.gepa"},
             {"budget.exhausted", nil}
           ]

    assert runtime.backend["events"] |> Enum.map(& &1["kind"]) == ["prefetch", "gepa"]
    assert State.validate!(exhausted) == exhausted
  end

  defp initial_state(options \\ []) do
    config =
      Config.new!(
        program_topology: %{"predictors" => ["answer"]},
        models: %{"behavior" => "fake", "reflection" => "fake"},
        dataset_digests: %{"train" => String.duplicate("a", 64)},
        verifier_version: "fake-v1",
        adapter_version: "fake-v1",
        t: 2,
        k: 2,
        g: 4,
        max_cycles: 1,
        reuse_rollouts: Keyword.get(options, :reuse_rollouts, true),
        sampling_config: %{"temperature" => 0.7}
      )

    State.new!(config, %{"version" => 0}, ["seed-prompt"],
      budgets: Keyword.get(options, :budgets, %{"operations" => 1_000_000})
    )
  end

  defp backend_context(options \\ []) do
    %{
      "events" => [],
      "fail_slow_step" => Keyword.get(options, :fail_slow_step),
      "failed_once" => false,
      "allow_replay" => Keyword.get(options, :allow_replay, false),
      "cancel_rollout" => tuple_as_list(Keyword.get(options, :cancel_rollout)),
      "exception_rollout" => tuple_as_list(Keyword.get(options, :exception_rollout))
    }
  end

  defp tuple_as_list(nil), do: nil
  defp tuple_as_list(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
end

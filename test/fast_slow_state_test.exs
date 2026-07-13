defmodule DSEx.Training.FastSlow.StateTest do
  use ExUnit.Case, async: true

  alias DSEx.Training.FastSlow.{Config, DatasetState, OperationIntent, Rollout, State}

  test "config enforces K divides G, JSON-only values, and credential exclusion" do
    assert_raise ArgumentError, ~r/g must be divisible by k/, fn -> config(k: 3, g: 4) end

    assert_raise ArgumentError, ~r/credentials/, fn ->
      config(provider_config: %{api_key: "secret"})
    end

    assert_raise ArgumentError, ~r/JSON-safe/, fn ->
      config(optimizer_config: %{worker: self()})
    end
  end

  test "state preserves cycle, theta, population, cursor, budget, and intent invariants" do
    config = config()

    state =
      State.new!(config, %{"weights" => [0.0]}, ["prompt-a", "prompt-b"], rng: %{"seed" => 7})

    assert_raise ArgumentError, ~r/exactly k/, fn ->
      State.new!(config, %{}, ["only-one"])
    end

    intent = OperationIntent.new!("train", 0, %{"theta" => state.current_theta_id})
    assert intent.id == OperationIntent.new!("train", 0, %{"theta" => state.current_theta_id}).id

    state = State.put_intent(state, intent)
    state = State.reconcile_intent(state, intent.id, :retryable, %{"remote" => "unknown"})
    assert state.pending_operations[intent.id].attempts == 1

    state = State.reconcile_intent(state, intent.id, :confirmed, %{"job" => "done"})
    state = State.set_stage(state, :fast)
    state = State.set_stage(state, :slow)
    state = State.append_theta(state, %{"weights" => [0.1]})
    state = State.revise_prompts(state, ["prompt-c", "prompt-d"])
    state = State.next_cycle(state, DatasetState.new!(8, 1, %{"seed" => 9}))
    {:ok, state} = State.charge_budget(state, :operations, 3)

    assert state.cycle == 1
    assert state.stage == :fast
    assert state.prompt_population.revision == 1
    assert state.dataset.cursor == 8
    assert state.budgets.used["operations"] == 3
    assert Enum.map(state.theta_lineage, & &1.parent_id) == [nil, hd(state.theta_lineage).id]
    assert State.validate!(state) == state

    exhausted = State.set_stage(state, :slow)

    assert_raise ArgumentError, ~r/horizon is exhausted/, fn ->
      State.next_cycle(exhausted, DatasetState.new!(9, 1, %{"seed" => 10}))
    end

    terminal = State.terminate(exhausted, :completed, %{"cycles" => 2})
    assert terminal.stage == :terminal
    assert terminal.terminal.reason == :completed
    assert State.validate!(terminal) == terminal
  end

  test "rollouts are single-claim, policy-bound, current-cycle reusable, and group-complete" do
    config = config()
    state = State.new!(config, %{"weights" => []}, ["a", "b"]) |> State.set_stage(:fast)
    rollout = rollout(state, 0)
    state = State.put_rollout(state, rollout)

    {:ok, claimed} = State.claim_rollout(state, rollout.id, "worker-a")
    assert {:error, :already_claimed} = State.claim_rollout(claimed, rollout.id, "worker-b")

    claimed = State.complete_rollout(claimed, rollout.id, "worker-a", %{"text" => "ok"}, 1.0, %{})
    completed = claimed.rollout_ledger[rollout.id]
    assert Rollout.reusable?(completed, 0, rollout_attrs(claimed, 0))
    refute Rollout.reusable?(completed, 1, rollout_attrs(claimed, 0))

    refute Rollout.reusable?(
             completed,
             0,
             rollout_attrs(claimed, 0, behavior_policy_id: "different-policy")
           )

    assert_raise ArgumentError, ~r/incomplete/, fn ->
      State.validate_complete_group!(claimed, "group-0")
    end

    complete =
      Enum.reduce(1..3, claimed, fn index, acc ->
        item = rollout(acc, index)
        acc = State.put_rollout(acc, item)
        {:ok, acc} = State.claim_rollout(acc, item.id, "worker-#{index}")

        State.complete_rollout(
          acc,
          item.id,
          "worker-#{index}",
          %{"index" => index},
          index / 10,
          %{}
        )
      end)

    assert [_, _, _, _] = State.validate_complete_group!(complete, "group-0")

    malformed =
      complete.rollout_ledger
      |> Map.values()
      |> Enum.map(fn item -> %{item | problem_id: "problem-#{item.member_index}"} end)

    assert_raise ArgumentError, ~r/incomplete or inconsistent/, fn ->
      Rollout.validate_complete_group!(malformed, "group-0", 0, 4, 2)
    end
  end

  defp config(overrides \\ []) do
    defaults = [
      program_topology: %{"predictors" => ["answer"]},
      models: %{"behavior" => "model-a", "optimizer" => "model-b"},
      dataset_digests: %{"train" => String.duplicate("a", 64)},
      verifier_version: "verifier-v1",
      adapter_version: "adapter-v1",
      t: 2,
      k: 2,
      g: 4,
      optimizer_config: %{"learning_rate" => 0.1},
      provider_config: %{"region" => "test"},
      sampling_config: %{"temperature" => 0.7}
    ]

    Config.new!(Keyword.merge(defaults, overrides))
  end

  defp rollout(state, index), do: Rollout.new!(rollout_attrs(state, index))

  defp rollout_attrs(state, index, overrides \\ []) do
    defaults = [
      cycle: state.cycle,
      group_id: "group-0",
      problem_id: "problem-0",
      group_size: state.g,
      member_index: index,
      prompt_index: rem(index, state.k),
      theta_id: state.current_theta_id,
      prompt_revision: state.prompt_population.revision,
      dataset_indices: [0],
      input_digest: Config.digest(%{"input" => index}),
      behavior_policy_id: "behavior-v1",
      sampling_config_digest: state.sampling_config_digest,
      behavior_logprobs: [-0.1, -0.2]
    ]

    Keyword.merge(defaults, overrides)
  end
end

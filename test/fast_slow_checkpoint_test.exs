defmodule DSEx.Training.FastSlow.CheckpointTest do
  use ExUnit.Case, async: true

  alias DSEx.Training.FastSlow.{Checkpoint, Config, Event, OperationIntent, Rollout, State}

  test "checkpoint JSON round trip retains provider-independent training state" do
    config = config()
    state = populated_state(config)
    checkpoint = Checkpoint.dump(config, state)
    decoded = checkpoint |> Jason.encode!() |> Jason.decode!()

    assert decoded["type"] == "dsex_fast_slow_training"
    assert decoded["schema_version"] == 2
    assert byte_size(decoded["payload_sha256"]) == 64
    assert Checkpoint.load!(decoded, config) == state
  end

  test "atomic writes replace the destination and leave no temporary checkpoint" do
    config = config()
    state = populated_state(config)

    directory =
      Path.join(System.tmp_dir!(), "dsex-fast-slow-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "state.json")
    on_exit(fn -> File.rm_rf!(directory) end)

    assert :ok = Checkpoint.write!(path, config, state)
    assert Checkpoint.read!(path, config) == state
    assert Path.wildcard(Path.join(directory, ".state.json.tmp-*")) == []
  end

  test "corruption, compatibility mismatches, and credential-bearing state fail closed" do
    config = config()
    state = populated_state(config)
    checkpoint = Checkpoint.dump(config, state)

    corrupted = put_in(checkpoint, ["payload", "state", "cycle"], 99)
    assert_raise ArgumentError, ~r/checksum/, fn -> Checkpoint.load!(corrupted, config) end

    for mismatch <- [
          config(models: %{"behavior" => "other", "optimizer" => "model-b"}),
          config(dataset_digests: %{"train" => String.duplicate("b", 64)}),
          config(sampling_config: %{"temperature" => 0.1}),
          config(verifier_version: "verifier-v2")
        ] do
      assert_raise ArgumentError, ~r/compatibility/, fn ->
        Checkpoint.load!(checkpoint, mismatch)
      end
    end

    unsafe =
      State.record_event(
        state,
        Event.new!(sequence: 0, kind: "unsafe", cycle: 0, data: %{"access_token" => "nope"})
      )

    assert_raise ArgumentError, ~r/credentials/, fn -> Checkpoint.dump(config, unsafe) end
  end

  test "legacy schema with incorrect t semantics is rejected explicitly" do
    assert_raise ArgumentError, ~r/schema 1 encoded t as a cycle horizon/, fn ->
      Checkpoint.load!(%{"type" => "dsex_fast_slow_training", "schema_version" => 1}, config())
    end
  end

  test "valid-checksum adversarial payloads cannot forge lineage, intents, or enum atoms" do
    config = config()
    checkpoint = Checkpoint.dump(config, populated_state(config))

    forged_parent =
      checkpoint
      |> put_in(["payload", "state", "theta_lineage", Access.at(0), "parent_id"], "forged")
      |> resign()

    assert_raise ArgumentError, ~r/theta identity|aggregate invariants/, fn ->
      Checkpoint.load!(forged_parent, config)
    end

    forged_intent =
      checkpoint
      |> put_in(["payload", "state", "pending_operations", Access.at(0), "payload"], %{
        "job" => "changed"
      })
      |> resign()

    assert_raise ArgumentError, ~r/operation intent identity/, fn ->
      Checkpoint.load!(forged_intent, config)
    end

    forged_status =
      checkpoint
      |> put_in(
        ["payload", "state", "rollout_ledger", Access.at(0), "status"],
        "never_make_this_an_atom"
      )
      |> resign()

    assert_raise ArgumentError, ~r/unsupported value/, fn ->
      Checkpoint.load!(forged_status, config)
    end
  end

  test "rollout provenance is checksummed and required when restoring" do
    config = config()
    checkpoint = Checkpoint.dump(config, populated_state(config))

    for key <- ["behavior_policy_id", "sampling_config_digest", "behavior_logprobs"] do
      adversarial =
        checkpoint
        |> update_in(["payload", "state", "rollout_ledger", Access.at(0)], &Map.delete(&1, key))
        |> resign()

      assert_raise ArgumentError, fn -> Checkpoint.load!(adversarial, config) end
    end
  end

  defp populated_state(config) do
    state =
      config
      |> State.new!(%{"weights" => [0.0]}, ["seed"])
      |> State.set_stage(:fast)
      |> State.revise_prompts(["p0", "p1"])
      |> State.set_stage(:slow)

    intent = OperationIntent.new!("provider-operation", 0, %{"job" => "job-1"})
    state = State.put_intent(state, intent)

    rollout =
      Rollout.new!(
        cycle: 0,
        group_id: "group-0",
        problem_id: "problem-0",
        group_size: 4,
        member_index: 0,
        prompt_index: 0,
        theta_id: state.current_theta_id,
        prompt_revision: state.prompt_population.revision,
        dataset_indices: [3],
        input_digest: Config.digest(%{"input" => 3}),
        behavior_policy_id: "behavior-v1",
        sampling_config_digest: state.sampling_config_digest,
        behavior_logprobs: [-0.4, -0.2]
      )

    state = State.put_rollout(state, rollout)
    {:ok, state} = State.claim_rollout(state, rollout.id, "claim-1")

    State.complete_rollout(state, rollout.id, "claim-1", %{"answer" => "ok"}, 0.5, %{
      "reward" => 0.5
    })
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
      max_cycles: 2,
      optimizer_config: %{"algorithm" => "adam"},
      provider_config: %{"region" => "test"},
      sampling_config: %{"temperature" => 0.7}
    ]

    Config.new!(Keyword.merge(defaults, overrides))
  end

  defp resign(checkpoint) do
    payload = checkpoint["payload"]

    digest =
      payload
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Map.put(checkpoint, "payload_sha256", digest)
  end
end

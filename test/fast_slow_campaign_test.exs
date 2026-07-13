defmodule DSEx.FastSlowCampaignTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.EvaluationCache.Codec
  alias Mix.Tasks.Dsex.Benchmark.FastSlow

  test "runs the canonical Fast-Slow protocol campaign end to end" do
    artifact = FastSlow.build_artifact()

    assert artifact == FastSlow.build_artifact()
    assert artifact["schema_version"] == 1
    assert artifact["artifact_type"] == "dsex_fast_slow_protocol_campaign"

    assert artifact["artifact_sha256"] ==
             Codec.digest(Map.delete(artifact, "artifact_sha256"))

    assert artifact["quality_scope"]["label"] == "synthetic_protocol_behavior"
    refute artifact["quality_scope"]["research_effectiveness"]
    refute artifact["quality_scope"]["provider_effectiveness"]
    assert artifact["dataset"]["optimizer_callback_access"] == ["train"]
    assert artifact["dataset"]["split_overlap"] == []
    assert artifact["summary"]["all_protocol_claims_verified"]
    assert artifact["recovery"]["cancelled_rollout"]["retryable"]
    assert artifact["recovery"]["cancelled_rollout"]["state_unchanged"]
    assert artifact["recovery"]["cancelled_rollout"]["replay_blocked"]

    assert artifact["recovery"]["cancelled_rollout"]["effect_events_before_resume"] ==
             artifact["recovery"]["cancelled_rollout"]["effect_events_after_resume"]

    assert artifact["summary"]["quality_comparison"]["combined_gt_prompt_only"]
    assert artifact["summary"]["quality_comparison"]["combined_gt_slow_only"]

    assert artifact["summary"]["quality_comparison"]["values"] == %{
             "prompt_only" => 0.5,
             "slow_only" => 5 / 6,
             "combined" => 1.0
           }

    assert Enum.map(artifact["rows"], & &1["mode"]) == ~w(prompt_only slow_only combined)

    for row <- artifact["rows"] do
      assert row["all_claims_verified"]
      assert Enum.all?(row["claims"], fn {_name, verified} -> verified end)

      assert Enum.map(row["event_trace"], & &1["kind"]) == [
               "prefetch",
               "gepa",
               "rollout",
               "rollout",
               "rollout",
               "rollout",
               "slow_update",
               "rollout",
               "rollout",
               "rollout",
               "rollout",
               "slow_update",
               "slow_update"
             ]

      successful_slow =
        row["event_trace"]
        |> Enum.filter(&(&1["kind"] == "slow_update"))
        |> Enum.reject(& &1["planned_failure"])

      assert Enum.map(successful_slow, & &1["prompt_indices"]) == [
               [0, 0, 1, 1],
               [0, 0, 1, 1]
             ]

      assert successful_slow
             |> Enum.map(& &1["population_digest"])
             |> Enum.uniq()
             |> length() == 1

      assert length(row["theta_lineage"]) == 3
      assert Enum.at(row["theta_lineage"], 1)["parent_id"] == hd(row["theta_lineage"])["id"]

      assert Enum.at(row["theta_lineage"], 2)["parent_id"] ==
               Enum.at(row["theta_lineage"], 1)["id"]

      assert row["resume"]["checkpoint_schema_version"] == 4
      assert row["resume"]["pending_retryable_intents"] == 1
      assert row["resume"]["rollouts_before_resume"] == 8
      assert row["resume"]["rollouts_after_resume"] == 8
      assert row["resume"]["rollouts_repeated_on_resume"] == 0
      assert row["resume"]["replayed_definitive_slow_update"] == 1
      assert row["resume"]["completed"]
      assert row["operation_counts"]["slow_update"] == 3
      assert row["cost"]["external_provider_cost"] == 0.0

      expected_trainer_steps = if row["mode"] == "prompt_only", do: 0, else: 2
      assert row["operation_counts"]["trainer_step"] == expected_trainer_steps

      final_theta = List.last(row["theta_lineage"])["payload"]

      if row["mode"] == "prompt_only" do
        assert final_theta["artifact"] == "theta-0"
      else
        assert final_theta["artifact"] == "protocol-cispo-theta-2"
      end

      assert row["quality"]["label"] == "synthetic_protocol_behavior"
      refute row["quality"]["optimizer_received_held_out_examples"]
      refute row["quality"]["evaluation_uses_training_callback_reward"]
      assert row["quality"]["total"] == 6
    end

    path =
      Path.join(
        System.tmp_dir!(),
        "fast-slow-campaign-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    Mix.Task.reenable("dsex.benchmark.fast_slow")
    FastSlow.run(["--out", path])

    written = Jason.decode!(File.read!(path))
    assert written == artifact
    assert File.read!(path) == Codec.canonical_json!(written) <> "\n"
  end
end

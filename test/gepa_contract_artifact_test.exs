defmodule GEPAContractArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Imp.Benchmark.GepaContract

  test "compare matches current GEPA v0.1.4 acceptance and proposal-selection semantics without effectiveness claims" do
    artifact = GepaContract.compare(upstream_fixture())

    assert artifact["summary"]["structural_contract_complete"]
    assert artifact["summary"]["required_cases"] == 15
    assert artifact["summary"]["required_passing"] == 15
    refute artifact["summary"]["paper_reproduction"]
    refute artifact["summary"]["optimizer_effectiveness"]
    refute artifact["summary"]["full_optimizer_parity"]
    refute artifact["summary"]["exact_rng_sequence_parity"]
    assert Enum.all?(artifact["rows"], & &1["passing"])

    rows = Map.new(artifact["rows"], &{&1["id"], &1})
    assert rows["strict_mutation_acceptance"]["status"] == "matched"
    assert rows["equal_or_better_merge_acceptance"]["status"] == "matched"
    assert rows["weighted_pareto_selection"]["actual"]["coverage_weighted_invariant"]
    assert rows["common_ancestor_merge_overlap_gate"]["actual"]
    assert rows["json_result_resume_and_rng"]["actual"]["live_rng_state_preserved"]
    assert rows["named_program_mutation"]["actual"]["after"]["writer"] == "concise writer"
    assert rows["parallel_proposal_selection"]["status"] == "matched"
    assert rows["parallel_proposal_selection"]["actual"]["best_improvement"] == [3]
    assert rows["parallel_proposal_selection"]["actual"]["top_k_2"] == [3, 4]
    assert length(artifact["declared_native_deviations"]) == 3
  end

  test "Mix task rejects a checkout that does not satisfy the current commit, tag, and source pins" do
    root = tmp_dir("wrong-gepa-checkout")
    File.write!(Path.join(root, "pyproject.toml"), "[project]\nversion=\"0.1.3\"\n")
    {_output, 0} = System.cmd("git", ["init", "--quiet"], cd: root, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["add", "pyproject.toml"], cd: root, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Imp Contract",
          "-c",
          "user.email=contract@example.invalid",
          "commit",
          "--quiet",
          "-m",
          "fixture"
        ],
        cd: root,
        stderr_to_stdout: true
      )

    python =
      System.find_executable("python3") || flunk("python3 is required for the pin-failure test")

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Task.reenable("imp.benchmark.gepa_contract")

          GepaContract.run([
            "--python",
            python,
            "--gepa-root",
            root,
            "--out",
            tmp_dir("wrong-gepa-output")
          ])
        end)
      end

    assert error.message =~ "pinned GEPA validation failed"
    assert error.message =~ "commit: expected 8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"
  end

  defp upstream_fixture do
    %{
      "acceptance" => %{
        "strict_improvement" => [
          %{"before" => [0.5, 0.3], "after" => [0.6, 0.4], "accepted" => true},
          %{"before" => [0.5, 0.3], "after" => [0.5, 0.3], "accepted" => false},
          %{"before" => [0.5, 0.3], "after" => [0.4, 0.2], "accepted" => false},
          %{"before" => [], "after" => [], "accepted" => false}
        ],
        "improvement_or_equal" => [
          %{"before" => [0.5, 0.3], "after" => [0.6, 0.4], "accepted" => true},
          %{"before" => [0.5, 0.3], "after" => [0.5, 0.3], "accepted" => true},
          %{"before" => [0.5, 0.3], "after" => [0.4, 0.2], "accepted" => false},
          %{"before" => [], "after" => [], "accepted" => true}
        ]
      },
      "proposal_selection" => %{
        "proposals" => [
          %{"id" => 0, "before" => [0.5], "after" => [0.8]},
          %{"id" => 1, "before" => [0.5], "after" => [0.3]},
          %{"id" => 2, "before" => [0.5], "after" => [0.6]},
          %{"id" => 3, "before" => [0.5], "after" => [0.9]},
          %{"id" => 4, "before" => [0.5], "after" => [0.9]}
        ],
        "all_improvements" => [0, 2, 3, 4],
        "best_improvement" => [3],
        "top_k_2" => [3, 4]
      },
      "pareto_selection" => %{
        "mapping" => %{"x" => [0], "y" => [0], "z" => [1]},
        "reduced_mapping" => %{"x" => [0], "y" => [0], "z" => [1]},
        "draw_count" => 300,
        "counts" => %{"0" => 203, "1" => 97},
        "coverage_weighted_invariant" => true
      },
      "component_rotation" => %{
        "selected" => ["critic", "planner", "writer", "critic", "planner"],
        "next_cursor" => 2
      },
      "merge" => %{
        "eligible_ancestors" => [0],
        "quality_filtered" => [],
        "repeated_filtered" => [],
        "ancestor_triplet" => [1, 2, 0],
        "merged_candidate" => %{
          "planner" => "left planner",
          "writer" => "right writer",
          "critic" => "right critic"
        },
        "merged_parent_ids" => [1, 2],
        "merged_ancestor" => 0,
        "overlap_blocked" => true
      },
      "frontier_mappings" => frontier_mappings(),
      "budget_stops" => %{
        "metric_calls_at_9_10" => [false, true],
        "candidate_proposals_i_at_1_2" => [false, true],
        "score_threshold_at_089_09" => [false, true],
        "no_improvement_sequence" => [false, false, false, false, true]
      },
      "json_result_resume" => %{
        "roundtrip_equal" => true,
        "best_candidate" => %{"planner" => "plan", "writer" => "clear"},
        "seed" => 19,
        "seed_replay_draws" => [693, 44, 803, 916],
        "live_rng_state_serialized" => false
      },
      "named_program_mutation" => %{
        "before" => %{"planner" => "base planner", "writer" => "base writer"},
        "component" => "writer",
        "text" => "concise writer",
        "after" => %{"planner" => "base planner", "writer" => "concise writer"},
        "unchanged_components" => ["planner"]
      }
    }
  end

  defp frontier_mappings do
    %{
      "instance" => [front(["instance", "v0"], [1]), front(["instance", "v1"], [2])],
      "objective" => [
        front(["objective", "quality"], [1]),
        front(["objective", "safety"], [2])
      ],
      "hybrid" =>
        [
          front(["instance", "v0"], [1]),
          front(["instance", "v1"], [2]),
          front(["objective", "quality"], [1]),
          front(["objective", "safety"], [2])
        ]
        |> Enum.sort_by(&Jason.encode!(&1["dimension"])),
      "cartesian" => [
        front(["cartesian", "v0", "quality"], [1]),
        front(["cartesian", "v0", "safety"], [2]),
        front(["cartesian", "v1", "quality"], [1]),
        front(["cartesian", "v1", "safety"], [2])
      ]
    }
  end

  defp front(dimension, winners), do: %{"dimension" => dimension, "winners" => winners}

  defp tmp_dir(name) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{nonce}")
    File.mkdir_p!(path)
    path
  end
end

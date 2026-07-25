defmodule GEPAContractArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Imp.Benchmark.GepaContract

  @gepa_sources %{
    "src/gepa/core/engine.py" =>
      "ba361b477de74c20eb813b277b0fb85b6898ca534e09c8e878604fb1c8980c53",
    "src/gepa/core/result.py" =>
      "5ee9ccfdf31e2d4d1262793c569e44ef7b39659a3e971e4f3dc7d656d69a1d85",
    "src/gepa/core/state.py" =>
      "9ad128c981c7344ba0e89d053c2fe33e98a2d74d830679d620cb7cd0d7b1820c",
    "src/gepa/gepa_utils.py" =>
      "60aca7024e31a3e273a01187a6329f381f297a77ec7b6add4b9c90b4d64e9b6c",
    "src/gepa/proposer/base.py" =>
      "75242e6c71758444d97949fb5c38ff84cd52f2f77f5464c894f6229c9beb210c",
    "src/gepa/proposer/merge.py" =>
      "cd0a3254927e399d0cae4a212076f7577161027b3c4ff19d03c3d2150408ee5a",
    "src/gepa/strategies/acceptance.py" =>
      "a6234c188fdeab0f7181dd1f01d767fc91779512773ed4ad952df68855c1d3a4",
    "src/gepa/strategies/component_selector.py" =>
      "248cc6eb125eeddaa98f90b7780db2754ec0444a6143aeb1f97ff5660cf39568",
    "src/gepa/strategies/proposal_selection.py" =>
      "8866ac697928ab0824653117876e08af7087d4cbfe24a4feaedb8ceef9b75b18",
    "src/gepa/utils/stop_condition.py" =>
      "d33475e411a38353f34272b12b0b2a7af24bbbeca2c2e4fe6c204fa476e87fdb"
  }

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

    admitted =
      Map.merge(artifact, %{
        "schema_version" => 1,
        "evidence_tier" => "t1_gepa_v014_structural_differential_contract",
        "claim_scope" =>
          "provider-free GEPA v0.1.4 structural semantics, including parallel proposal selection",
        "generated_at" => "2026-07-25T00:00:00Z",
        "git_sha" => String.duplicate("a", 40),
        "gepa" => %{
          "version" => "0.1.4",
          "tag" => "v0.1.4",
          "commit" => "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975",
          "project_metadata_version" => "0.1.3",
          "project_metadata_version_note" =>
            "the v0.1.4 tag retains version=0.1.3 in pyproject.toml",
          "source_materialization" => "exact pinned git checkout",
          "sources" =>
            Enum.map(@gepa_sources, fn {path, sha256} -> %{"path" => path, "sha256" => sha256} end)
        }
      })

    assert :ok =
             Imp.BenchmarkTruth.ReproductionArtifactValidator.validate!(
               "gepa_contract",
               admitted
             )

    tampered = put_in(admitted, ["rows", Access.at(0), "passing"], false)

    assert_raise ArgumentError, ~r/non-matching required row/, fn ->
      Imp.BenchmarkTruth.ReproductionArtifactValidator.validate!("gepa_contract", tampered)
    end
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

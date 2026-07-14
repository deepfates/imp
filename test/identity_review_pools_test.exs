defmodule DSEx.IdentityReviewPoolsTest do
  use ExUnit.Case, async: true

  alias DSEx.IdentityReviewPools

  test "projection order is deterministic across unordered inputs" do
    decision_views = decision_views()
    assessments = assessments()

    assert {:ok, left} = IdentityReviewPools.compile(decision_views, assessments, limits())

    shuffled = %{
      decision_views
      | "candidates" => Enum.reverse(decision_views["candidates"]),
        "scenarios" => Enum.reverse(decision_views["scenarios"])
    }

    assert {:ok, right} =
             IdentityReviewPools.compile(shuffled, Enum.reverse(assessments), limits())

    assert left == right
    assert Jason.encode!(left) == Jason.encode!(right)
    refute left["selection_made"]
  end

  test "wildcard pool preserves every wildcard and sorts by best scenario rank then display" do
    report = compile!()

    assert Enum.map(report["pools"]["wildcard_pool"], & &1["candidate_id"]) ==
             ~w(cand-e cand-c cand-f)

    assert report["counts"]["wildcard_pool"]["candidate_count"] == 3
  end

  test "Pareto pool is the union of every scenario membership" do
    report = compile!()
    pool = report["pools"]["pareto_pool"]

    assert Enum.map(pool, & &1["candidate_id"]) == ~w(cand-a cand-b cand-d)

    delta = Enum.find(pool, &(&1["candidate_id"] == "cand-d"))

    assert delta["scenario_memberships"] == [
             %{"rank" => 2, "scenario_id" => "scenario-a"},
             %{"rank" => 3, "scenario_id" => "scenario-b"}
           ]
  end

  test "model disagreement ranks maximum range and reports decisive profile scores" do
    report = compile!()
    [first | _] = report["pools"]["model_disagreement"]

    assert first["candidate_id"] == "cand-c"
    assert first["decisive_axis"] == "axis-y"
    assert first["max_axis_range"] == 5
    assert first["mean_axis_range"] == 2.5
    assert first["profile_scores"] == %{"profile-a" => 5, "profile-b" => 0}
  end

  test "flagged contenders use the configured best-rank threshold" do
    report = compile!()

    assert Enum.map(report["pools"]["flagged_contenders"], & &1["candidate_id"]) ==
             ~w(cand-a cand-d)

    assert Enum.find(report["pools"]["flagged_contenders"], &(&1["candidate_id"] == "cand-d"))[
             "best_scenario_rank"
           ] == 2
  end

  test "resurrection pool keeps non-leaders with a top-K axis mean" do
    report = compile!()
    pool = report["pools"]["resurrection_pool"]

    assert Enum.map(pool, & &1["candidate_id"]) == ~w(cand-d cand-e)

    assert Enum.find(pool, &(&1["candidate_id"] == "cand-e"))["qualifying_axes"] == [
             %{"axis" => "axis-x", "mean" => 4.9, "rank" => 2}
           ]

    refute Enum.any?(pool, &(&1["candidate_id"] in ~w(cand-a cand-b)))
  end

  test "unknown scenario candidate references fail validation" do
    decision_views = decision_views()
    [scenario | rest] = decision_views["scenarios"]
    [row | rows] = scenario["ranked"]

    bad = %{
      decision_views
      | "scenarios" => [
          %{scenario | "ranked" => [%{row | "candidate_id" => "cand-unknown"} | rows]} | rest
        ]
    }

    assert {:error, errors} = IdentityReviewPools.compile(bad, assessments(), limits())
    assert Enum.any?(errors, &String.contains?(&1, "references unknown candidates: cand-unknown"))
  end

  test "assessment candidate coverage must match decision candidates" do
    incomplete = Enum.reject(assessments(), &(&1["candidate_id"] == "cand-f"))

    assert {:error, errors} = IdentityReviewPools.compile(decision_views(), incomplete, limits())
    assert Enum.any?(errors, &String.contains?(&1, "assessment candidate coverage mismatch"))
  end

  test "every candidate must have the same profile set" do
    incomplete =
      Enum.reject(assessments(), fn assessment ->
        assessment["candidate_id"] == "cand-f" and
          assessment["assessor"]["profile_id"] == "profile-b"
      end)

    assert {:error, errors} = IdentityReviewPools.compile(decision_views(), incomplete, limits())
    assert Enum.any?(errors, &String.contains?(&1, "profile set is not stable"))
  end

  defp compile! do
    IdentityReviewPools.compile!(decision_views(), assessments(), limits())
  end

  defp limits do
    [
      scenario_limit: 1,
      disagreement_limit: 6,
      flagged_rank_threshold: 2,
      resurrection_top_k: 2
    ]
  end

  defp decision_views do
    candidates = [
      candidate("cand-f", "Zeta", true, [], 0, 0),
      candidate("cand-c", "Gamma", true, [], 3, 3),
      candidate("cand-a", "Alpha", false, ["flag-a"], 5, 1),
      candidate("cand-e", "Epsilon", true, [], 4.9, 2),
      candidate("cand-b", "Beta", false, [], 1, 5),
      candidate("cand-d", "Delta", false, ["flag-d"], 2, 4.9)
    ]

    %{
      "schema_version" => 2,
      "score_aggregation" => "equal_assessment_mean",
      "selection_made" => false,
      "summary" => %{"candidate_entities" => 6},
      "candidates" => candidates,
      "scenarios" => [
        scenario("scenario-b", [
          {"cand-b", 6.0, true},
          {"cand-e", 5.0, false},
          {"cand-d", 4.0, true},
          {"cand-c", 3.0, false},
          {"cand-a", 2.0, false},
          {"cand-f", 1.0, false}
        ]),
        scenario("scenario-a", [
          {"cand-a", 6.0, true},
          {"cand-d", 5.0, true},
          {"cand-e", 4.0, false},
          {"cand-c", 3.0, false},
          {"cand-b", 2.0, false},
          {"cand-f", 1.0, false}
        ])
      ]
    }
  end

  defp candidate(id, display, wildcard, flags, axis_x, axis_y) do
    %{
      "candidate_id" => id,
      "display" => display,
      "axis_scores" => %{
        "axis-x" => %{"mean" => axis_x, "mean_confidence" => 0.01, "replicates" => 2},
        "axis-y" => %{"mean" => axis_y, "mean_confidence" => 0.99, "replicates" => 2}
      },
      "flags" => flags,
      "dissent" => [],
      "wildcard" => wildcard
    }
  end

  defp scenario(id, rows) do
    %{
      "id" => id,
      "label" => String.upcase(id),
      "ranked" =>
        Enum.map(rows, fn {candidate_id, score, pareto} ->
          %{
            "candidate_id" => candidate_id,
            "scenario_score" => score,
            "tier" => "A",
            "pareto" => pareto
          }
        end),
      "unranked" => []
    }
  end

  defp assessments do
    for candidate_id <- ~w(cand-f cand-c cand-a cand-e cand-b cand-d),
        profile <- ~w(profile-b profile-a) do
      %{
        "id" => "assessment-#{candidate_id}-#{profile}",
        "candidate_id" => candidate_id,
        "assessor" => %{"profile_id" => profile},
        "scores" => assessment_scores(candidate_id, profile)
      }
    end
  end

  defp assessment_scores("cand-c", "profile-a"), do: %{"axis-x" => 3, "axis-y" => 5}
  defp assessment_scores("cand-c", "profile-b"), do: %{"axis-x" => 3, "axis-y" => 0}
  defp assessment_scores("cand-a", "profile-a"), do: %{"axis-x" => 5, "axis-y" => 1}
  defp assessment_scores("cand-a", "profile-b"), do: %{"axis-x" => 1, "axis-y" => 1}
  defp assessment_scores("cand-b", "profile-a"), do: %{"axis-x" => 4, "axis-y" => 4}
  defp assessment_scores("cand-b", "profile-b"), do: %{"axis-x" => 2, "axis-y" => 2}
  defp assessment_scores(_candidate_id, "profile-a"), do: %{"axis-x" => 3, "axis-y" => 3}
  defp assessment_scores(_candidate_id, "profile-b"), do: %{"axis-x" => 2, "axis-y" => 2}
end

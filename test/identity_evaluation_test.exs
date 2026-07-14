defmodule Imp.IdentityEvaluationTest do
  use ExUnit.Case, async: true

  alias Imp.IdentityEvaluation

  test "scenario scoring and Pareto views preserve flags and dissent outside scores" do
    registry = [observation("cand-a", "Alpha"), observation("cand-b", "Beta")]

    assessments =
      for replicate <- 1..3,
          {candidate_id, truth, fit} <- [{"cand-a", 5, 4}, {"cand-b", 3, 5}] do
        %{
          "id" => "assessment-#{candidate_id}-#{replicate}",
          "candidate_id" => candidate_id,
          "confidence" => 1.0,
          "scores" => %{"semantic-truth" => truth, "current-product-fit" => fit},
          "context" => %{}
        }
      end

    flags = [%{"id" => "flag-a", "candidate_id" => "cand-a"}]
    dissent = [%{"id" => "dissent-b", "candidate_id" => "cand-b"}]

    atlas = %{
      "atlas_version" => 1,
      "assessment_axes" => [
        %{"id" => "semantic-truth"},
        %{"id" => "current-product-fit"}
      ],
      "audiences" => [],
      "brand_architectures" => [],
      "coverage_requirements" => %{"required_assessment_replicates_for_ranked_views" => 3}
    }

    scenarios = %{
      "schema_version" => 1,
      "tier_thresholds" => [
        %{"tier" => "A", "minimum" => 4.0},
        %{"tier" => "B", "minimum" => 0.0}
      ],
      "scenarios" => [
        %{
          "id" => "test-scenario",
          "label" => "Test scenario",
          "weights" => %{"semantic-truth" => 0.5, "current-product-fit" => 0.5}
        }
      ]
    }

    assert {:ok, report} =
             IdentityEvaluation.compile(registry, assessments, flags, dissent, atlas, scenarios)

    assert report["schema_version"] == 2
    [view] = report["scenarios"]
    assert view["ranked_candidate_count"] == 2
    assert view["pareto_candidate_count"] == 2

    alpha = Enum.find(view["ranked"], &(&1["candidate_id"] == "cand-a"))
    alpha_candidate = Enum.find(report["candidates"], &(&1["candidate_id"] == "cand-a"))
    beta_candidate = Enum.find(report["candidates"], &(&1["candidate_id"] == "cand-b"))

    assert alpha["scenario_score"] == 4.5
    assert alpha_candidate["flags"] == ["flag-a"]
    assert beta_candidate["dissent"] == ["dissent-b"]
    assert get_in(alpha_candidate, ["axis_scores", "semantic-truth", "replicates"]) == 3
    assert Map.keys(alpha) |> Enum.sort() == ~w(candidate_id pareto scenario_score tier)
  end

  test "a candidate remains visible but unranked until replicate coverage is complete" do
    registry = [observation("cand-a", "Alpha")]

    assessment = %{
      "id" => "assessment-one",
      "candidate_id" => "cand-a",
      "confidence" => 1.0,
      "scores" => %{"semantic-truth" => 5},
      "context" => %{}
    }

    atlas = %{
      "atlas_version" => 1,
      "assessment_axes" => [%{"id" => "semantic-truth"}],
      "audiences" => [],
      "brand_architectures" => [],
      "coverage_requirements" => %{"required_assessment_replicates_for_ranked_views" => 3}
    }

    scenarios = %{
      "schema_version" => 1,
      "tier_thresholds" => [%{"tier" => "A", "minimum" => 0.0}],
      "scenarios" => [
        %{"id" => "test", "label" => "Test", "weights" => %{"semantic-truth" => 1.0}}
      ]
    }

    assert {:ok, report} =
             IdentityEvaluation.compile(registry, [assessment], [], [], atlas, scenarios)

    [view] = report["scenarios"]
    assert view["ranked"] == []
    assert [%{"candidate_id" => "cand-a"}] = view["unranked"]
  end

  test "a missing axis cannot accidentally satisfy ranking coverage" do
    registry = [observation("cand-a", "Alpha")]

    assessments =
      for replicate <- 1..3 do
        %{
          "id" => "assessment-missing-#{replicate}",
          "candidate_id" => "cand-a",
          "confidence" => 1.0,
          "scores" => %{"semantic-truth" => 5},
          "context" => %{}
        }
      end

    atlas = %{
      "atlas_version" => 1,
      "assessment_axes" => [
        %{"id" => "semantic-truth"},
        %{"id" => "current-product-fit"}
      ],
      "audiences" => [],
      "brand_architectures" => [],
      "coverage_requirements" => %{"required_assessment_replicates_for_ranked_views" => 3}
    }

    scenarios = %{
      "schema_version" => 1,
      "tier_thresholds" => [%{"tier" => "A", "minimum" => 0.0}],
      "scenarios" => [
        %{
          "id" => "test",
          "label" => "Test",
          "weights" => %{"semantic-truth" => 0.5, "current-product-fit" => 0.5}
        }
      ]
    }

    assert {:ok, report} =
             IdentityEvaluation.compile(registry, assessments, [], [], atlas, scenarios)

    [view] = report["scenarios"]
    assert view["ranked"] == []

    assert [%{"missing_or_under_replicated_axes" => ["current-product-fit"]}] =
             view["unranked"]
  end

  test "uncalibrated model confidence does not reweight assessment scores" do
    registry = [observation("cand-a", "Alpha")]

    assessments =
      [{0, 1.0}, {5, 0.1}, {5, 0.1}]
      |> Enum.with_index(1)
      |> Enum.map(fn {{score, confidence}, replicate} ->
        %{
          "id" => "assessment-confidence-#{replicate}",
          "candidate_id" => "cand-a",
          "confidence" => confidence,
          "scores" => %{"semantic-truth" => score},
          "context" => %{}
        }
      end)

    atlas = %{
      "atlas_version" => 1,
      "assessment_axes" => [%{"id" => "semantic-truth"}],
      "audiences" => [],
      "brand_architectures" => [],
      "coverage_requirements" => %{"required_assessment_replicates_for_ranked_views" => 3}
    }

    scenarios = %{
      "schema_version" => 1,
      "tier_thresholds" => [%{"tier" => "A", "minimum" => 0.0}],
      "scenarios" => [
        %{"id" => "test", "label" => "Test", "weights" => %{"semantic-truth" => 1.0}}
      ]
    }

    assert {:ok, report} =
             IdentityEvaluation.compile(registry, assessments, [], [], atlas, scenarios)

    [candidate] = report["candidates"]
    axis = candidate["axis_scores"]["semantic-truth"]

    assert report["score_aggregation"] == "equal_assessment_mean"
    assert_in_delta axis["mean"], 10 / 3, 1.0e-12
    assert_in_delta axis["mean_confidence"], 0.4, 1.0e-12
  end

  defp observation(candidate_id, surface) do
    %{
      "event_type" => "candidate_observed",
      "candidate_id" => candidate_id,
      "occurrence_id" => "occ-#{candidate_id}",
      "run_id" => "run-test",
      "surface" => surface,
      "normalized" => String.downcase(surface),
      "candidate" => %{
        "territories" => ["declaration-contract"],
        "strategies" => ["ordinary-object"],
        "wildcard" => false
      }
    }
  end
end

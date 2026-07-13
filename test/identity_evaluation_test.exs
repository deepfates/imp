defmodule DSEx.IdentityEvaluationTest do
  use ExUnit.Case, async: true

  alias DSEx.IdentityEvaluation

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

    [view] = report["scenarios"]
    assert view["ranked_candidate_count"] == 2
    assert view["pareto_candidate_count"] == 2

    alpha = Enum.find(view["ranked"], &(&1["candidate_id"] == "cand-a"))
    beta = Enum.find(view["ranked"], &(&1["candidate_id"] == "cand-b"))

    assert alpha["scenario_score"] == 4.5
    assert alpha["flags"] == ["flag-a"]
    assert beta["dissent"] == ["dissent-b"]
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

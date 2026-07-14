defmodule Imp.IdentityReliabilityTest do
  use ExUnit.Case, async: true

  alias Imp.IdentityReliability

  test "reports perfect rank, absolute, and consistency agreement" do
    report =
      IdentityReliability.compile!(assessments(fn score, _profile -> score end), scenarios())

    [axis] = report["axes"]

    assert axis["icc"]["absolute_agreement_single"] == 1.0
    assert axis["icc"]["absolute_agreement_mean"] == 1.0
    assert axis["icc"]["consistency_single"] == 1.0
    assert axis["icc"]["consistency_mean"] == 1.0

    assert Enum.all?(axis["pairwise"], fn pair ->
             pair["spearman_rank_correlation"] == 1.0 and
               pair["mean_absolute_error"] == 0.0
           end)
  end

  test "separates rank consistency from absolute score agreement" do
    shifts = %{"a" => 0, "b" => 1, "c" => -1}
    report = IdentityReliability.compile!(assessments(&(&1 + shifts[&2])), scenarios())
    [axis] = report["axes"]

    assert_in_delta axis["icc"]["consistency_single"], 1.0, 1.0e-12
    assert_in_delta axis["icc"]["consistency_mean"], 1.0, 1.0e-12
    assert_in_delta axis["icc"]["absolute_agreement_single"], 0.625, 1.0e-12
    assert_in_delta axis["icc"]["absolute_agreement_mean"], 5 / 6, 1.0e-12
    assert Enum.all?(axis["pairwise"], &(&1["spearman_rank_correlation"] == 1.0))
  end

  test "reports disagreement for inverted rankings and scenario projections" do
    report =
      IdentityReliability.compile!(
        assessments(fn score, profile -> if profile == "c", do: 4 - score, else: score end),
        scenarios()
      )

    [axis] = report["axes"]
    [scenario] = report["scenarios"]
    inverted = Enum.find(axis["pairwise"], &(&1["right_profile_id"] == "c"))

    assert inverted["spearman_rank_correlation"] == -1.0
    assert scenario["id"] == "balanced"
    assert scenario["pairwise"] != []
  end

  test "rejects duplicate and incomplete candidate profile matrices" do
    records = assessments(fn score, _profile -> score end)

    assert_raise ArgumentError, ~r/duplicate candidate\/profile/, fn ->
      IdentityReliability.compile!([hd(records) | records], scenarios())
    end

    assert_raise ArgumentError, ~r/incomplete candidate\/profile/, fn ->
      IdentityReliability.compile!(tl(records), scenarios())
    end
  end

  defp assessments(transform) do
    for candidate <- 1..4, profile <- ~w(a b c) do
      score = transform.(candidate, profile)

      %{
        "id" => "assessment-#{candidate}-#{profile}",
        "candidate_id" => "cand-#{candidate}",
        "assessor" => %{"profile_id" => profile},
        "scores" => %{"truth" => score}
      }
    end
  end

  defp scenarios do
    %{
      "scenarios" => [
        %{"id" => "balanced", "label" => "Balanced", "weights" => %{"truth" => 1.0}}
      ]
    }
  end
end

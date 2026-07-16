defmodule Imp.ReleaseProfileTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.ReleaseProfile

  test "canonical profiles are cumulative and v0.1 is the product default" do
    assert ReleaseProfile.default() == "v0.1"
    assert ReleaseProfile.names() == ["research", "telos", "v0.1"]
    assert ReleaseProfile.fetch!("v0.1")["claim_releases"] == ["v0.1"]
    assert ReleaseProfile.fetch!("telos")["claim_releases"] == ["v0.1", "telos"]

    assert ReleaseProfile.fetch!("research")["claim_releases"] == [
             "v0.1",
             "telos",
             "research"
           ]
  end

  test "lane evidence requirements are derived from selected claims" do
    claims = [
      %{
        "id" => "v01",
        "release" => "v0.1",
        "gate_policy" => "blocking",
        "requirements" => [
          %{"id" => "failure.t0", "lane" => "failure_recovery", "evidence" => "passing"}
        ]
      },
      %{
        "id" => "telos",
        "release" => "telos",
        "gate_policy" => "blocking",
        "requirements" => [
          %{"id" => "failure.live", "lane" => "failure_recovery", "evidence" => "full"}
        ]
      }
    ]

    assert [%{"evidence" => "passing"}] =
             ReleaseProfile.lane_requirements(claims, ReleaseProfile.fetch!("v0.1"))

    assert [requirement] =
             ReleaseProfile.lane_requirements(claims, ReleaseProfile.fetch!("telos"))

    assert requirement["evidence"] == "full"
    assert requirement["claim_ids"] == ["v01", "telos"]
    assert requirement["requirement_ids"] == ["failure.t0", "failure.live"]
  end

  test "non-blocking claims remain visible but do not create profile requirements" do
    claims = [
      %{
        "id" => "informational",
        "release" => "v0.1",
        "gate_policy" => "informational",
        "requirements" => [
          %{"id" => "research.sample", "lane" => "research", "evidence" => "passing"}
        ]
      }
    ]

    assert ReleaseProfile.lane_requirements(claims, ReleaseProfile.fetch!("v0.1")) == []
  end
end

defmodule DSEx.IdentityCheckpointTest do
  use ExUnit.Case, async: true

  alias DSEx.IdentityCheckpoint

  @atlas_path Path.expand("../identity/atlas.json", __DIR__)

  test "normalization and candidate IDs are stable across display punctuation" do
    assert IdentityCheckpoint.normalize_surface("  Form-Lab! ") == "formlab"

    assert IdentityCheckpoint.candidate_id("Form Lab") ==
             IdentityCheckpoint.candidate_id("form-lab")
  end

  test "compile preserves duplicate observations with one canonical candidate id" do
    atlas = IdentityCheckpoint.load_atlas!(@atlas_path)

    portfolio =
      portfolio_entry("run-duplicate-proof", [
        candidate(1, "Form Lab"),
        candidate(2, "form-lab")
      ])

    assert {:ok, %{events: events, report: report}} =
             IdentityCheckpoint.compile(atlas, [portfolio])

    observations = Enum.filter(events, &(&1["event_type"] == "candidate_observed"))

    assert length(observations) == 2
    assert observations |> Enum.map(& &1["occurrence_id"]) |> Enum.uniq() |> length() == 2
    assert observations |> Enum.map(& &1["candidate_id"]) |> Enum.uniq() |> length() == 1
    assert report["summary"]["raw_occurrences"] == 2
    assert report["summary"]["distinct_normalized_candidates"] == 1
    assert report["summary"]["duplicate_occurrences"] == 1
  end

  test "compile rejects an atlas reference that was never declared" do
    atlas = IdentityCheckpoint.load_atlas!(@atlas_path)

    portfolio =
      portfolio_entry("run-bad-territory", [
        candidate(1, "Unmapped") |> Map.put("territories", ["missing-territory"])
      ])

    assert {:error, errors} = IdentityCheckpoint.compile(atlas, [portfolio])
    assert Enum.any?(errors, &String.contains?(&1, "missing-territory"))
  end

  test "registry rendering retains every event as JSONL" do
    events = [%{"event_type" => "generation_run", "event_id" => "event-a"}]
    body = IdentityCheckpoint.render_registry(events)

    assert String.ends_with?(body, "\n")
    assert [line] = String.split(body, "\n", trim: true)
    assert Jason.decode!(line) == hd(events)
  end

  defp portfolio_entry(run_id, candidates) do
    data = %{
      "schema_version" => 1,
      "run" => %{
        "id" => run_id,
        "generated_at" => "2026-07-13T18:00:00Z",
        "generator" => %{"kind" => "agent", "name" => "test generator"},
        "method" => "contract test",
        "brief" => "Exercise the lossless registry contract.",
        "atlas_version" => 1,
        "intended_territories" => ["declaration-contract"],
        "intended_strategies" => ["ordinary-object"],
        "intended_audiences" => ["beam-developers"]
      },
      "candidates" => candidates
    }

    body = Jason.encode!(data)

    %{
      path: "identity/inbox/#{run_id}.json",
      sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
      data: data
    }
  end

  defp candidate(ordinal, surface) do
    %{
      "ordinal" => ordinal,
      "surface" => surface,
      "rationale" => "A deliberately repeated candidate.",
      "territories" => ["declaration-contract"],
      "strategies" => ["ordinary-object"],
      "audience_lenses" => ["beam-developers"],
      "architecture_lenses" => ["beam-master"],
      "wildcard" => false
    }
  end
end

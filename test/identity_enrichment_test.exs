defmodule DSEx.IdentityEnrichmentTest do
  use ExUnit.Case, async: true

  alias DSEx.IdentityEnrichment

  test "derives conventional Elixir identity surfaces without interning atoms" do
    assert %{
             "hex_package" => "form_lab",
             "otp_app" => "form_lab",
             "module_root" => "FormLab",
             "mix_task_prefix" => "form_lab",
             "config_prefix" => "form_lab",
             "telemetry_prefix" => "[:form_lab]",
             "code_concerns" => []
           } = IdentityEnrichment.code_forms("Form Lab")
  end

  test "keeps symbolic candidates visible with explicit code limitations" do
    forms = IdentityEnrichment.code_forms("->")

    assert forms["hex_package"] == nil
    assert forms["module_root"] == nil
    assert Enum.any?(forms["code_concerns"], &String.contains?(&1, "No ASCII"))
  end

  test "emits exactly one baseline enrichment for each normalized candidate entity" do
    registry = [
      observation("cand-a", "Form Lab", "occ-a"),
      observation("cand-a", "form-lab", "occ-b"),
      observation("cand-b", "->", "occ-c")
    ]

    atlas = %{
      "brand_architectures" => [
        %{"id" => "beam-master", "label" => "BEAM master"},
        %{"id" => "neutral-master-beam-implementation", "label" => "Neutral master"}
      ]
    }

    enrichments =
      IdentityEnrichment.baseline(registry, atlas, generated_at: "2026-07-13T20:00:00Z")

    assert length(enrichments) == 2

    form_lab = Enum.find(enrichments, &(&1["candidate_id"] == "cand-a"))
    assert form_lab["evidence_refs"] == ["occ-a", "occ-b"]
    assert form_lab["code_forms"]["module_root"] == "FormLab"

    assert [
             %{"architecture_id" => "beam-master"},
             %{"architecture_id" => "neutral-master-beam-implementation"}
           ] =
             form_lab["architecture_forms"]
  end

  defp observation(candidate_id, surface, occurrence_id) do
    %{
      "event_type" => "candidate_observed",
      "candidate_id" => candidate_id,
      "occurrence_id" => occurrence_id,
      "run_id" => "run-test",
      "surface" => surface,
      "normalized" => String.downcase(surface),
      "candidate" => %{
        "territories" => ["declaration-contract"],
        "strategies" => ["ordinary-object"],
        "architecture_lenses" => [
          "beam-master",
          "neutral-master-beam-implementation"
        ],
        "wildcard" => false
      }
    }
  end
end

defmodule Imp.IdentityInternationalScreenTest do
  use ExUnit.Case, async: true

  alias Imp.IdentityInternationalScreen

  test "records deterministic signals without claiming international validation" do
    observations = [observation("occ-a", "Form Lab", "form lab")]

    screen =
      IdentityInternationalScreen.build(
        entity("Form Lab", ["ordinary-object"]),
        observations,
        code_forms("form_lab")
      )

    assert screen["basis"] == "algorithmic-screen"
    assert screen["evidence_refs"] == ["occ-a"]
    assert screen["limitations"] |> Enum.all?(&String.contains?(&1, "No "))

    assert Enum.map(screen["checks"], & &1["id"]) ==
             IdentityInternationalScreen.check_ids()

    assert check(screen, "unicode")["status"] == "no-machine-signal"
    assert check(screen, "script")["signals"] == ["script:Latin"]
    assert check(screen, "transliteration")["status"] == "unverified"
    assert "uts39-confusable-skeleton-not-run" in check(screen, "transliteration")["signals"]
    assert check(screen, "speech-accessibility")["status"] == "unverified"
    assert check(screen, "cultural-provenance")["status"] == "unverified"
    assert IdentityInternationalScreen.current?(screen, observations)
  end

  test "surfaces source-language, pronunciation, normalization, and projection concerns" do
    surface = "Ecoute" <> <<0xCC, 0x81>>
    observations = [observation("occ-a", surface, nil)]

    screen =
      IdentityInternationalScreen.build(
        entity(surface, ["archaic-cross-language"]),
        observations,
        code_forms("ecoute"),
        ["cand-other"]
      )

    assert "nfc-changed" in check(screen, "unicode")["signals"]
    assert "combining-mark-present" in check(screen, "unicode")["signals"]
    assert check(screen, "transliteration")["status"] == "attention"

    assert "source-romanization-unverified" in check(screen, "transliteration")["signals"]

    assert "ascii-code-projection-shared-with:cand-other" in check(screen, "transliteration")[
             "signals"
           ]

    assert check(screen, "speech-accessibility")["status"] == "attention"
    assert "pronunciation-missing" in check(screen, "speech-accessibility")["signals"]
    assert check(screen, "cultural-provenance")["status"] == "attention"
  end

  test "detects mixed Latin and Cyrillic scripts" do
    surface = "A" <> <<0xD0, 0x90>>
    observations = [observation("occ-a", surface, "two letters")]

    screen =
      IdentityInternationalScreen.build(
        entity(surface, ["abstract-sound-brand"]),
        observations,
        code_forms("a")
      )

    script = check(screen, "script")
    assert script["status"] == "attention"
    assert "script:Latin" in script["signals"]
    assert "script:Cyrillic" in script["signals"]
    assert "mixed-scripts" in script["signals"]
  end

  test "evidence digests are order-independent and change with evidence" do
    first = observation("occ-a", "Form Lab", "form lab")
    second = observation("occ-b", "form-lab", "form dash lab")

    assert IdentityInternationalScreen.evidence_digest([first, second]) ==
             IdentityInternationalScreen.evidence_digest([second, first])

    refute IdentityInternationalScreen.evidence_digest([first]) ==
             IdentityInternationalScreen.evidence_digest([second])
  end

  defp check(screen, id), do: Enum.find(screen["checks"], &(&1["id"] == id))

  defp entity(surface, strategies) do
    %{
      "candidate_id" => "cand-test",
      "display" => surface,
      "surfaces" => [surface],
      "strategies" => strategies
    }
  end

  defp observation(occurrence_id, surface, pronunciation) do
    %{
      "event_id" => "event-#{occurrence_id}",
      "event_type" => "candidate_observed",
      "candidate_id" => "cand-test",
      "occurrence_id" => occurrence_id,
      "surface" => surface,
      "candidate" => %{
        "pronunciation" => pronunciation,
        "strategies" => ["ordinary-object"]
      }
    }
  end

  defp code_forms(slug) do
    %{
      "hex_package" => slug,
      "otp_app" => slug,
      "module_root" => "FormLab",
      "mix_task_prefix" => slug,
      "config_prefix" => slug,
      "telemetry_prefix" => "[:#{slug}]"
    }
  end
end

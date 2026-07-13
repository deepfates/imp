defmodule DSEx.EvidenceAuthoritiesTest do
  use ExUnit.Case, async: true

  alias DSEx.EvidenceAuthorities

  test "checked-in authority documentation is generated from the validated ledger" do
    ledger = EvidenceAuthorities.load!()
    current = File.read!("docs/EVIDENCE_AUTHORITIES.md")

    assert current ==
             EvidenceAuthorities.replace_summary!(
               current,
               EvidenceAuthorities.render_family_summary(ledger)
             )
  end

  test "present upstream tests require immutable path-bound hashes" do
    ledger = EvidenceAuthorities.load!()

    drifted =
      update_in(ledger, ["families", Access.at(1), "upstream_tests", "references"], fn _ ->
        ["tests/signatures/test_signature.py"]
      end)

    assert_raise ArgumentError, ~r/path-bound SHA-256/, fn ->
      EvidenceAuthorities.validate!(drifted)
    end
  end

  test "pinned dataset protocols require concrete source references and digests" do
    ledger = EvidenceAuthorities.load!()

    drifted =
      put_in(
        ledger,
        ["families", Access.at(3), "dataset_protocol", "immutable_digests"],
        ["the digest is documented elsewhere"]
      )

    assert_raise ArgumentError, ~r/invalid pinned dataset protocol/, fn ->
      EvidenceAuthorities.validate!(drifted)
    end
  end
end

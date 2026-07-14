defmodule Imp.EvidenceAuthoritiesTest do
  use ExUnit.Case, async: true

  alias Imp.EvidenceAuthorities

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

  test "every pinned repository has a complete immutable source manifest" do
    ledger = EvidenceAuthorities.load!()

    pinned =
      Enum.filter(ledger["families"], fn family ->
        family["upstream_repository"]["status"] in ["release_and_commit_pinned", "commit_pinned"]
      end)

    assert pinned != []

    assert Enum.all?(pinned, fn family ->
             reference = family["upstream_repository"]["source_manifest"]
             reference["file_count"] > 0 and byte_size(reference["sha256"]) == 64
           end)
  end

  test "source manifest byte tampering fails closed" do
    root =
      Path.join(System.tmp_dir!(), "authority-manifest-#{System.unique_integer([:positive])}")

    source_root = Path.join(root, "benchmarks")
    File.mkdir_p!(Path.join(source_root, "authority_sources"))

    ledger = EvidenceAuthorities.load!()
    family = Enum.find(ledger["families"], &(&1["id"] == "family.rlm"))
    reference = family["upstream_repository"]["source_manifest"]
    source = File.read!(reference["path"])
    File.write!(Path.join(root, reference["path"]), source <> " ")

    File.write!(
      Path.join(source_root, "authorities.json"),
      Jason.encode!(%{ledger | "families" => [family]})
    )

    assert_raise ArgumentError, ~r/source manifest digest mismatch/, fn ->
      EvidenceAuthorities.load!(Path.join(source_root, "authorities.json"))
    end
  end

  test "re-digested manifests cannot omit a declared source path" do
    root =
      Path.join(System.tmp_dir!(), "authority-coverage-#{System.unique_integer([:positive])}")

    source_root = Path.join(root, "benchmarks")
    File.mkdir_p!(Path.join(source_root, "authority_sources"))

    ledger = EvidenceAuthorities.load!()
    family = Enum.find(ledger["families"], &(&1["id"] == "family.tools_agents_react"))
    reference = family["upstream_repository"]["source_manifest"]

    manifest =
      reference["path"]
      |> File.read!()
      |> Jason.decode!()
      |> update_in(
        ["files"],
        &Enum.reject(&1, fn file -> file["path"] == "dspy/predict/react_v2.py" end)
      )

    bytes = Jason.encode!(manifest)

    changed_reference = %{
      reference
      | "file_count" => length(manifest["files"]),
        "sha256" => sha256(bytes)
    }

    changed_family = put_in(family, ["upstream_repository", "source_manifest"], changed_reference)
    File.write!(Path.join(root, reference["path"]), bytes)

    File.write!(
      Path.join(source_root, "authorities.json"),
      Jason.encode!(%{ledger | "families" => [changed_family]})
    )

    assert_raise ArgumentError, ~r/source manifest coverage mismatch/, fn ->
      EvidenceAuthorities.load!(Path.join(source_root, "authorities.json"))
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

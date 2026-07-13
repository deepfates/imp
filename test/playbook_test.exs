defmodule DSEx.PlaybookTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DSEx.Playbook
  alias DSEx.Playbook.{Delta, Entry, Policy, Provenance}
  alias DSEx.Playbook.Operation.{Add, Merge, Remove, Revise, UpdateCounters}

  test "add and revise retain identity and form both hash chains" do
    root = Playbook.new(id: "pb_test")

    assert {:ok, added} =
             Playbook.apply_delta(root, [Add.new("  Keep evidence.  ", id: "evidence")])

    assert added.revision == 1
    assert added.parent_hash == root.hash

    assert {:ok, revised} =
             Playbook.apply_delta(
               added,
               Delta.new([Revise.new("evidence", "Keep primary evidence.", expected_revision: 1)],
                 expected_revision: 1,
                 parent_hash: added.hash
               )
             )

    assert {:ok, entry} = Playbook.fetch(revised, "evidence")
    assert entry.revision == 2
    assert entry.parent_hash == hd(added.entries).hash
    assert entry.id == "evidence"
  end

  test "revise replaces explicit semantic fields, preserves counters, and updates the hash" do
    provenance = Provenance.new(source_ids: ["dataset:v1"], digests: [String.duplicate("a", 64)])

    assert {:ok, initial} =
             Playbook.apply_delta(Playbook.new(), [
               Add.new("instruction",
                 id: "entry",
                 section: "Rules",
                 helpful: 2,
                 harmful: 1,
                 provenance: provenance
               )
             ])

    before = hd(initial.entries)

    assert {:ok, revised} =
             Playbook.apply_delta(initial, [
               Revise.new("entry", "instruction",
                 section: "Archived",
                 status: :inactive,
                 expected_revision: 1
               )
             ])

    after_entry = hd(revised.entries)
    assert {after_entry.helpful, after_entry.harmful} == {2, 1}
    assert after_entry.provenance == provenance
    assert after_entry.status == :inactive
    assert after_entry.section == "Archived"
    assert after_entry.parent_hash == before.hash
    refute after_entry.hash == before.hash
    assert Playbook.render(revised) == ""
  end

  test "a failing operation leaves the whole delta unapplied" do
    root = Playbook.new(id: "atomic")

    assert {:error, {:operation_failed, 1, {:entry_not_found, "missing"}}} =
             Playbook.apply_delta(root, [Add.new("valid"), Remove.new("missing")])

    assert root.entries == []
    assert root.revision == 0
    assert root.hash == Playbook.new(id: "atomic").hash
  end

  test "deduplication is exact after deterministic normalization" do
    assert {:ok, playbook} =
             Playbook.apply_delta(Playbook.new(), [Add.new("Cafe\u0301  \r\n")])

    assert {:error, {:operation_failed, 0, {:duplicate_content, _id}}} =
             Playbook.apply_delta(playbook, [Add.new("Caf\u00e9")])

    assert {:ok, distinct} = Playbook.apply_delta(playbook, [Add.new("caf\u00e9")])
    assert length(distinct.entries) == 2
  end

  test "merge and remove preserve complete typed tombstones" do
    assert {:ok, initial} =
             Playbook.apply_delta(Playbook.new(), [
               Add.new("one", id: "one"),
               Add.new("two", id: "two"),
               Add.new("three", id: "three")
             ])

    assert {:ok, merged} =
             Playbook.apply_delta(initial, [
               Merge.new(["one", "two"], "one plus two", id: "combined")
             ])

    assert Enum.map(merged.entries, & &1.id) == ["combined", "three"]

    assert Enum.map(merged.tombstones, &{&1.entry.id, &1.operation, &1.replacement_id}) == [
             {"one", :merge, "combined"},
             {"two", :merge, "combined"}
           ]

    assert {:ok, removed} = Playbook.apply_delta(merged, [Remove.new("combined")])
    assert List.last(removed.tombstones).entry.hash == hd(merged.entries).hash
    assert List.last(removed.tombstones).operation == :remove
  end

  test "secret-shaped content is rejected by redaction unless explicitly disabled" do
    secret = "Bearer abcdefghijklmnop"

    assert {:error, {:operation_failed, 0, :secret_content}} =
             Playbook.apply_delta(Playbook.new(), [Add.new(secret)])

    permissive = Playbook.new(policy: Policy.new(reject_secrets: false))
    assert {:ok, _} = Playbook.apply_delta(permissive, [Add.new(secret)])
  end

  test "status, counters, sections, and provenance reject adversarial values" do
    root = Playbook.new(policy: Policy.new(max_section_bytes: 4, max_counter: 5))

    assert {:error, {:operation_failed, 0, {:invalid_status, :deleted}}} =
             Playbook.apply_delta(root, [Add.new("x", section: "ok", status: :deleted)])

    assert {:error, {:operation_failed, 0, {:invalid_counter, -1, 5}}} =
             Playbook.apply_delta(root, [Add.new("x", section: "ok", helpful: -1)])

    assert {:error, {:operation_failed, 0, {:section_too_large, 5}}} =
             Playbook.apply_delta(root, [Add.new("x", section: "Rules")])

    assert {:error, {:operation_failed, 0, :invalid_provenance}} =
             Playbook.apply_delta(root, [
               Add.new("x", section: "ok", provenance: %{trace: "raw reasoning"})
             ])

    malformed = %Provenance{source_ids: "raw trace", digests: []}

    assert {:error, {:operation_failed, 0, :invalid_provenance}} =
             Playbook.apply_delta(root, [
               Add.new("x", section: "ok", provenance: malformed)
             ])

    raw = Provenance.new(source_ids: ["chain of thought"])

    assert {:error, {:operation_failed, 0, {:invalid_source_id, "chain of thought"}}} =
             Playbook.apply_delta(root, [Add.new("x", section: "ok", provenance: raw)])

    secret = Provenance.new(source_ids: ["sk-abcdefgh"])

    assert {:error, {:operation_failed, 0, {:invalid_source_id, "sk-abcdefgh"}}} =
             Playbook.apply_delta(root, [Add.new("x", section: "ok", provenance: secret)])

    invalid_digest = Provenance.new(digests: ["not-a-digest"])

    assert {:error, {:operation_failed, 0, {:invalid_digest, "not-a-digest"}}} =
             Playbook.apply_delta(root, [Add.new("x", section: "ok", provenance: invalid_digest)])
  end

  test "counter updates are atomic, revisioned, and protected by the policy maximum" do
    root = Playbook.new(policy: Policy.new(max_counter: 5))
    assert {:ok, initial} = Playbook.apply_delta(root, [Add.new("x", id: "x", helpful: 4)])

    assert {:ok, updated} =
             Playbook.apply_delta(initial, [
               UpdateCounters.new("x", harmful: 2, expected_revision: 1)
             ])

    entry = hd(updated.entries)
    assert {entry.helpful, entry.harmful, entry.revision} == {4, 2, 2}
    assert entry.parent_hash == hd(initial.entries).hash

    assert {:error, {:operation_failed, 0, {:counter_overflow, 5}}} =
             Playbook.apply_delta(updated, [UpdateCounters.new("x", helpful: 2)])

    assert hd(updated.entries).helpful == 4

    assert {:error, {:operation_failed, 0, {:invalid_counter, -1, 5}}} =
             Playbook.apply_delta(updated, [UpdateCounters.new("x", harmful: -1)])
  end

  test "merge aggregates counters and closes provenance over every source" do
    digest_a = String.duplicate("a", 64)
    digest_b = String.duplicate("b", 64)

    assert {:ok, initial} =
             Playbook.apply_delta(Playbook.new(), [
               Add.new("one",
                 id: "one",
                 helpful: 2,
                 harmful: 1,
                 provenance: Provenance.new(source_ids: ["source:a"], digests: [digest_a])
               ),
               Add.new("two",
                 id: "two",
                 helpful: 3,
                 harmful: 4,
                 provenance: Provenance.new(source_ids: ["source:b"], digests: [digest_b])
               )
             ])

    source_hashes = Enum.map(initial.entries, & &1.hash)

    assert {:ok, merged} =
             Playbook.apply_delta(initial, [
               Merge.new(["one", "two"], "combined", id: "combined", section: "Merged")
             ])

    entry = hd(merged.entries)
    assert {entry.helpful, entry.harmful} == {5, 5}
    assert entry.provenance.source_ids == ["one", "source:a", "source:b", "two"]
    assert entry.provenance.digests == Enum.sort([digest_a, digest_b | source_hashes])

    overflow_root = Playbook.new(policy: Policy.new(max_counter: 5))

    assert {:ok, overflowing} =
             Playbook.apply_delta(overflow_root, [
               Add.new("a", id: "a", helpful: 3),
               Add.new("b", id: "b", helpful: 3)
             ])

    assert {:error, {:operation_failed, 0, {:counter_overflow, 5}}} =
             Playbook.apply_delta(overflowing, [Merge.new(["a", "b"], "ab")])
  end

  test "entry, playbook, and operation limits are enforced at commit" do
    policy =
      Policy.new(max_entries: 2, max_entry_bytes: 4, max_playbook_bytes: 20, max_operations: 2)

    root = Playbook.new(policy: policy)

    assert {:error, {:too_many_operations, 3}} =
             Playbook.apply_delta(root, [Add.new("a"), Add.new("b"), Add.new("c")])

    assert {:error, {:operation_failed, 0, {:entry_too_large, 5}}} =
             Playbook.apply_delta(root, [Add.new("abcde")])

    assert {:ok, full} = Playbook.apply_delta(root, [Add.new("abc"), Add.new("def")])
    assert {:error, {:too_many_entries, 3}} = Playbook.apply_delta(full, [Add.new("g")])
  end

  test "tombstones remain inside count and total retained-content bounds" do
    count_policy =
      Policy.new(max_entries: 2, max_tombstones: 1, max_operations: 2)

    assert {:ok, populated} =
             Playbook.apply_delta(Playbook.new(policy: count_policy), [
               Add.new("a", id: "a"),
               Add.new("b", id: "b")
             ])

    assert {:error, {:too_many_tombstones, 2}} =
             Playbook.apply_delta(populated, [Remove.new("a"), Remove.new("b")])

    assert Enum.map(populated.entries, & &1.id) == ["a", "b"]
    assert populated.tombstones == []

    byte_policy = Policy.new(max_playbook_bytes: 10)

    assert {:ok, added} =
             Playbook.apply_delta(Playbook.new(policy: byte_policy), [Add.new("abc")])

    assert {:ok, removed} = Playbook.apply_delta(added, [Remove.new(hd(added.entries).id)])

    assert {:error, {:playbook_too_large, 18}} =
             Playbook.apply_delta(removed, [Add.new("d")])
  end

  test "canonical serialization and rendering are deterministic" do
    delta = [Add.new("first", id: "a"), Add.new("second", id: "b")]
    assert {:ok, left} = Playbook.apply_delta(Playbook.new(id: "same"), delta)
    assert {:ok, right} = Playbook.apply_delta(Playbook.new(id: "same"), delta)

    assert left == right
    assert Playbook.serialize(left) == Playbook.serialize(right)
    assert Jason.decode!(Playbook.serialize(left)) == Playbook.dump(left)

    assert Playbook.render(left) ==
             "# general\n\n## a (revision 1)\n\nfirst\n\n## b (revision 1)\n\nsecond"
  end

  test "all semantic fields affect hashes deterministically without leaking provenance in render" do
    digest = String.duplicate("c", 64)
    provenance = Provenance.new(source_ids: ["corpus:v2"], digests: [digest])

    operations = [
      Add.new("same", id: "same", section: "Rules"),
      Add.new("same", id: "same", section: "Other"),
      Add.new("same", id: "same", status: :inactive),
      Add.new("same", id: "same", helpful: 1),
      Add.new("same", id: "same", provenance: provenance)
    ]

    hashes =
      Enum.map(operations, fn operation ->
        assert {:ok, result} = Playbook.apply_delta(Playbook.new(id: "root"), [operation])
        hd(result.entries).hash
      end)

    assert length(Enum.uniq(hashes)) == length(hashes)

    assert {:ok, left} = Playbook.apply_delta(Playbook.new(id: "root"), [List.last(operations)])
    assert {:ok, right} = Playbook.apply_delta(Playbook.new(id: "root"), [List.last(operations)])
    assert left.hash == right.hash
    refute Playbook.render(left) =~ "corpus:v2"
    refute Playbook.render(left) =~ digest
  end

  property "normalization is idempotent and produces identical entry hashes" do
    check all(content <- string(:printable, min_length: 1, max_length: 100), max_runs: 100) do
      normalized = Entry.normalize(content)
      assert Entry.normalize(normalized) == normalized

      if normalized != "" and DSEx.Redaction.redact(normalized) == normalized do
        assert Entry.new(content).hash == Entry.new(normalized).hash
      end
    end
  end

  property "failed duplicate additions never mutate the prior value" do
    check all(content <- string(:alphanumeric, min_length: 1, max_length: 40), max_runs: 100) do
      root = Playbook.new(id: "property", policy: Policy.new(reject_secrets: false))
      assert {:ok, playbook} = Playbook.apply_delta(root, [Add.new(content)])
      snapshot = :erlang.term_to_binary(playbook)

      assert {:error, {:operation_failed, 0, {:duplicate_content, _}}} =
               Playbook.apply_delta(playbook, [Add.new(" \r\n" <> content <> "  ")])

      assert :erlang.term_to_binary(playbook) == snapshot
    end
  end
end

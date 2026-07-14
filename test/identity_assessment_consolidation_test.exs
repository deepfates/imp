defmodule DSEx.IdentityAssessmentConsolidationTest do
  use ExUnit.Case, async: true

  alias DSEx.IdentityAssessmentConsolidation

  @candidates ["cand-0000000000000001", "cand-0000000000000002"]
  @profiles ["flash", "terra"]

  test "validates, sorts, consolidates, and audits a complete assessment matrix" do
    root = tmp_dir("happy")
    paths = paths(root)
    write_schema!(paths.schema)

    records = complete_records()

    write_jsonl!(paths.assessment_a, [Enum.at(records, 3), Enum.at(records, 0)])
    write_jsonl!(paths.assessment_b, [Enum.at(records, 2), Enum.at(records, 1)])
    write_jsonl!(paths.ledger_a, ledger_events("run-a", "flash"))
    write_jsonl!(paths.ledger_b, ledger_events("run-b", "terra", failed?: true))

    audit = consolidate!(paths, root)
    canonical = read_jsonl!(paths.out)

    assert Enum.map(canonical, fn record ->
             {record["candidate_id"], record["assessor"]["profile_id"], record["id"]}
           end) ==
             Enum.sort(
               Enum.map(records, fn record ->
                 {record["candidate_id"], record["assessor"]["profile_id"], record["id"]}
               end)
             )

    assert audit["outputs"]["assessments"]["record_count"] == 4
    assert audit["outputs"]["run_ledger"]["event_count"] == 7
    assert audit["ledger"]["failure_event_count"] == 1
    assert audit["ledger"]["assessment_reference_count"] == 4
    assert audit["validation"] |> Map.values() |> Enum.uniq() == [0]

    assert Enum.map(audit["profiles"], &Map.take(&1, ["profile_id", "model"])) == [
             %{"profile_id" => "flash", "model" => "openrouter:flash"},
             %{"profile_id" => "terra", "model" => "openai:terra"}
           ]

    assert audit == paths.report |> File.read!() |> Jason.decode!()
    assert audit["outputs"]["assessments"]["sha256"] == file_sha256(paths.out)
    assert audit["outputs"]["run_ledger"]["sha256"] == file_sha256(paths.runs_out)
  end

  test "rejects a missing candidate/profile pair before writing outputs" do
    root = tmp_dir("missing")
    paths = paths(root)
    write_schema!(paths.schema)
    write_jsonl!(paths.assessment_a, Enum.drop(complete_records(), -1))
    write_jsonl!(paths.assessment_b, [])
    write_jsonl!(paths.ledger_a, ledger_events("run-a", "flash"))
    write_jsonl!(paths.ledger_b, ledger_events("run-b", "terra"))

    assert_raise ArgumentError, ~r/missing candidate\/profile pairs:.*terra/, fn ->
      consolidate!(paths, root)
    end

    refute File.exists?(paths.out)
    refute File.exists?(paths.runs_out)
    refute File.exists?(paths.report)
  end

  test "rejects conflicting evidence digests across profiles" do
    root = tmp_dir("evidence")
    paths = valid_fixture!(root)

    records =
      complete_records()
      |> Enum.map(fn record ->
        if record["candidate_id"] == hd(@candidates) and
             record["assessor"]["profile_id"] == "terra" do
          put_in(record, ["assessor", "evidence_digest"], "evidence-conflict")
        else
          record
        end
      end)

    write_jsonl!(paths.assessment_a, records)

    assert_raise ArgumentError, ~r/conflicting evidence_digest values/, fn ->
      consolidate!(paths, root)
    end
  end

  test "rejects duplicate candidate/profile pairs even with distinct assessment IDs" do
    root = tmp_dir("duplicate-pair")
    paths = valid_fixture!(root)
    [first | _] = records = complete_records()
    duplicate = Map.put(first, "id", "assessment-duplicate-pair")
    write_jsonl!(paths.assessment_a, records ++ [duplicate])

    assert_raise ArgumentError, ~r/duplicate candidate\/profile pair/, fn ->
      consolidate!(paths, root)
    end
  end

  test "reports supplied-schema validation failures with source path and line" do
    root = tmp_dir("schema")
    paths = valid_fixture!(root)

    records =
      complete_records()
      |> List.update_at(1, &Map.put(&1, "confidence", "certain"))

    write_jsonl!(paths.assessment_a, records)

    error =
      assert_raise ArgumentError, fn ->
        consolidate!(paths, root)
      end

    assert error.message =~ "assessment-a.jsonl:2: assessment schema validation failed"
  end

  test "remaps colliding process-local run IDs by source ledger" do
    root = tmp_dir("run-collision")
    paths = valid_fixture!(root)
    source_run_id = "identity-assessment-run-process-local"
    write_jsonl!(paths.ledger_a, ledger_events(source_run_id, "flash"))
    write_jsonl!(paths.ledger_b, ledger_events(source_run_id, "terra"))

    audit = consolidate!(paths, root)
    events = read_jsonl!(paths.runs_out)
    by_source = Enum.group_by(events, & &1["source_ledger"])

    assert map_size(by_source) == 2

    canonical_ids =
      Enum.map(by_source, fn {_source, source_events} ->
        assert Enum.uniq(Enum.map(source_events, & &1["source_run_id"])) == [source_run_id]
        assert Enum.uniq(Enum.map(source_events, & &1["source_run_occurrence"])) == [1]
        [canonical_id] = Enum.uniq(Enum.map(source_events, & &1["run_id"]))
        refute canonical_id == source_run_id
        canonical_id
      end)

    assert length(Enum.uniq(canonical_ids)) == 2
    assert audit["ledger"]["source_run_id_collision_count"] == 1
    assert audit["ledger"]["source_run_id_collision_run_count"] == 2
    assert audit["ledger"]["source_run_id_collision_extra_occurrences"] == 1
    assert audit["ledger"]["run_id_remap_count"] == 2
  end

  test "strict JSONL errors include the source path and physical line" do
    root = tmp_dir("jsonl")
    paths = valid_fixture!(root)

    File.write!(
      paths.assessment_a,
      Jason.encode!(hd(complete_records())) <> "\n{not-json}\n"
    )

    error = assert_raise ArgumentError, fn -> consolidate!(paths, root) end
    assert error.message =~ "assessment-a.jsonl:2: invalid JSON"
  end

  test "rejects ledger events without an active run-start occurrence" do
    root = tmp_dir("orphan")
    paths = valid_fixture!(root)

    write_jsonl!(paths.ledger_a, [
      %{
        "event_type" => "identity_assessment_batch_completed",
        "run_id" => "run-orphan",
        "profile_id" => "flash"
      }
    ])

    assert_raise ArgumentError, ~r/orphaned ledger event/, fn ->
      consolidate!(paths, root)
    end
  end

  test "rejects assessments without exactly one completed-batch provenance reference" do
    root = tmp_dir("missing-provenance")
    paths = valid_fixture!(root)

    events =
      ledger_events("run-a", "flash")
      |> Enum.map(fn
        %{"event_type" => "identity_assessment_batch_completed"} = event ->
          Map.update!(event, "assessment_ids", &Enum.take(&1, 1))

        event ->
          event
      end)

    write_jsonl!(paths.ledger_a, events)

    assert_raise ArgumentError, ~r/assessment\/run-ledger provenance mismatch/, fn ->
      consolidate!(paths, root)
    end
  end

  defp consolidate!(paths, root) do
    IdentityAssessmentConsolidation.consolidate_files!(
      assessments: [paths.assessment_b, paths.assessment_a],
      run_ledgers: [paths.ledger_b, paths.ledger_a],
      profile_ids: @profiles,
      candidate_ids: @candidates,
      schema: paths.schema,
      out: paths.out,
      runs_out: paths.runs_out,
      report: paths.report,
      cwd: root
    )
  end

  defp valid_fixture!(root) do
    paths = paths(root)
    write_schema!(paths.schema)
    write_jsonl!(paths.assessment_a, complete_records())
    write_jsonl!(paths.assessment_b, [])
    write_jsonl!(paths.ledger_a, ledger_events("run-a", "flash"))
    write_jsonl!(paths.ledger_b, ledger_events("run-b", "terra"))
    paths
  end

  defp complete_records do
    for candidate_id <- @candidates, profile_id <- @profiles do
      model = if profile_id == "flash", do: "openrouter:flash", else: "openai:terra"

      %{
        "id" => "assessment-#{profile_id}-#{String.last(candidate_id)}",
        "candidate_id" => candidate_id,
        "assessed_at" => "2026-07-13T20:00:00Z",
        "assessor" => %{
          "kind" => "model",
          "name" => profile_id,
          "profile_id" => profile_id,
          "profile_digest" => "profile-digest-#{profile_id}",
          "model" => model,
          "evidence_digest" => "evidence-#{String.last(candidate_id)}"
        },
        "context" => %{},
        "scores" => %{"semantic-truth" => 4},
        "confidence" => 0.8,
        "reasoning" => "A grounded assessment.",
        "evidence_refs" => ["evidence-ref"],
        "supersedes" => nil
      }
    end
  end

  defp ledger_events(run_id, profile_id, opts \\ []) do
    completed = %{
      "event_type" => "identity_assessment_batch_completed",
      "run_id" => run_id,
      "profile_id" => profile_id,
      "assessment_ids" => Enum.map(@candidates, &"assessment-#{profile_id}-#{String.last(&1)}")
    }

    middle =
      if Keyword.get(opts, :failed?, false) do
        [
          %{
            "event_type" => "identity_assessment_batch_failed",
            "run_id" => run_id,
            "profile_id" => profile_id,
            "failure" => %{"kind" => "test"}
          },
          completed
        ]
      else
        [completed]
      end

    [
      %{
        "event_type" => "identity_assessment_run_started",
        "run_id" => run_id,
        "profiles" => [%{"id" => profile_id}]
      }
    ] ++ middle ++ [%{"event_type" => "identity_assessment_run_completed", "run_id" => run_id}]
  end

  defp write_schema!(path) do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "required" => ["id", "candidate_id", "assessor", "confidence"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "candidate_id" => %{"type" => "string"},
        "assessor" => %{"type" => "object"},
        "confidence" => %{"type" => "number"}
      }
    }

    File.write!(path, Jason.encode!(schema))
  end

  defp paths(root) do
    %{
      schema: Path.join(root, "assessment.schema.json"),
      assessment_a: Path.join(root, "assessment-a.jsonl"),
      assessment_b: Path.join(root, "assessment-b.jsonl"),
      ledger_a: Path.join(root, "ledger-a.jsonl"),
      ledger_b: Path.join(root, "ledger-b.jsonl"),
      out: Path.join(root, "canonical-assessments.jsonl"),
      runs_out: Path.join(root, "canonical-runs.jsonl"),
      report: Path.join(root, "audit.json")
    }
  end

  defp write_jsonl!(path, records) do
    body = if records == [], do: "", else: Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
    File.write!(path, body)
  end

  defp read_jsonl!(path) do
    path
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Enum.to_list()
  end

  defp file_sha256(path) do
    body = File.read!(path)
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-assessment-consolidation-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

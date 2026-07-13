defmodule DSEx.IdentityProgressTest do
  use ExUnit.Case, async: true

  alias DSEx.{IdentityCheckpoint, IdentityProgress}

  @atlas_path Path.expand("../identity/atlas.json", __DIR__)

  test "separates accepted, valid pending, and assigned frontier capacity" do
    root = tmp_root()
    accepted_path = Path.join(root, "identity/inbox/accepted.json")
    pending_path = Path.join(root, "identity/inbox/pending.json")
    assigned_path = Path.join(root, "identity/inbox/assigned.json")

    write_json!(
      accepted_path,
      portfolio("run-accepted", [candidate(1, "Form Lab"), candidate(2, "form-lab")])
    )

    write_json!(pending_path, portfolio("run-pending", [candidate(1, "Other Form")]))

    write_workflow_data!(root, [
      %{"path" => accepted_path, "target_candidate_count" => 2},
      %{"path" => pending_path, "target_candidate_count" => 1},
      %{
        "path" => assigned_path,
        "target_candidate_count" => 1,
        "missing_state" => "assigned"
      }
    ])

    report =
      IdentityProgress.snapshot(
        root: root,
        atlas: @atlas_path,
        accepted_paths: [accepted_path],
        generated_at: "2026-07-13T22:00:00Z"
      )

    frontier = report["frontier"]
    assert frontier["target_raw_occurrences"] == 4
    assert frontier["accepted"]["raw_occurrences"] == 2
    assert frontier["accepted"]["distinct_normalized_candidates"] == 1
    assert frontier["valid_pending"]["raw_occurrences"] == 1
    assert frontier["valid_pending"]["net_new_distinct_candidates"] == 1
    assert frontier["observable_valid"]["raw_occurrences"] == 3
    assert frontier["remaining_to_accept"] == 2
    assert frontier["remaining_to_generate"] == 1

    assert report["portfolio_states"] == %{
             "accepted" => 1,
             "assigned" => 1,
             "valid_pending" => 1
           }

    assert [wave] = report["waves"]
    assert wave["state"] == "in_progress"
    assert wave["accepted_raw_occurrences"] == 2
    assert wave["valid_pending_raw_occurrences"] == 1
    assert wave["remaining_to_generate"] == 1
  end

  test "partial portfolio and JSONL artifacts remain observable without crashing" do
    root = tmp_root()
    partial_path = Path.join(root, "identity/inbox/partial.json")
    File.mkdir_p!(Path.dirname(partial_path))
    File.write!(partial_path, ~s({"schema_version": 1, "run":))

    write_workflow_data!(root, [
      %{
        "path" => partial_path,
        "target_candidate_count" => 1,
        "missing_state" => "assigned"
      }
    ])

    File.write!(Path.join(root, "identity/enrichments.jsonl"), ~s({"candidate_id":))

    report =
      IdentityProgress.snapshot(
        root: root,
        atlas: @atlas_path,
        accepted_paths: [],
        generated_at: "2026-07-13T22:00:00Z"
      )

    assert report["portfolio_states"] == %{"in_progress" => 1}
    assert report["frontier"]["observable_valid"]["raw_occurrences"] == 0
    assert report["pipeline"]["enrichments"]["state"] == "needs_attention"
    assert report["pipeline"]["enrichments"]["parse_error_count"] == 1
  end

  test "a schema-valid portfolio with the wrong planned count needs attention" do
    root = tmp_root()
    path = Path.join(root, "identity/inbox/short.json")
    write_json!(path, portfolio("run-short", [candidate(1, "One Form")]))
    write_workflow_data!(root, [%{"path" => path, "target_candidate_count" => 2}])

    report =
      IdentityProgress.snapshot(
        root: root,
        atlas: @atlas_path,
        accepted_paths: [],
        generated_at: "2026-07-13T22:00:00Z"
      )

    assert report["portfolio_states"] == %{"needs_attention" => 1}
    assert report["frontier"]["valid_pending"]["raw_occurrences"] == 0
    assert [portfolio] = report["portfolios"]
    assert hd(portfolio["errors"]) =~ "does not match planned target"
  end

  test "an undeclared portfolio cannot enter the accepted frontier" do
    root = tmp_root()
    planned_path = Path.join(root, "identity/inbox/planned.json")
    unplanned_path = Path.join(root, "identity/inbox/unplanned.json")

    write_json!(planned_path, portfolio("run-planned", [candidate(1, "Planned Form")]))

    write_json!(
      unplanned_path,
      portfolio("run-unplanned", [candidate(1, "Unplanned Form")])
      |> put_in(["run", "notes"], ["challenge_wave:test-wave"])
    )

    write_workflow_data!(root, [%{"path" => planned_path, "target_candidate_count" => 1}])

    report =
      IdentityProgress.snapshot(
        root: root,
        atlas: @atlas_path,
        accepted_paths: [planned_path, unplanned_path],
        generated_at: "2026-07-13T22:00:00Z"
      )

    assert report["frontier"]["accepted"]["raw_occurrences"] == 1
    assert report["portfolio_states"] == %{"accepted" => 1, "unplanned" => 1}
    refute report["integrity"]["workflow_alignment_valid"]
    assert [error] = report["integrity"]["workflow_alignment_errors"]
    assert error =~ "unplanned.json is not declared (claims test-wave)"

    assert unplanned = Enum.find(report["portfolios"], &(&1["state"] == "unplanned"))
    assert unplanned["accepted_source"]
    assert unplanned["claimed_wave"] == "test-wave"
  end

  test "measures derived artifacts against the exact accepted event set" do
    root = tmp_root()
    accepted_path = Path.join(root, "identity/inbox/accepted.json")
    portfolio = portfolio("run-accepted", [candidate(1, "Form Lab")])
    write_json!(accepted_path, portfolio)
    write_workflow_data!(root, [%{"path" => accepted_path, "target_candidate_count" => 1}])

    body = Jason.encode!(portfolio, pretty: true) <> "\n"

    entry = %{
      path: accepted_path,
      sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
      data: portfolio
    }

    atlas = IdentityCheckpoint.load_atlas!(@atlas_path)
    assert {:ok, %{events: events}} = IdentityCheckpoint.compile(atlas, [entry])
    write_jsonl!(Path.join(root, "identity/registry.jsonl"), events)

    candidate_id = IdentityCheckpoint.candidate_id("Form Lab")

    enrichment = %{
      "id" => "enrichment-test",
      "candidate_id" => candidate_id,
      "enriched_at" => "2026-07-13T21:00:00Z",
      "assessor" => %{"kind" => "test", "name" => "progress contract"},
      "spoken_forms" => %{
        "pronunciation" => "form lab",
        "recommendation" => "Try Form Lab.",
        "support_call" => "Using Form Lab."
      },
      "code_forms" => %{
        "hex_package" => "form_lab",
        "otp_app" => "form_lab",
        "module_root" => "FormLab",
        "mix_task_prefix" => "form_lab",
        "config_prefix" => "form_lab",
        "telemetry_prefix" => "[:form_lab]"
      },
      "prose_forms" => %{
        "readme_headline" => "Form Lab for Elixir.",
        "paper_title" => "Form Lab: An Elixir Study",
        "conference_sentence" => "We evaluated Form Lab.",
        "error_sentence" => "Form Lab could not complete the call."
      },
      "architecture_forms" => [
        %{"architecture_id" => "beam-master", "form" => "Form Lab", "notes" => "Test"}
      ],
      "international_notes" => [],
      "future_scope_notes" => ["Test-only embodiment."],
      "supersedes" => nil
    }

    write_jsonl!(Path.join(root, "identity/enrichments.jsonl"), [enrichment])

    report =
      IdentityProgress.snapshot(
        root: root,
        atlas: @atlas_path,
        accepted_paths: [accepted_path],
        generated_at: "2026-07-13T22:00:00Z"
      )

    pipeline = report["pipeline"]
    assert pipeline["registry"]["state"] == "complete"
    assert pipeline["registry"]["completed"] == 2
    assert pipeline["enrichments"]["state"] == "complete"
    assert pipeline["spoken_forms"]["state"] == "complete"
    assert pipeline["code_forms"]["state"] == "complete"
    assert pipeline["architecture_forms"]["state"] == "complete"
    assert pipeline["international_review"]["state"] == "not_started"
    assert pipeline["assessments"]["target"] == 1
    assert pipeline["assessments"]["target_assessment_records"] == 3
    assert pipeline["collision_checks"]["target"] == 4

    write_jsonl!(
      Path.join(root, "identity/registry.jsonl"),
      events ++ [%{"event_id" => "event-extra", "event_type" => "generation_run"}]
    )

    out_of_sync =
      IdentityProgress.snapshot(
        root: root,
        atlas: @atlas_path,
        accepted_paths: [accepted_path],
        generated_at: "2026-07-13T22:00:00Z"
      )

    assert out_of_sync["pipeline"]["registry"]["state"] == "out_of_sync"
    assert out_of_sync["pipeline"]["registry"]["extra_events"] == 1
  end

  test "malformed enrichment shapes do not crash coverage" do
    root = tmp_root()
    accepted_path = Path.join(root, "identity/inbox/accepted.json")
    write_json!(accepted_path, portfolio("run-accepted", [candidate(1, "Form Lab")]))
    write_workflow_data!(root, [%{"path" => accepted_path, "target_candidate_count" => 1}])

    candidate_id = IdentityCheckpoint.candidate_id("Form Lab")

    write_jsonl!(Path.join(root, "identity/enrichments.jsonl"), [
      %{"id" => "enrichment-test", "candidate_id" => candidate_id, "code_forms" => []}
    ])

    write_jsonl!(Path.join(root, "identity/assessments.jsonl"), [
      %{"id" => "assessment-test", "candidate_id" => candidate_id, "scores" => []}
    ])

    report =
      IdentityProgress.snapshot(
        root: root,
        atlas: @atlas_path,
        accepted_paths: [accepted_path],
        generated_at: "2026-07-13T22:00:00Z"
      )

    assert report["pipeline"]["code_forms"]["state"] == "needs_attention"
    assert report["pipeline"]["assessments"]["state"] == "needs_attention"
    assert report["pipeline"]["assessments"]["completed"] == 0
  end

  test "Git acceptance excludes dirty tracked and untracked portfolios" do
    root = tmp_root()
    clean = Path.join(root, "identity/inbox/clean.json")
    dirty = Path.join(root, "identity/inbox/dirty.json")
    untracked = Path.join(root, "identity/inbox/untracked.json")
    File.mkdir_p!(Path.dirname(clean))
    File.write!(clean, "clean\n")
    File.write!(dirty, "before\n")

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "identity-progress@example.invalid"])
    git!(root, ["config", "user.name", "Identity Progress Test"])
    git!(root, ["add", "identity/inbox/clean.json", "identity/inbox/dirty.json"])
    git!(root, ["commit", "-qm", "seed"])

    File.write!(dirty, "after\n")
    File.write!(untracked, "new\n")
    git!(root, ["add", "identity/inbox/untracked.json"])

    accepted =
      Path.join(root, "identity/inbox/*.json")
      |> IdentityProgress.git_accepted_paths!(root: root)
      |> MapSet.new()

    assert accepted == MapSet.new([clean])
  end

  test "text view includes frontier and pipeline denominators" do
    coverage = %{"completed" => 0, "target" => 8, "state" => "not_started"}

    report = %{
      "frontier" => %{
        "target_raw_occurrences" => 10,
        "remaining_to_accept" => 4,
        "remaining_to_generate" => 2,
        "accepted" => stats(6),
        "valid_pending" => Map.put(stats(2), "net_new_distinct_candidates", 2),
        "observable_valid" => stats(8)
      },
      "waves" => [
        %{
          "id" => "wave-a",
          "state" => "in_progress",
          "accepted_raw_occurrences" => 6,
          "target_raw_occurrences" => 10,
          "valid_pending_raw_occurrences" => 2,
          "remaining_to_generate" => 2
        }
      ],
      "pipeline" => %{
        "registry" => coverage,
        "enrichments" => coverage,
        "spoken_forms" => coverage,
        "code_forms" => coverage,
        "architecture_forms" => coverage,
        "international_review" => coverage,
        "assessments" => coverage,
        "collision_checks" => coverage
      },
      "portfolios" => []
    }

    output = IdentityProgress.render_text(report)
    assert output =~ "accepted: 6 raw"
    assert output =~ "target: 10 raw"
    assert output =~ "registry events: 0/8"
  end

  defp tmp_root do
    root =
      Path.join(System.tmp_dir!(), "dsex-identity-progress-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    root
  end

  defp write_workflow_data!(root, portfolios) do
    workflow = %{
      "schema_version" => 1,
      "checkpoint_id" => "test-checkpoint",
      "selection_made" => false,
      "required_assessment_replicates" => 3,
      "collision_sources" => ["hex", "npm", "pypi", "crates"],
      "waves" => [
        %{"id" => "test-wave", "label" => "Test wave", "portfolios" => portfolios}
      ]
    }

    write_json!(Path.join(root, "identity/workflow.json"), workflow)
  end

  defp portfolio(run_id, candidates) do
    %{
      "schema_version" => 1,
      "run" => %{
        "id" => run_id,
        "generated_at" => "2026-07-13T21:00:00Z",
        "generator" => %{"kind" => "algorithm", "name" => "progress test"},
        "method" => "progress contract test",
        "brief" => "Exercise accepted and pending frontier states.",
        "atlas_version" => 1,
        "intended_territories" => ["declaration-contract"],
        "intended_strategies" => ["ordinary-object"],
        "intended_audiences" => ["beam-developers"]
      },
      "candidates" => candidates
    }
  end

  defp candidate(ordinal, surface) do
    %{
      "ordinal" => ordinal,
      "surface" => surface,
      "rationale" => "A progress-test candidate.",
      "territories" => ["declaration-contract"],
      "strategies" => ["ordinary-object"],
      "audience_lenses" => ["beam-developers"],
      "architecture_lenses" => ["beam-master"],
      "wildcard" => false
    }
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value, pretty: true) <> "\n")
  end

  defp write_jsonl!(path, records) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
  end

  defp git!(root, args) do
    assert {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end

  defp stats(count) do
    %{
      "raw_occurrences" => count,
      "distinct_normalized_candidates" => count,
      "duplicate_occurrences" => 0,
      "wildcard_occurrences" => 0
    }
  end
end

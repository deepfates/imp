defmodule Imp.IdentityAssessmentTest do
  use ExUnit.Case, async: false

  alias Imp.IdentityAssessment

  defmodule FakeReqLLM do
    def generate_object(model, messages, schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:generate_object, model, messages, schema, opts})
      {:ok, _compiled_schema} = ReqLLM.Schema.compile(schema)

      payload = messages |> user_text() |> Jason.decode!()

      assessments =
        Enum.map(payload["candidates"], fn candidate ->
          %{
            "candidate_id" => candidate["candidate_id"],
            "scores" => Map.new(payload["atlas"]["assessment_axes"], &{&1["id"], 4}),
            "confidence" => 0.8,
            "reasoning" => "#{candidate["display"]} is assessed from the supplied evidence.",
            "evidence_refs" => [hd(candidate["allowed_evidence_refs"])]
          }
        end)

      {:ok,
       %ReqLLM.Response{
         id: "identity-assessment-test",
         model: model,
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(""),
         object: %{"assessments" => assessments}
       }}
    end

    defp user_text(messages) do
      messages
      |> Enum.find(&(&1.role == :user))
      |> Map.fetch!(:content)
      |> content_text()
    end

    defp content_text(content) when is_binary(content), do: content

    defp content_text(content) when is_list(content) do
      Enum.map_join(content, "", fn
        %{text: text} when is_binary(text) -> text
        text when is_binary(text) -> text
      end)
    end
  end

  test "batches every candidate across profiles and resumes exact complete records" do
    input = input(3)
    parent = self()

    assessor = fn profile, request ->
      send(parent, {:assessed, profile.id, request.candidate_ids})
      {:ok, valid_response(request)}
    end

    opts = [
      profiles: [
        profile("beta", "anthropic:claude-sonnet-5"),
        profile("alpha", "openai:gpt-5.6-terra")
      ],
      assessor: assessor,
      batch_size: 2,
      concurrency: 2
    ]

    first = IdentityAssessment.run(input, opts)

    assert first["summary"] == %{
             "attempted_batches" => 4,
             "candidate_entities" => 3,
             "complete_records_after_run" => 6,
             "existing_complete_records" => 0,
             "expected_records" => 6,
             "failed_batches" => 0,
             "failed_records" => 0,
             "pending_records" => 6,
             "planned_batches" => 4,
             "profiles" => 2,
             "succeeded_batches" => 4,
             "succeeded_records" => 6
           }

    assert length(first["records"]) == 6
    assert first["failures"] == []
    assert Enum.uniq_by(first["records"], & &1["id"]) == first["records"]

    assessment_schema =
      "identity/schema/assessment.schema.json"
      |> File.read!()
      |> Jason.decode!()
      |> JSV.build!(formats: true)

    Enum.each(first["records"], fn record ->
      assert {:ok, _validated} = JSV.validate(record, assessment_schema)
      assert record["assessor"]["kind"] == "model"
      assert String.starts_with?(record["assessor"]["name"], "Model assessment:")
      assert Map.keys(record["scores"]) |> Enum.sort() == ~w(current-product-fit semantic-truth)
      assert record["supersedes"] == nil
    end)

    resumed =
      IdentityAssessment.run(
        Map.put(input, :assessments, first["records"]),
        Keyword.put(opts, :assessor, fn _profile, _request -> flunk("resume called assessor") end)
      )

    assert resumed["summary"]["existing_complete_records"] == 6
    assert resumed["summary"]["pending_records"] == 0
    assert resumed["summary"]["attempted_batches"] == 0
    assert resumed["records"] == []

    repeated = IdentityAssessment.run(input, opts)
    assert Enum.map(repeated["records"], & &1["id"]) == Enum.map(first["records"], & &1["id"])
  end

  test "accepts fenced JSON text and canonicalizes model evidence" do
    assessor = fn _profile, request ->
      body = request |> valid_response() |> Jason.encode!()
      {:ok, "```json\n#{body}\n```"}
    end

    result =
      IdentityAssessment.run(input(1),
        profiles: [profile("text", "openai:gpt-5.6-terra")],
        assessor: assessor
      )

    assert result["summary"]["succeeded_records"] == 1
    assert [%{"evidence_refs" => refs}] = result["records"]
    assert refs == Enum.sort(refs)
  end

  test "accepts a provider response with a JSON-encoded assessments array" do
    assessor = fn _profile, request ->
      response = valid_response(request)
      {:ok, %{"assessments" => Jason.encode!(response["assessments"])}}
    end

    result =
      IdentityAssessment.run(input(1),
        profiles: [profile("nested-json", "anthropic:claude-sonnet-5")],
        assessor: assessor
      )

    assert result["summary"]["succeeded_records"] == 1
  end

  test "accepts ReqLLM structured tool-call envelopes" do
    assessor = fn _profile, request ->
      {:ok, %{tool_calls: [%{arguments: valid_response(request)}]}}
    end

    result =
      IdentityAssessment.run(input(1),
        profiles: [profile("tool", "openai:gpt-5.6-terra")],
        assessor: assessor
      )

    assert result["summary"]["succeeded_records"] == 1
  end

  test "evidence changes produce a new deterministic assessment identity" do
    base = input(1)
    opts = [profiles: [profile("stable", "anthropic:claude-sonnet-5")]]

    first =
      IdentityAssessment.run(
        base,
        Keyword.put(opts, :assessor, fn _profile, request ->
          {:ok, valid_response(request)}
        end)
      )

    [first_record] = first["records"]

    changed =
      update_in(base, [:enrichments, Access.at(0), "prose_forms"], fn prose ->
        Map.put(prose, "readme_headline", "Changed evidence")
      end)

    second =
      IdentityAssessment.run(
        Map.put(changed, :assessments, [first_record]),
        Keyword.put(opts, :assessor, fn _profile, request ->
          {:ok, valid_response(request)}
        end)
      )

    assert second["summary"]["existing_complete_records"] == 0
    assert second["summary"]["succeeded_records"] == 1
    assert [second_record] = second["records"]
    refute second_record["id"] == first_record["id"]
  end

  test "rejects a batch with a missing axis and preserves the failure" do
    assessor = fn _profile, request ->
      response = valid_response(request)

      broken =
        update_in(response, ["assessments", Access.all(), "scores"], fn scores ->
          Map.delete(scores, "semantic-truth")
        end)

      {:ok, broken}
    end

    result =
      IdentityAssessment.run(input(2),
        profiles: [profile("strict", "anthropic:claude-sonnet-5")],
        assessor: assessor,
        batch_size: 2
      )

    assert result["records"] == []
    assert result["summary"]["failed_batches"] == 1
    assert result["summary"]["failed_records"] == 2

    assert [failure] = result["failures"]
    assert failure["failure"]["kind"] == "invalid_model_assessment"
    assert failure["failure"]["message"] =~ "exact atlas axis set"
    assert is_binary(failure["failure"]["response_sha256"])
  end

  test "times out bounded assessor work without losing candidate IDs" do
    assessor = fn _profile, _request ->
      Process.sleep(100)
      {:error, :too_late}
    end

    result =
      IdentityAssessment.run(input(1),
        profiles: [profile("slow", "openai:gpt-5.6-terra")],
        assessor: assessor,
        timeout: 10
      )

    assert [failure] = result["failures"]
    assert failure["failure"]["kind"] == "timeout"
    assert failure["candidate_ids"] == ["cand-0000000000000001"]
  end

  test "passes only active enrichment and current collision evidence to the assessor" do
    base = input(1)

    old_enrichment = enrichment("cand-0000000000000001", "enrichment-old")

    new_enrichment =
      enrichment("cand-0000000000000001", "enrichment-new")
      |> Map.put("supersedes", "enrichment-old")

    collisions = [
      collision("check-old", 1, "no-exact-record"),
      collision("check-new", 2, "collision")
    ]

    input =
      base
      |> Map.put(:enrichments, [old_enrichment, new_enrichment])
      |> Map.put(:flags, [flag("cand-0000000000000001")])
      |> Map.put(:collisions, collisions)

    assessor = fn _profile, request ->
      payload = request.messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
      [candidate] = payload["candidates"]

      assert Enum.map(candidate["enrichments"], & &1["id"]) == ["enrichment-new"]
      assert Enum.map(candidate["flags"], & &1["id"]) == ["flag-test"]
      assert Enum.map(candidate["collision_checks"], & &1["id"]) == ["check-new"]
      assert "check-new" in candidate["allowed_evidence_refs"]
      refute "check-old" in candidate["allowed_evidence_refs"]

      {:ok, valid_response(request)}
    end

    result =
      IdentityAssessment.run(input,
        profiles: [profile("evidence", "google/gemini:gemini-3.5-flash")],
        assessor: assessor
      )

    assert result["summary"]["succeeded_records"] == 1
    assert [%{"assessor" => %{"model" => "google:gemini-3.5-flash"}}] = result["records"]
  end

  test "file runner uses ReqLLM structured transport and preserves append-only resume" do
    root = tmp_dir("identity-assessment")
    paths = write_input_files(root, input(2))
    out = Path.join(root, "assessments.jsonl")
    runs_out = Path.join(root, "assessment-runs.jsonl")

    opts = [
      registry: paths.registry,
      enrichments: [paths.enrichments],
      flags: [],
      collisions: [],
      atlas: paths.atlas,
      out: out,
      runs_out: runs_out,
      profiles: [
        %{
          id: "flash",
          model: "google/gemini:gemini-3.5-flash",
          options: [test_pid: self()]
        }
      ],
      req_llm_module: FakeReqLLM,
      batch_size: 2,
      concurrency: 1,
      checkpoint_every: 1
    ]

    first = IdentityAssessment.run_files!(opts)
    assert first["summary"]["succeeded_records"] == 2

    assert_received {:generate_object, "google:gemini-3.5-flash", messages, schema, req_opts}
    assert Enum.any?(messages, &match?(%ReqLLM.Message{role: :user}, &1))
    assert get_in(schema, ["properties", "assessments", "minItems"]) == 2
    assert Keyword.fetch!(req_opts, :receive_timeout) == 120_000

    first_body = File.read!(out)
    assert length(jsonl(out)) == 2
    assert Enum.map(jsonl(out), & &1["assessor"]["kind"]) == ["model", "model"]

    second = IdentityAssessment.run_files!(opts)
    assert second["summary"]["existing_complete_records"] == 2
    assert second["summary"]["attempted_batches"] == 0
    assert File.read!(out) == first_body
    refute_received {:generate_object, _, _, _, _}

    events = jsonl(runs_out)
    assert Enum.count(events, &(&1["event_type"] == "identity_assessment_run_started")) == 2
    assert Enum.count(events, &(&1["event_type"] == "identity_assessment_run_completed")) == 2
  end

  test "file plan performs no provider call and creates no output artifacts" do
    root = tmp_dir("identity-assessment-plan")
    paths = write_input_files(root, input(1))
    out = Path.join(root, "assessments.jsonl")
    runs_out = Path.join(root, "assessment-runs.jsonl")

    result =
      IdentityAssessment.run_files!(
        registry: paths.registry,
        enrichments: [paths.enrichments],
        flags: [],
        collisions: [],
        atlas: paths.atlas,
        out: out,
        runs_out: runs_out,
        profiles: [%{id: "plan", model: "openai:gpt-5.6-terra"}],
        req_llm_module: FakeReqLLM,
        dry_run: true
      )

    assert result["mode"] == "plan"
    assert result["summary"]["pending_records"] == 1
    refute File.exists?(out)
    refute File.exists?(runs_out)
    refute_received {:generate_object, _, _, _, _}
  end

  test "file runner checkpoints provider failures in the run ledger" do
    root = tmp_dir("identity-assessment-failure")
    paths = write_input_files(root, input(1))
    out = Path.join(root, "assessments.jsonl")
    runs_out = Path.join(root, "assessment-runs.jsonl")

    result =
      IdentityAssessment.run_files!(
        registry: paths.registry,
        enrichments: [paths.enrichments],
        flags: [],
        collisions: [],
        atlas: paths.atlas,
        out: out,
        runs_out: runs_out,
        profiles: [%{id: "failed", model: "anthropic:claude-sonnet-5"}],
        assessor: fn _profile, _request -> {:error, :provider_unavailable} end,
        checkpoint_every: 1
      )

    assert result["summary"]["failed_records"] == 1
    refute File.exists?(out)

    assert [started, failed, completed] = jsonl(runs_out)
    assert started["event_type"] == "identity_assessment_run_started"
    assert failed["event_type"] == "identity_assessment_batch_failed"
    assert failed["failure"]["kind"] == "transport_error"
    assert completed["event_type"] == "identity_assessment_run_completed"
  end

  test "checkpoints completed batches before starting later work" do
    {:ok, state} = Agent.start_link(fn -> %{calls: 0, checkpointed_records: 0} end)

    assessor = fn _profile, request ->
      call = Agent.get_and_update(state, &{&1.calls + 1, %{&1 | calls: &1.calls + 1}})

      if call == 2 do
        assert Agent.get(state, & &1.checkpointed_records) == 1
      end

      {:ok, valid_response(request)}
    end

    checkpoint = fn records, _events ->
      Agent.update(state, &%{&1 | checkpointed_records: length(records)})
    end

    result =
      IdentityAssessment.run(input(2),
        profiles: [profile("streaming", "openai:gpt-5.6-terra")],
        assessor: assessor,
        checkpoint: checkpoint,
        batch_size: 1,
        concurrency: 1,
        checkpoint_every: 1
      )

    assert result["summary"]["succeeded_records"] == 2
    assert Agent.get(state, & &1.checkpointed_records) == 2
  end

  defp valid_response(request) do
    payload = request.messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()

    assessments =
      Enum.map(payload["candidates"], fn candidate ->
        %{
          "candidate_id" => candidate["candidate_id"],
          "scores" => Map.new(payload["atlas"]["assessment_axes"], &{&1["id"], 4}),
          "confidence" => 0.75,
          "reasoning" => "#{candidate["display"]} fits the supplied product and code evidence.",
          "evidence_refs" => [hd(candidate["allowed_evidence_refs"])]
        }
      end)

    %{"assessments" => assessments}
  end

  defp input(count) do
    ids = Enum.map(1..count, &"cand-#{String.pad_leading(Integer.to_string(&1), 16, "0")}")

    %{
      registry:
        Enum.zip_with(ids, 1..count, fn candidate_id, ordinal ->
          observation(candidate_id, ordinal)
        end),
      enrichments: Enum.map(ids, &enrichment(&1, "enrichment-#{String.slice(&1, -4, 4)}")),
      flags: [],
      collisions: [],
      assessments: [],
      atlas: atlas()
    }
  end

  defp observation(candidate_id, ordinal) do
    surface = "Candidate #{ordinal}"

    %{
      "event_type" => "candidate_observed",
      "candidate_id" => candidate_id,
      "occurrence_id" => "occ-#{ordinal}",
      "run_id" => "run-test",
      "surface" => surface,
      "normalized" => "candidate#{ordinal}",
      "ordinal" => ordinal,
      "candidate" => %{
        "rationale" => "Candidate-specific rationale #{ordinal}.",
        "territories" => ["declaration-contract"],
        "strategies" => ["ordinary-object"],
        "audience_lenses" => ["elixir-maintainers"],
        "architecture_lenses" => ["beam-master"],
        "wildcard" => false
      }
    }
  end

  defp enrichment(candidate_id, id) do
    %{
      "id" => id,
      "candidate_id" => candidate_id,
      "code_forms" => %{"hex_package" => "candidate"},
      "spoken_forms" => %{"recommendation" => "Try Candidate"},
      "prose_forms" => %{"readme_headline" => "Candidate"},
      "architecture_forms" => [],
      "supersedes" => nil
    }
  end

  defp flag(candidate_id) do
    %{
      "id" => "flag-test",
      "candidate_id" => candidate_id,
      "kind" => "scope",
      "severity" => "medium",
      "status" => "observed",
      "scope" => "test",
      "summary" => "Scope needs review.",
      "confidence" => 0.9,
      "evidence_refs" => [],
      "supersedes" => nil
    }
  end

  defp collision(id, attempt, status) do
    %{
      "id" => id,
      "candidate_id" => "cand-0000000000000001",
      "source" => "hex",
      "query" => "candidate",
      "attempt" => attempt,
      "checked_at" => "2026-07-13T00:00:0#{attempt}Z",
      "status" => status,
      "claim_basis" => "observed",
      "confidence" => 1.0,
      "summary" => status
    }
  end

  defp atlas do
    %{
      "atlas_version" => 1,
      "product_boundary" => %{
        "current" => "An Elixir library for language-model programs.",
        "credible_horizon" => "A broader artifact-optimization substrate."
      },
      "assessment_axes" => [
        %{"id" => "semantic-truth", "label" => "Semantic truth", "question" => "Is it true?"},
        %{
          "id" => "current-product-fit",
          "label" => "Current fit",
          "question" => "Does it fit now?"
        }
      ],
      "territories" => [%{"id" => "declaration-contract", "label" => "Declaration"}],
      "lexical_strategies" => [%{"id" => "ordinary-object", "label" => "Ordinary object"}],
      "audiences" => [%{"id" => "elixir-maintainers", "label" => "Elixir maintainers"}],
      "brand_architectures" => [%{"id" => "beam-master", "label" => "BEAM master"}]
    }
  end

  defp profile(id, model), do: %{id: id, model: model}

  defp write_input_files(root, input) do
    registry = Path.join(root, "registry.jsonl")
    enrichments = Path.join(root, "enrichments.jsonl")
    atlas = Path.join(root, "atlas.json")

    File.write!(registry, render_jsonl(input.registry))
    File.write!(enrichments, render_jsonl(input.enrichments))
    File.write!(atlas, Jason.encode!(input.atlas))

    %{registry: registry, enrichments: enrichments, atlas: atlas}
  end

  defp render_jsonl(records), do: Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"

  defp jsonl(path), do: Imp.IdentityEvaluation.load_jsonl!(path)

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

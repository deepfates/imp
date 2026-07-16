defmodule Imp.BenchmarkTruth.OptimizeAnythingUpstreamDifferentialReadinessTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.OptimizeAnything.UpstreamDifferential

  defmodule SequencedLM do
    defstruct [:responses]

    def generate(_messages, _opts), do: {:error, :instance_required}

    def generate(%__MODULE__{responses: responses}, _messages, _opts) do
      Agent.get_and_update(responses, fn [response | rest] -> {response, rest} end)
    end
  end

  test "readiness reports missing protocol inputs without starting Python" do
    assert {:error, message} =
             UpstreamDifferential.readiness(
               manifest: "/tmp/imp-missing-oa-manifest.json",
               python: "/tmp/imp-missing-oa-python",
               runner: "/tmp/imp-missing-oa-runner.py"
             )

    assert message =~ "protocol manifest is missing"
  end

  test "matched retry wrapper retries transient provider overloads only" do
    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:error, %{status: 529, reason: "overloaded"}},
          {:error, %{status: 503, reason: "unavailable"}},
          {:ok, "complete"}
        ]
      end)

    lm =
      UpstreamDifferential.RetryLM.new(%SequencedLM{responses: responses},
        max_retries: 3,
        base_delay_ms: 0,
        max_delay_ms: 0
      )

    assert Imp.LM.generate(lm, [%{role: :user, content: "test"}], []) == {:ok, "complete"}
    assert Agent.get(responses, & &1) == []
  end

  test "matched retry wrapper fails fast for non-transient errors" do
    {:ok, responses} =
      Agent.start_link(fn ->
        [{:error, %{status: 400, reason: "bad request"}}, {:ok, "must not run"}]
      end)

    lm =
      UpstreamDifferential.RetryLM.new(%SequencedLM{responses: responses},
        max_retries: 3,
        base_delay_ms: 0,
        max_delay_ms: 0
      )

    assert Imp.LM.generate(lm, [%{role: :user, content: "test"}], []) ==
             {:error, %{status: 400, reason: "bad request"}}

    assert Agent.get(responses, & &1) == [{:ok, "must not run"}]
  end
end

defmodule Imp.BenchmarkTruth.OptimizeAnythingUpstreamDifferentialTest do
  use ExUnit.Case, async: false

  @enabled System.get_env("IMP_OPTIMIZE_ANYTHING_DIFFERENTIAL") == "1"
  @moduletag :optimize_anything_upstream_differential

  unless @enabled do
    @moduletag skip:
                 "set IMP_OPTIMIZE_ANYTHING_DIFFERENTIAL=1 to run the pinned provider-free gate"
  end

  alias Imp.BenchmarkTruth.OptimizeAnything.UpstreamDifferential

  @manifest "benchmarks/config/optimize-anything-upstream-differential-v1.json"
  @python "tmp/optimize-anything-upstream/.venv/bin/python"

  test "pinned authority and all shared evaluators pass provider-free verification" do
    artifact =
      UpstreamDifferential.verify_evaluators(
        manifest: @manifest,
        python: @python
      )

    assert artifact["authority_verified"]

    assert Enum.map(artifact["rows"], & &1["domain"]) == [
             "circle_packing_26",
             "blackbox_problem_46",
             "swe_bench_flask_5014"
           ]

    [circle, blackbox, flask] = artifact["rows"]
    assert_in_delta circle["baseline"]["score"], 0.9797642169962063, 1.0e-12
    assert_in_delta blackbox["baseline"]["score"], -151.2525823200071, 1.0e-12
    assert blackbox["baseline"]["objective_calls"] == 1
    assert_in_delta flask["baseline"]["score"], 0.2, 1.0e-12
    assert_in_delta flask["reference"]["score"], 1.0, 1.0e-12

    runtime = artifact["test_runtime"]
    assert runtime["interpreter_sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert runtime["installed_distribution_manifest_sha256"] =~ ~r/^[0-9a-f]{64}$/
    refute runtime["cross_platform_reproducible"]
  end

  test "authority source hash drift fails readiness closed" do
    manifest = @manifest |> File.read!() |> Jason.decode!()

    drifted =
      put_in(
        manifest,
        ["authority", "source_hashes", "src/gepa/optimize_anything.py"],
        String.duplicate("0", 64)
      )

    path = temporary_path("drifted-manifest.json")
    File.write!(path, Jason.encode!(drifted))
    on_exit(fn -> File.rm(path) end)

    assert {:error, message} =
             UpstreamDifferential.readiness(
               manifest: path,
               python: @python
             )

    assert (message =~ "source hash mismatch" and
              message =~ "src/gepa/optimize_anything.py") or
             message =~
               "protocol manifest authority.source_hashes differs from canonical registry authority"
  end

  test "protocol manifest keeps adapted claims separate from paper reproduction" do
    manifest = @manifest |> File.read!() |> Jason.decode!()

    assert manifest["protocol_class"] == "adapted_matched_runtime_differential"
    assert manifest["controls"]["cache_evaluation"] == false
    assert manifest["controls"]["parallel"] == false
    assert manifest["controls"]["seeds"] == [0, 1, 2]
    assert manifest["controls"]["max_candidate_proposals"] == 2
    assert length(manifest["swe_bench"]["pass_to_pass"]) == 59

    assert "exact reproduction of every paper domain or reported number" in manifest[
             "claim_scope"
           ]["excluded"]

    assert "general superiority outside these domains, controls, seeds, and model" in manifest[
             "claim_scope"
           ]["excluded"]
  end

  defp temporary_path(name) do
    Path.join(
      System.tmp_dir!(),
      "imp-oa-#{System.unique_integer([:positive, :monotonic])}-#{name}"
    )
  end
end

defmodule Imp.BenchmarkTruth.OptimizeAnything.UpstreamDifferentialAdmissionTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.OptimizeAnything.UpstreamDifferential

  @domains ["circle_packing_26", "blackbox_problem_46", "swe_bench_flask_5014"]

  @fake_runner ~S"""
  import argparse
  import hashlib
  import json

  parser = argparse.ArgumentParser()
  parser.add_argument("--manifest", required=True)
  parser.add_argument("command")
  parser.add_argument("--domain")
  parser.add_argument("--candidate")
  parser.add_argument("--out", required=True)
  args = parser.parse_args()

  with open(args.manifest, encoding="utf-8") as handle:
      manifest = json.load(handle)

  if args.command == "describe":
      value = manifest["description"]
  elif args.command == "evaluate":
      with open(args.candidate, encoding="utf-8") as handle:
          candidate = handle.read()
      score = 2.0 if "|improved" in candidate else 1.0
      objective_calls = 2 if args.domain == "blackbox_problem_46" else 0
      value = {
          "protocol_id": manifest["protocol_id"],
          "domain": args.domain,
          "candidate_sha256": hashlib.sha256(candidate.encode("utf-8")).hexdigest(),
          "isolation": manifest["description"]["isolation"],
          "score": score,
          "side_info": {"domain": args.domain, "score": score},
          "objective_calls": objective_calls,
          "wall_time_ms": 1,
      }
  else:
      raise SystemExit(f"unsupported command: {args.command}")

  with open(args.out, "w", encoding="utf-8") as handle:
      json.dump(value, handle, sort_keys=True)
  """

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-oa-admission-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    description = description()
    manifest_path = Path.join(root, "manifest.json")
    runner_path = Path.join(root, "runner.py")
    python = System.find_executable("python3") || raise "python3 is required for admission tests"

    File.write!(
      manifest_path,
      Jason.encode!(%{"protocol_id" => description["protocol_id"], "description" => description})
    )

    File.write!(runner_path, @fake_runner)

    opts = [manifest: manifest_path, runner: runner_path, python: python]
    source_state = UpstreamDifferential.evaluator_source_state!(opts)
    raw = raw_bundle(description, source_state)
    artifact = UpstreamDifferential.build_bundle!(raw, description)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, artifact: artifact, description: description, opts: opts, raw: raw}
  end

  test "a complete evidence bundle semantically replays every recorded evaluation", context do
    durable_artifact = context.artifact |> Jason.encode!() |> Jason.decode!()
    assert length(durable_artifact["rows"]) == 9

    assert UpstreamDifferential.validate_artifact!(
             durable_artifact,
             context.description,
             context.opts
           ) == durable_artifact
  end

  test "a bounded preflight remains execution-complete but not protocol-complete", context do
    partial_raw =
      context.raw
      |> Map.put("execution_scope", %{
        "domains" => [hd(@domains)],
        "seeds" => [0],
        "full_protocol" => false
      })
      |> Map.put("domains", [hd(context.raw["domains"])])
      |> Map.put("rows", [hd(context.raw["rows"])])

    partial = UpstreamDifferential.build_bundle!(partial_raw, context.description)

    assert partial["summary"]["execution_complete"]
    refute partial["summary"]["protocol_complete"]

    assert UpstreamDifferential.validate_artifact!(
             partial,
             context.description,
             context.opts
           ) == partial
  end

  test "the auditor's fabricated nine-row live artifact is rejected", context do
    forged =
      context.artifact
      |> Map.put("schema_version", 1)
      |> Map.put("claim_scope", context.description["claim_scope"])
      |> Map.drop(["bundle_receipt"])
      |> Map.update!("rows", fn rows ->
        Enum.map(rows, fn pair ->
          pair
          |> Map.update!("upstream", &legacy_report/1)
          |> Map.update!("imp", &legacy_report/1)
        end)
      end)

    assert length(forged["rows"]) == 9

    assert_raise ArgumentError, fn ->
      UpstreamDifferential.validate_artifact!(forged, context.description, context.opts)
    end
  end

  test "an internally rebound forged evaluator score still fails semantic replay", context do
    forged_raw =
      context.raw
      |> put_in(
        [
          "rows",
          Access.at(0),
          "upstream",
          "evaluation_evidence",
          Access.at(1),
          "observed",
          "score"
        ],
        999.0
      )
      |> put_in(
        [
          "rows",
          Access.at(0),
          "upstream",
          "evaluation_evidence",
          Access.at(1),
          "observed",
          "side_info",
          "score"
        ],
        999.0
      )
      |> put_in(
        ["rows", Access.at(0), "upstream", "verification_evidence", "observed", "score"],
        999.0
      )
      |> put_in(
        [
          "rows",
          Access.at(0),
          "upstream",
          "verification_evidence",
          "observed",
          "side_info",
          "score"
        ],
        999.0
      )

    forged = UpstreamDifferential.build_bundle!(forged_raw, context.description)

    error =
      assert_raise ArgumentError, fn ->
        UpstreamDifferential.validate_artifact!(forged, context.description, context.opts)
      end

    assert error.message =~ "evaluator replay mismatch"
  end

  test "trace, token, cost, and call-count tampering are rejected", context do
    tamperers = [
      fn artifact ->
        put_in(
          artifact,
          ["rows", Access.at(0), "upstream", "evaluation_trace", Access.at(0), "score"],
          42.0
        )
      end,
      fn artifact ->
        update_in(artifact, ["rows", Access.at(0), "imp", "input_tokens"], &(&1 + 1))
      end,
      fn artifact ->
        update_in(artifact, ["rows", Access.at(0), "upstream", "cost_usd"], &(&1 + 1.0))
      end,
      fn artifact ->
        update_in(artifact, ["rows", Access.at(0), "imp", "metric_calls"], &(&1 + 1))
      end,
      fn artifact ->
        update_in(artifact, ["rows", Access.at(0), "imp", "objective_calls"], &(&1 + 1))
      end,
      fn artifact ->
        update_in(artifact, ["rows", Access.at(0), "imp", "reflection_calls"], &(&1 + 1))
      end,
      fn artifact ->
        update_in(
          artifact,
          [
            "rows",
            Access.at(0),
            "imp",
            "reflection_evidence",
            Access.at(0),
            "usage_events",
            Access.at(0),
            "output_tokens"
          ],
          &(&1 + 1)
        )
      end
    ]

    Enum.each(tamperers, fn tamper ->
      assert_raise ArgumentError, fn ->
        context.artifact
        |> tamper.()
        |> UpstreamDifferential.validate_artifact!(context.description, context.opts)
      end
    end)
  end

  test "claim scope states the residual provider-execution trust limitation", context do
    claim_scope = context.artifact["claim_scope"]
    receipt = context.artifact["bundle_receipt"]

    refute claim_scope["provider_execution_cryptographically_proven"]
    refute receipt["provider_execution_attested"]
    assert Enum.any?(claim_scope["limitations"], &String.contains?(&1, "not signatures"))

    assert Enum.any?(
             claim_scope["limitations"],
             &String.contains?(&1, "not cryptographically proven")
           )
  end

  test "source-bound admission rejects a fabricated clean flag in a dirty tree", context do
    marker =
      Path.join(File.cwd!(), "imp-oa-admission-dirty-#{System.unique_integer([:positive])}")

    File.write!(marker, "uncommitted")
    on_exit(fn -> File.rm(marker) end)

    forged_raw = put_in(context.raw, ["source_state", "working_tree_clean"], true)
    forged = UpstreamDifferential.build_bundle!(forged_raw, context.description)

    assert_raise ArgumentError, ~r/current repository is dirty/, fn ->
      UpstreamDifferential.admit_artifact!(forged, context.opts)
    end
  end

  test "source-bound validation rejects a supplied current harness digest", context do
    forged_raw =
      put_in(
        context.raw,
        ["source_state", "imp_harness_sha256"],
        String.duplicate("0", 64)
      )

    forged = UpstreamDifferential.build_bundle!(forged_raw, context.description)

    assert_raise ArgumentError, ~r/pinned evaluator source receipt mismatch/, fn ->
      UpstreamDifferential.validate_artifact!(forged, context.description, context.opts)
    end
  end

  test "source-bound validation detects runner mutation after capture", context do
    runner = context.opts[:runner]
    original = File.read!(runner)

    try do
      File.write!(runner, original <> "\n# mutation after capture\n")

      assert_raise ArgumentError, ~r/pinned evaluator source receipt mismatch/, fn ->
        UpstreamDifferential.validate_artifact!(
          context.artifact,
          context.description,
          context.opts
        )
      end
    after
      File.write!(runner, original)
    end
  end

  defp raw_bundle(description, source_state) do
    controls = description["controls"]

    rows =
      for domain <- description["domains"], seed <- controls["seeds"] do
        %{
          "domain" => domain["id"],
          "seed" => seed,
          "upstream" => raw_report(description, domain, seed, "upstream_python"),
          "imp" => raw_report(description, domain, seed, "imp_beam")
        }
      end

    %{
      "protocol_id" => description["protocol_id"],
      "protocol_class" => description["protocol_class"],
      "generated_at" => "2026-07-15T12:00:00Z",
      "source_state" => source_state,
      "authority" => description["authority"],
      "swe_bench" => description["swe_bench"],
      "controls" => controls,
      "execution_scope" => %{
        "domains" => @domains,
        "seeds" => controls["seeds"],
        "full_protocol" => true
      },
      "domains" =>
        Enum.map(
          description["domains"],
          &Map.take(&1, [
            "id",
            "kind",
            "objective",
            "seed_candidate_sha256",
            "reflection_template_sha256",
            "evaluator"
          ])
        ),
      "rows" => rows
    }
  end

  defp raw_report(description, domain, seed, runtime) do
    controls = description["controls"]
    baseline = domain["seed_candidate"]
    improved = "#{domain["id"]}|#{runtime}|#{seed}|improved"

    evidence = [
      evaluation_evidence(description, domain["id"], baseline, 1, 1.0),
      evaluation_evidence(description, domain["id"], improved, 2, 2.0)
    ]

    %{
      "protocol_id" => description["protocol_id"],
      "runtime" => runtime,
      "authority_commit" => description["authority"]["commit"],
      "domain" => domain["id"],
      "seed" => seed,
      "model" => controls["model"],
      "controls" =>
        Map.take(controls, [
          "max_candidate_proposals",
          "parallel",
          "max_workers",
          "cache_evaluation",
          "reflection_minibatch_size",
          "candidate_selection_strategy",
          "frontier_type"
        ]),
      "wall_time_ms" => 5,
      "stop_reason" => "fixture_complete",
      "evaluation_evidence" => evidence,
      "verification_evidence" => evaluation_evidence(description, domain["id"], improved, 3, 2.0),
      "reflection_evidence" => [reflection_evidence(controls["model"], runtime)]
    }
  end

  defp evaluation_evidence(description, domain, candidate, sequence, score) do
    objective_calls = if domain == "blackbox_problem_46", do: 2, else: 0

    %{
      "sequence" => sequence,
      "candidate" => candidate,
      "observed" => %{
        "protocol_id" => description["protocol_id"],
        "domain" => domain,
        "candidate_sha256" => sha256(candidate),
        "isolation" => description["isolation"],
        "score" => score,
        "side_info" => %{"domain" => domain, "score" => score},
        "objective_calls" => objective_calls,
        "wall_time_ms" => 1
      }
    }
  end

  defp reflection_evidence(model, runtime) do
    {call_source, event_source, event, model_name} =
      if runtime == "imp_beam" do
        {"imp_lm_call_audit", "req_llm_token_usage_telemetry", "req_llm.token_usage",
         model["imp_name"]}
      else
        {"pinned_litellm_call_wrapper", "litellm_response_usage_delta", "litellm.completion",
         model["upstream_name"]}
      end

    %{
      "sequence" => 1,
      "source" => call_source,
      "prompt_sha256" => sha256("prompt"),
      "response_sha256" => sha256("response"),
      "status" => "ok",
      "usage_events" => [
        %{
          "sequence" => 1,
          "source" => event_source,
          "event" => event,
          "provider" => model["provider"],
          "model" => model_name,
          "request_id_sha256" => nil,
          "input_tokens" => 10,
          "output_tokens" => 5,
          "cost_usd" => 0.01
        }
      ]
    }
  end

  defp legacy_report(report) do
    report
    |> Map.put("schema_version", 1)
    |> Map.drop([
      "evaluation_evidence",
      "verification_evidence",
      "reflection_evidence",
      "usage_evidence_scope",
      "run_receipt"
    ])
  end

  defp description do
    controls = %{
      "seeds" => [0, 1, 2],
      "max_candidate_proposals" => 2,
      "parallel" => false,
      "max_workers" => 1,
      "cache_evaluation" => false,
      "reflection_minibatch_size" => 1,
      "candidate_selection_strategy" => "pareto",
      "frontier_type" => "hybrid",
      "model" => %{
        "provider" => "anthropic",
        "upstream_name" => "anthropic/test-model",
        "imp_name" => "anthropic:test-model",
        "temperature" => 0,
        "max_tokens" => 128,
        "upstream_retries" => 3,
        "imp_retries" => 3,
        "imp_retry_base_delay_ms" => 0,
        "imp_retry_max_delay_ms" => 0
      }
    }

    domains =
      Enum.map(@domains, fn id ->
        seed = "#{id}|baseline"
        template = "candidate=<curr_param>\nfeedback=<side_info>"

        %{
          "id" => id,
          "kind" => "fixture",
          "objective" => "fixture objective",
          "seed_candidate" => seed,
          "seed_candidate_sha256" => sha256(seed),
          "reflection_template" => template,
          "reflection_template_sha256" => sha256(template),
          "evaluator" => %{"fixture" => true}
        }
      end)

    %{
      "schema_version" => 1,
      "protocol_id" => "optimize_anything_upstream_differential_v1",
      "protocol_class" => "adapted_matched_runtime_differential",
      "authority" => %{
        "repository" => "https://example.invalid/pinned-authority",
        "commit" => String.duplicate("a", 40),
        "source_hashes" => %{}
      },
      "swe_bench" => %{"instance_id" => "fixture"},
      "isolation" => %{"mode" => "fixture_sandbox"},
      "controls" => controls,
      "claim_scope" => %{"included" => ["fixture"], "excluded" => []},
      "domains" => domains
    }
  end

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

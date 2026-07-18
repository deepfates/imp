defmodule Mix.Tasks.Imp.Benchmark.Dashboard do
  @moduledoc """
  Aggregate Imp-vs-DSPy validation evidence into one dashboard artifact.

      mix imp.benchmark.dashboard

  By default the task writes a dashboard even when lanes are missing. Use
  `--require-ready` for the profile gate that refuses readiness unless every
  release-blocking claim in the selected profile has its required evidence.

  Public claims are evaluated from `benchmarks/claims.json` by default. Pass
  `--claims-file path/to/claims.json` to inspect a different inventory. An
  alternate inventory is diagnostic only and cannot authorize profile readiness.

  Select `--profile v0.1`, `--profile telos`, or `--profile research` to choose
  the claim scope. The default is the product-scoped `v0.1` profile.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.{ArtifactFile, LocalMLXCampaign, OverheadPolicy, ReleaseProfile}

  @shortdoc "Aggregate parity and performance evidence into a dashboard"

  @default_results_dir Imp.BenchmarkTruth.Paths.runs_root()
  @default_claims_file "benchmarks/claims.json"
  @failure_case_ids ~w(
    task_cancellation_releases_admission
    task_timeout_is_explicit_and_terminal
    async_concurrency_is_bounded
    partial_stream_failure_is_terminal
    training_retry_and_idempotency_are_bounded
    http_retrieval_retry_timeout_and_idempotency
    mcp_retry_timeout_and_idempotency
    mipro_v2_durable_resume_and_tamper
    simba_durable_resume_and_tamper
  )
  @failure_live_ids ~w(
    provider_retry_timeout_idempotency_live
    retrieval_and_tool_agent_recovery_live
  )
  @instruction_optimizer_tier "t1_instruction_optimizer_differential_contract"
  @instruction_optimizer_dspy_version "3.3.0b1"
  @instruction_optimizer_dspy_commit "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
  @instruction_optimizer_sources %{
    "dspy/propose/grounded_proposer.py" =>
      "c9900b74c0997410f915f2a470d39dcd9d55c1fa8b9cdf35799915ec0b1617e3",
    "dspy/teleprompt/bootstrap.py" =>
      "0a588f11f09a358a5306540cc42401d905073c9452e54d32348b13d12bbb1255",
    "dspy/teleprompt/mipro_optimizer_v2.py" =>
      "6bf7632836d3a54ab0da3f38a8f1963813472312e9c0e3f2ff19b4377af407f3",
    "dspy/teleprompt/simba.py" =>
      "4de72e1d0cb1cd30a180569c21973c41fa272c3ebb82a365e3f307986ab67a55",
    "dspy/teleprompt/simba_utils.py" =>
      "ed745647ffcfcf4090e5d5b5489cd0b13ebfff1d38a22559563f4f606b31fb2c",
    "dspy/teleprompt/utils.py" =>
      "218c38c25dde75aab9b1d452a15c75687c2e1842d7157dcc6c695f5adbcaf182"
  }
  @rag_tool_agent_provider_free_ids ~w(
    rag_memory_retrieval
    rag_multi_hop_retrieval
    http_retriever_protocol_shape
    react_lookup_tool
    react_unknown_tool_error_trace
    mcp_import_agent_trace
    agent_tool_policy_denial
    react_v2_recovers_from_tool_and_submit_errors
    code_act_tool_program
    program_of_thought_safe_eval
    program_of_thought_rejects_unsafe_remote_call
    streaming_incremental_fields
    tasks_async_stream_ordered_results
    save_load_redacts_provider_secret
  )
  @rag_tool_agent_live_ids ~w(live_rag_memory_retrieval live_mcp_lookup_tool)

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          trace_dir: :string,
          overhead_dir: :string,
          optimizer_dir: :string,
          instruction_optimizer_dir: :string,
          gepa_dir: :string,
          optimize_anything_dir: :string,
          rag_tool_agent_dir: :string,
          rlm_dir: :string,
          live_matrix_dir: :string,
          failure_campaign_dir: :string,
          local_mlx_dir: :string,
          results_dir: :string,
          gate_dir: :string,
          claims_file: :string,
          out: :string,
          max_age_hours: :integer,
          profile: :string,
          require_ready: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = Keyword.get(opts, :out, @default_results_dir)
    File.mkdir_p!(out_dir)

    profile_name = Keyword.get(opts, :profile, ReleaseProfile.default())

    try do
      ReleaseProfile.fetch!(profile_name)
    rescue
      error in ArgumentError -> Mix.raise(Exception.message(error))
    end

    dashboard = dashboard(Keyword.put(opts, :profile, profile_name))

    # Exclusive allocation: two runs in the same wall-clock second must produce
    # two files, never a silent overwrite. ArtifactFile suffixes on collision
    # and returns the path it actually wrote, which is the path we announce.
    out_path =
      ArtifactFile.write_json!(
        Path.join(out_dir, "parity-dashboard-#{timestamp_slug()}.json"),
        dashboard
      )

    Mix.shell().info("parity dashboard: #{out_path}")
    Mix.shell().info("release profile: #{dashboard["profile"]["id"]}")
    Mix.shell().info("profile ready: #{dashboard["profile_ready"]}")

    Mix.shell().info(
      "provider-free overhead guard: #{dashboard["provider_free_overhead_regression_guard_passed"]}"
    )

    if Keyword.get(opts, :require_ready, false) and not dashboard["profile_ready"] do
      Mix.raise(release_gate_failure_message(dashboard, out_path))
    end
  end

  defp dashboard(opts) do
    max_age_hours = Keyword.get(opts, :max_age_hours, 24)
    profile = opts |> Keyword.fetch!(:profile) |> ReleaseProfile.fetch!()
    claims_path = Keyword.get(opts, :claims_file, @default_claims_file)
    code_revision = git_sha()

    instruction_optimizer_contract =
      instruction_optimizer_contract_lane(
        Keyword.get(opts, :instruction_optimizer_dir, "tmp/instruction-optimizer-contract"),
        max_age_hours,
        code_revision
      )

    optimizer_lift =
      optimizer_lift_lane(
        Keyword.get(opts, :optimizer_dir, "tmp/optimizer-lift"),
        max_age_hours,
        instruction_optimizer_contract
      )

    lanes = %{
      "product_package" =>
        gate_lane(
          "product_package",
          Keyword.get(opts, :gate_dir, "tmp/gate-evidence"),
          max_age_hours,
          "package.check",
          :source_revision
        ),
      "livebook_execute" =>
        gate_lane(
          "livebook_execute",
          Keyword.get(opts, :gate_dir, "tmp/gate-evidence"),
          max_age_hours,
          "livebook.execute.check",
          :source_revision
        ),
      "live_provider_smoke" =>
        gate_lane(
          "live_provider_smoke",
          Keyword.get(opts, :gate_dir, "tmp/gate-evidence"),
          max_age_hours,
          "live.check",
          :source_and_age
        ),
      "protocol_gates" =>
        gate_lane(
          "protocol_gates",
          Keyword.get(opts, :gate_dir, "tmp/gate-evidence"),
          max_age_hours,
          "protocol.check",
          :source_revision
        ),
      "failure_recovery" =>
        failure_recovery_lane(
          Keyword.get(opts, :failure_campaign_dir, "tmp/failure-campaign"),
          results_dir(opts),
          max_age_hours
        ),
      "local_mlx_weight_training" =>
        local_mlx_weight_training_lane(
          Keyword.get(opts, :local_mlx_dir, Imp.BenchmarkTruth.Paths.admitted("local_mlx")),
          max_age_hours
        ),
      "golden_trace" =>
        golden_trace_lane(Keyword.get(opts, :trace_dir, "tmp/golden-trace"), max_age_hours),
      "live_matched_model" =>
        live_matched_model_lane(
          Keyword.get(opts, :live_matrix_dir, "tmp/live-matrix"),
          results_dir(opts),
          max_age_hours
        ),
      "instruction_optimizer_contract" => instruction_optimizer_contract,
      "optimizer_lift" => optimizer_lift,
      "copro_isolation" => copro_isolation_lane(max_age_hours),
      "gepa_replication" =>
        gepa_replication_lane(
          Keyword.get(opts, :gepa_dir, "tmp/gepa-replication"),
          max_age_hours
        ),
      "optimize_anything" =>
        optimize_anything_lane(
          Keyword.get(
            opts,
            :optimize_anything_dir,
            Imp.BenchmarkTruth.Paths.admitted("optimize_anything")
          ),
          max_age_hours
        ),
      "rag_tool_agent" =>
        rag_tool_agent_lane(
          Keyword.get(opts, :rag_tool_agent_dir),
          max_age_hours
        ),
      "rlm_benchmark" =>
        rlm_benchmark_lane(
          Keyword.get(opts, :rlm_dir, "tmp/rlm-benchmark"),
          max_age_hours
        ),
      "provider_free_overhead" =>
        overhead_lane(Keyword.get(opts, :overhead_dir, "tmp/overhead"), max_age_hours)
    }

    required = profile_lane_requirements(claims_path, profile, Map.keys(lanes))
    claims = claims_gate(claims_path, lanes, profile)
    gate_checks = claim_gate_checks(claims)
    profile_ready = claims["passing"] == true
    performance_supported = get_in(lanes, ["provider_free_overhead", "full_evidence"]) == true

    %{
      "schema_version" => 3,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => code_revision,
      "max_age_hours" => max_age_hours,
      "profile" => profile,
      "required_lanes" => Enum.map(required, & &1["lane"]),
      "required_lane_requirements" => required,
      "profile_ready" => profile_ready,
      "provider_free_overhead_regression_guard_passed" => performance_supported,
      "profile_gate" => %{
        "passing" => profile_ready,
        "checks" => gate_checks,
        "blocking_lanes" =>
          gate_checks
          |> Enum.reject(& &1["passing"])
          |> Enum.map(& &1["lane"])
          |> Enum.uniq()
          |> Enum.sort(),
        "blocking_claim_ids" =>
          gate_checks
          |> Enum.reject(& &1["passing"])
          |> Enum.map(& &1["claim_id"])
          |> Enum.uniq()
          |> Enum.sort(),
        "note" =>
          "Profile readiness requires every release-blocking claim to have fresh evidence at its declared tier."
      },
      "claims" => claims,
      "summary" => %{
        "passing_lanes" => Enum.count(lanes, fn {_id, lane} -> lane["passing"] end),
        "full_evidence_lanes" => Enum.count(lanes, fn {_id, lane} -> lane["full_evidence"] end),
        "total_lanes" => map_size(lanes),
        "public_claims" => claims["summary"],
        "note" =>
          "Profile readiness is true only when every release-blocking claim has its declared evidence. Passing smoke or deterministic slices remain visible but authorize only their stated scope."
      },
      "lanes" => lanes
    }
  end

  defp results_dir(opts), do: Keyword.get(opts, :results_dir, @default_results_dir)

  defp profile_lane_requirements(path, profile, known_lanes) do
    case read_claims(path, known_lanes) do
      {:ok, claims} -> ReleaseProfile.lane_requirements(claims, profile)
      {:error, _reason} -> []
    end
  end

  defp claim_gate_checks(%{"claims" => [], "passing" => false} = claims) do
    [
      %{
        "lane" => "claims_inventory",
        "claim_id" => "claims_inventory",
        "requirement_id" => "claims_inventory.valid",
        "status" => claims["status"],
        "passing" => false,
        "fresh" => false,
        "full_evidence" => false,
        "required_evidence" => "valid_inventory",
        "limitation" => claims["limitation"],
        "blocking_requirements" => claims["blocking_requirements"] || []
      }
    ]
  end

  defp claim_gate_checks(%{"claims" => claims} = claims_gate) do
    inventory_checks =
      if get_in(claims_gate, ["artifact", "canonical"]) == false do
        [
          %{
            "lane" => "claims_inventory",
            "claim_id" => "claims_inventory",
            "requirement_id" => "claims_inventory.canonical",
            "status" => "noncanonical",
            "passing" => false,
            "fresh" => false,
            "full_evidence" => false,
            "required_evidence" => "canonical_inventory",
            "limitation" => claims_gate["limitation"],
            "blocking_requirements" => claims_gate["blocking_requirements"] || []
          }
        ]
      else
        []
      end

    claim_checks =
      claims
      |> Enum.filter(&(&1["gate_policy"] == "blocking"))
      |> Enum.flat_map(fn claim ->
        Enum.map(claim["requirements"] || [], fn requirement ->
          %{
            "lane" => requirement["lane"],
            "claim_id" => claim["id"],
            "requirement_id" => requirement["id"],
            "status" => requirement["lane_status"],
            "passing" => requirement["satisfied"] == true,
            "fresh" => requirement["lane_fresh"] == true,
            "full_evidence" => requirement["lane_full_evidence"] == true,
            "required_evidence" => requirement["evidence"],
            "limitation" => requirement["lane_limitation"],
            "blocking_requirements" => requirement["blocking_requirements"] || []
          }
        end)
      end)

    inventory_checks ++ claim_checks
  end

  defp claim_gate_checks(_claims), do: []

  defp release_gate_failure_message(dashboard, out_path) do
    blocking =
      dashboard
      |> get_in(["profile_gate", "checks"])
      |> List.wrap()
      |> Enum.reject(& &1["passing"])
      |> Enum.flat_map(&blocking_lines/1)

    """
    profile readiness gate failed; inspect #{out_path}
    blocking requirements:
    #{Enum.map_join(blocking, "\n", &"- #{&1}")}
    """
    |> String.trim()
  end

  defp blocking_lines(%{"claim_id" => claim_id, "requirement_id" => requirement_id} = check) do
    check
    |> blocking_detail_lines()
    |> Enum.map(&"claim #{claim_id} requirement #{requirement_id}: #{&1}")
  end

  defp blocking_lines(check), do: blocking_detail_lines(check)

  defp blocking_detail_lines(%{"lane" => lane, "blocking_requirements" => requirements})
       when is_list(requirements) and requirements != [] do
    Enum.map(requirements, &format_blocking_requirement(lane, &1))
  end

  defp blocking_detail_lines(%{"lane" => lane, "limitation" => limitation})
       when is_binary(limitation),
       do: ["#{lane}: #{limitation}"]

  defp blocking_detail_lines(%{"lane" => lane, "status" => status}),
    do: ["#{lane}: status #{inspect(status)} is not full passing evidence"]

  defp format_blocking_requirement(parent_lane, %{"kind" => "live_lane_full_evidence"} = req) do
    lane = req["lane"] || parent_lane
    status = req["status"] || "present"
    model = req["best_model"] || req["models"] || "unknown model"

    suffix =
      coverage_suffix(req["coverage"]) <> parity_suffix(req["parity"]) <> cost_suffix(req["cost"])

    "#{lane}: #{model} is #{status}, not full live evidence#{suffix}"
  end

  defp format_blocking_requirement(_parent_lane, %{"kind" => "public_claim_blocked"} = req) do
    claim = req["claim_id"] || "unknown_claim"
    statement = req["statement"] || "public claim"
    missing = req["missing_requirements"] || []

    suffix =
      case missing do
        [] -> ""
        values -> " (missing #{Enum.join(values, ", ")})"
      end

    "claim #{claim}: #{statement}#{suffix}"
  end

  defp format_blocking_requirement(parent_lane, %{"kind" => "live_lane_missing"} = req) do
    lane = req["lane"] || parent_lane
    "#{lane}: missing matched live evidence"
  end

  defp format_blocking_requirement(
         _parent_lane,
         %{"kind" => "campaign_coverage_incomplete"} = req
       ),
       do: "live campaign coverage incomplete#{coverage_suffix(req["coverage"])}"

  defp format_blocking_requirement(_parent_lane, %{"kind" => "campaign_full_parity_false"} = req),
    do: "live campaign parity thresholds not satisfied#{parity_suffix(req["parity"])}"

  defp format_blocking_requirement(_parent_lane, %{"kind" => "live_latency_parity_false"} = req) do
    models =
      cond do
        is_binary(req["model"]) -> req["model"]
        is_list(req["models"]) and req["models"] != [] -> Enum.join(req["models"], ", ")
        true -> "unknown model"
      end

    ratio =
      req["failures"]
      |> List.wrap()
      |> Enum.find_value(&get_in(&1, ["latency", "latency_ratio_imp_over_dspy"]))

    suffix = if is_number(ratio), do: " (latency ratio #{ratio})", else: ""

    "live latency parity failed for #{models}#{suffix}"
  end

  defp format_blocking_requirement(
         _parent_lane,
         %{"kind" => "live_max_concurrency_inconsistent"} = req
       ) do
    models =
      req["failures"]
      |> List.wrap()
      |> Enum.map(& &1["model"])
      |> Enum.reject(&is_nil/1)

    suffix =
      case models do
        [] -> ""
        values -> " for #{Enum.join(values, ", ")}"
      end

    "live max_concurrency evidence is missing or inconsistent#{suffix}"
  end

  defp format_blocking_requirement(parent_lane, %{"message" => message}) when is_binary(message),
    do: "#{parent_lane}: #{message}"

  defp format_blocking_requirement(parent_lane, requirement) when is_binary(requirement),
    do: "#{parent_lane}: #{requirement}"

  defp format_blocking_requirement(parent_lane, requirement),
    do: "#{parent_lane}: #{inspect(requirement)}"

  defp coverage_suffix(%{} = coverage) do
    cond do
      is_number(coverage["remaining_rows"]) ->
        " (#{coverage["remaining_rows"]} rows remaining)"

      is_number(coverage["covered"]) and is_number(coverage["expected"]) ->
        " (#{coverage["covered"]}/#{coverage["expected"]} rows covered)"

      is_number(coverage["covered_rows"]) and is_number(coverage["expected_rows"]) ->
        " (#{coverage["covered_rows"]}/#{coverage["expected_rows"]} rows covered)"

      true ->
        ""
    end
  end

  defp coverage_suffix(_coverage), do: ""

  defp cost_suffix(%{"estimated_remaining_total_tokens" => tokens}) when is_number(tokens),
    do: "; estimated remaining tokens #{tokens}"

  defp cost_suffix(_cost), do: ""

  defp parity_suffix(%{} = parity) do
    gap =
      parity["aggregate_gap"] ||
        parity["max_task_score_gap"] ||
        parity["score_delta"]

    if is_number(gap), do: " (gap #{gap})", else: ""
  end

  defp parity_suffix(_parity), do: ""

  defp golden_trace_lane(dir, max_age_hours) do
    with {:ok, path} <-
           latest_eligible(
             Path.join(dir, "golden-trace-parity-*.json"),
             :source_revision,
             max_age_hours,
             &valid_golden_trace_candidate?/1
           ),
         {:ok, artifact} <- read_artifact(path) do
      passing =
        get_in(artifact, ["summary", "all_cases_passing"]) == true and
          get_in(artifact, ["summary", "imp_semantic_checks", "all_passing"]) == true

      artifact_lane("golden_trace", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
        freshness: :source_revision,
        summary: %{
          "cases" => get_in(artifact, ["summary", "total"]),
          "passing_cases" => get_in(artifact, ["summary", "passing"]),
          "prediction_parity" => get_in(artifact, ["summary", "prediction_parity"]),
          "tool_trace_parity" => get_in(artifact, ["summary", "tool_trace_parity"]),
          "semantic_checks" => get_in(artifact, ["summary", "imp_semantic_checks"])
        },
        limitation:
          "Golden trace is passing for the current fixture corpus. Byte-identical prompt-template parity is intentionally not asserted; normalized semantic parity and retained message histories are the release evidence."
      )
    else
      _ -> missing_lane("golden_trace", "no golden-trace-parity artifact found in #{dir}")
    end
  end

  defp gate_lane(id, dir, max_age_hours, expected_mix_task, freshness) do
    with {:ok, path} <-
           latest_eligible(
             Path.join(dir, "gate-evidence-#{id}-*.json"),
             freshness,
             max_age_hours,
             &valid_gate_candidate?(&1, id, expected_mix_task)
           ),
         {:ok, artifact} <- read_artifact(path) do
      passing =
        artifact["gate"] == id and
          get_in(artifact, ["summary", "mix_task"]) == expected_mix_task and
          get_in(artifact, ["summary", "passing"]) == true

      artifact_lane(id, path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
        freshness: freshness,
        summary: %{
          "mix_task" => get_in(artifact, ["summary", "mix_task"]),
          "exit_status" => get_in(artifact, ["summary", "exit_status"]),
          "duration_ms" => get_in(artifact, ["summary", "duration_ms"]),
          "command" => artifact["command"],
          "output_tail" => artifact["output_tail"]
        },
        limitation:
          if(passing,
            do: nil,
            else:
              "#{id} evidence artifact exists, but it does not prove #{expected_mix_task} passed."
          ),
        blocking_requirements:
          if(passing,
            do: [],
            else: [
              %{
                "kind" => "source_gate_failed",
                "gate" => id,
                "mix_task" => expected_mix_task,
                "message" =>
                  "#{expected_mix_task} did not pass in the latest #{id} evidence artifact."
              }
            ]
          )
      )
    else
      _ ->
        missing_lane(
          id,
          "no #{id} source-checkout gate evidence artifact found in #{dir}; run mix imp.gate_evidence --gate #{id} --mix-task #{expected_mix_task}"
        )
    end
  end

  defp failure_recovery_lane(dir, canonical_results_dir, max_age_hours) do
    with {:ok, path, artifact} <-
           latest_verified_failure_artifact(
             [
               Path.join(dir, "failure-campaign-*.json"),
               Path.join(canonical_results_dir, "failure-campaign-*.json")
             ],
             max_age_hours
           ) do
      authority = failure_recovery_authority(artifact)
      deterministic = authority["deterministic_complete"]
      live = authority["live_complete"]

      blockers =
        []
        |> maybe_add_requirement(not deterministic, %{
          "kind" => "failure_recovery_t0_unverified",
          "message" =>
            "Deterministic failure recovery cases or runtime leak accounting are incomplete."
        })
        |> maybe_add_requirement(deterministic and not live, %{
          "kind" => "failure_recovery_live_incomplete",
          "missing_live_rows" => authority["missing_live_rows"],
          "message" =>
            "Verified T0 evidence is present, but completed live recovery rows are still required."
        })

      artifact_lane("failure_recovery", path, artifact, max_age_hours,
        passing: deterministic,
        full_evidence: deterministic and live,
        scale: if(live, do: "full", else: "t0"),
        freshness: :source_revision,
        full_freshness: if(live, do: :source_and_age, else: :source_revision),
        status_freshness: if(live, do: :source_and_age, else: :source_revision),
        summary: %{
          "evidence_tier" => artifact["evidence_tier"],
          "authority" => authority,
          "reported_summary" => artifact["summary"]
        },
        limitation:
          cond do
            not deterministic ->
              "The verified artifact does not independently establish deterministic T0 failure recovery."

            not live ->
              "Deterministic T0 failure recovery passes, but it cannot authorize live release recovery claims."

            true ->
              nil
          end,
        blocking_requirements: blockers
      )
    else
      {:error, :missing} ->
        missing_lane(
          "failure_recovery",
          "no failure-campaign artifact found in #{dir}; run mix benchmark.failure_campaign.check"
        )

      {:error, {:unverifiable, path, reason}} ->
        unverifiable_failure_lane(path, reason)
    end
  end

  defp read_verified_failure_artifact(path) do
    {:ok, ArtifactFile.read_run_json!(path)}
  rescue
    error -> {:error, {:unverifiable, path, Exception.message(error)}}
  end

  defp latest_verified_failure_artifact(globs, max_age_hours) do
    paths =
      globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort_by(&mtime_unix!/1, :desc)

    case paths do
      [] ->
        {:error, :missing}

      paths ->
        {valid, first_error} =
          Enum.reduce(paths, {[], nil}, fn path, {valid, first_error} ->
            case read_verified_failure_artifact(path) do
              {:ok, artifact} ->
                {[{path, artifact} | valid], first_error}

              {:error, {:unverifiable, ^path, reason}} ->
                {valid, first_error || {:error, path, reason}}
            end
          end)

        case valid do
          [] ->
            case first_error do
              {:error, path, reason} -> {:error, {:unverifiable, path, reason}}
              nil -> {:error, :missing}
            end

          valid ->
            {path, artifact} =
              Enum.max_by(valid, fn {path, artifact} ->
                live = failure_recovery_authority(artifact)["live_complete"] == true
                freshness = if(live, do: :source_and_age, else: :source_revision)
                admitted = fresh?(artifact, path, max_age_hours, freshness)
                {admitted, live, mtime_unix!(path)}
              end)

            {:ok, path, artifact}
        end
    end
  end

  defp local_mlx_weight_training_lane(dir, max_age_hours) do
    with {:ok, path, validated} <-
           latest_valid_local_mlx_artifact(Path.join(dir, "*.json")) do
      artifact_lane("local_mlx_weight_training", path, validated, max_age_hours,
        passing: true,
        full_evidence: true,
        scale: "full",
        summary: %{
          "status" => validated["status"],
          "evidence_level" => validated["evidence_level"],
          "effect" => validated["effect"],
          "acceptance" => validated["acceptance"]
        },
        limitation:
          "This evidence establishes local MLX weight-training effectiveness only; it does not establish BetterTogether parity."
      )
    else
      {:error, :missing} ->
        missing_lane(
          "local_mlx_weight_training",
          "no local-mlx campaign artifact found in #{dir}"
        )

      {:error, {:unverifiable, path, reason}} ->
        rejected_local_mlx_lane(path, "artifact envelope is invalid or tampered: #{reason}")

      {:error, {:rejected, path, reasons}} ->
        rejected_local_mlx_lane(
          path,
          "artifact was rejected by LocalMLXCampaign validation: #{inspect(reasons)}"
        )
    end
  end

  defp copro_isolation_lane(max_age_hours) do
    registry = Imp.ReproductionRegistry.load!()
    feature = Enum.find(registry["features"], &(&1["id"] == "copro"))
    evidence = feature && feature["admitted_evidence"]

    unless is_map(evidence) and evidence["tier"] == "t1" and
             evidence["protocol_id"] == "copro_isolation" and
             is_binary(evidence["artifact"]) do
      raise ArgumentError, "canonical COPRO T1 isolation evidence is not selected"
    end

    path = evidence["artifact"]
    artifact = ArtifactFile.read_run_json!(path)
    Imp.ReproductionRegistry.validate_protocol_artifact!(registry, "copro_isolation", artifact)

    artifact_lane("copro_isolation", path, artifact, max_age_hours,
      passing: true,
      full_evidence: true,
      scale: "full",
      freshness: :age,
      summary: %{
        "feature" => "copro",
        "tier" => evidence["tier"],
        "protocol_id" => evidence["protocol_id"],
        "artifact_sha256" => evidence["artifact_sha256"],
        "deterministic_observations_verified" =>
          get_in(artifact, ["summary", "deterministic_observations_verified"]),
        "limitations" => get_in(artifact, ["scope", "not_claimed"])
      },
      limitation:
        "The canonical artifact proves only its five DSPy 3.2.1 observations; it excludes exact RNG parity, provider behavior, effectiveness, and full optimizer parity."
    )
  rescue
    error ->
      missing_lane(
        "copro_isolation",
        "canonical selected COPRO isolation evidence is invalid: #{Exception.message(error)}"
      )
  end

  defp latest_valid_local_mlx_artifact(glob) do
    paths = glob |> Path.wildcard() |> Enum.sort_by(&mtime_unix!/1, :desc)

    {valid, rejected} =
      Enum.reduce(paths, {[], []}, fn path, {valid, rejected} ->
        with {:ok, artifact} <- read_verified_local_mlx_artifact(path),
             {:ok, validated} <- validate_local_mlx_artifact(path, artifact) do
          {[{path, validated} | valid], rejected}
        else
          {:error, reason} -> {valid, [{path, reason} | rejected]}
        end
      end)

    case valid do
      [] ->
        case List.first(rejected) do
          {_path, {:unverifiable, path, reason}} -> {:error, {:unverifiable, path, reason}}
          {_path, {:rejected, path, reasons}} -> {:error, {:rejected, path, reasons}}
          nil -> {:error, :missing}
        end

      valid ->
        {path, artifact} =
          Enum.max_by(valid, fn {path, artifact} ->
            {artifact_timestamp(artifact), mtime_unix!(path)}
          end)

        {:ok, path, artifact}
    end
  end

  defp read_verified_local_mlx_artifact(path) do
    {:ok, ArtifactFile.read_run_json!(path)}
  rescue
    error -> {:error, {:unverifiable, path, Exception.message(error)}}
  end

  defp validate_local_mlx_artifact(path, artifact) do
    case LocalMLXCampaign.validate_artifact(artifact) do
      {:ok, validated} -> {:ok, validated}
      {:error, reasons} -> {:error, {:rejected, path, reasons}}
    end
  end

  defp rejected_local_mlx_lane(path, reason) do
    %{
      "id" => "local_mlx_weight_training",
      "status" => "failing",
      "passing" => false,
      "fresh" => false,
      "full_evidence" => false,
      "scale" => "rejected",
      "artifact" => if(path, do: %{"path" => path, "sha256" => file_sha256(path)}, else: nil),
      "summary" => %{"validated" => false},
      "limitation" => reason,
      "blocking_requirements" => [
        %{
          "kind" => "local_mlx_artifact_rejected",
          "message" =>
            "Local MLX weight-training evidence requires a verified, independently validated successful artifact."
        }
      ]
    }
  end

  defp failure_recovery_authority(artifact) do
    cases = artifact["cases"] || []
    deterministic_cases = Enum.filter(cases, &(&1["evidence_kind"] == "deterministic"))
    configured_iterations = get_in(artifact, ["configuration", "iterations"])
    required_iterations = get_in(artifact, ["configuration", "required_flake_iterations"])

    valid_case_ids =
      deterministic_cases
      |> Enum.filter(&valid_failure_case?(&1, configured_iterations, required_iterations))
      |> ids()

    expected_case_ids = Enum.sort(@failure_case_ids)
    runtime_complete = valid_failure_runtime?(artifact["runtime"])

    envelope_current =
      artifact["schema_version"] == 3 and artifact["runner"] == "imp-failure-campaign" and
        artifact["evidence_tier"] == "t0_deterministic_failure_recovery"

    workspace_clean =
      get_in(artifact, ["run_context", "schema_version"]) == 2 and
        get_in(artifact, ["run_context", "workspace", "state"]) == "clean" and
        get_in(artifact, ["run_context", "workspace", "reproducible"]) == true

    deterministic_complete =
      envelope_current and workspace_clean and valid_case_ids == expected_case_ids and
        runtime_complete and
        valid_failure_telemetry?(artifact["telemetry"]) and
        valid_failure_secret_scan?(artifact["secret_scan"]) and
        length(deterministic_cases) == length(expected_case_ids) and
        Enum.sort(artifact["scope"] || []) == expected_case_ids

    live_rows = failure_live_rows(artifact)
    valid_live_ids = live_rows |> Enum.filter(&valid_failure_live_row?/1) |> ids()
    expected_live_ids = Enum.sort(@failure_live_ids)

    live_complete =
      deterministic_complete and valid_live_ids == expected_live_ids and
        length(live_rows) == length(expected_live_ids)

    %{
      "run_envelope_verified" => true,
      "current_schema" => envelope_current,
      "workspace_clean" => workspace_clean,
      "deterministic_complete" => deterministic_complete,
      "runtime_complete" => runtime_complete,
      "expected_deterministic_cases" => expected_case_ids,
      "valid_deterministic_cases" => valid_case_ids,
      "live_complete" => live_complete,
      "expected_live_rows" => expected_live_ids,
      "valid_live_rows" => valid_live_ids,
      "missing_live_rows" => expected_live_ids -- valid_live_ids
    }
  end

  defp valid_failure_case?(case_row, configured_iterations, required_iterations) do
    iterations = case_row["iterations"]
    outcomes = case_row["outcomes"]

    case_row["id"] in @failure_case_ids and is_integer(required_iterations) and
      required_iterations >= 10 and is_integer(configured_iterations) and
      configured_iterations >= required_iterations and iterations == configured_iterations and
      case_row["passing"] == true and case_row["passing_iterations"] == iterations and
      case_row["failing_iterations"] == 0 and case_row["flake_rate"] == 0 and
      is_list(outcomes) and length(outcomes) == iterations and
      Enum.sort(Enum.map(outcomes, & &1["iteration"])) == Enum.to_list(1..iterations) and
      Enum.all?(outcomes, fn outcome ->
        outcome["passing"] == true and is_number(outcome["duration_ms"]) and
          outcome["duration_ms"] >= 0 and is_map(outcome["evidence"]) and
          valid_failure_case_evidence?(case_row["id"], outcome["evidence"])
      end)
  end

  defp valid_failure_case_evidence?("task_cancellation_releases_admission", evidence),
    do: evidence["task_alive"] == false and evidence["cancellation"] == "terminal"

  defp valid_failure_case_evidence?("task_timeout_is_explicit_and_terminal", evidence),
    do: evidence["outcome"] == "timeout" and evidence["worker_terminated"] == true

  defp valid_failure_case_evidence?("async_concurrency_is_bounded", evidence),
    do: evidence["ordered"] == true and evidence["peak"] <= evidence["limit"]

  defp valid_failure_case_evidence?("partial_stream_failure_is_terminal", evidence),
    do: evidence["terminal_errors"] == 1 and evidence["statuses"] == ["started", "error"]

  defp valid_failure_case_evidence?("training_retry_and_idempotency_are_bounded", evidence),
    do: bounded_retry_evidence?(evidence, 3)

  defp valid_failure_case_evidence?("http_retrieval_retry_timeout_and_idempotency", evidence),
    do: bounded_retry_evidence?(evidence, 3) and evidence["terminal_status"] == 200

  defp valid_failure_case_evidence?("mcp_retry_timeout_and_idempotency", evidence),
    do:
      evidence["initialize_attempts"] == 2 and evidence["list_attempts"] == 2 and
        evidence["max_attempts"] == 3 and evidence["idempotency_header_present"] == true and
        evidence["terminal_tool_count"] == 1

  defp valid_failure_case_evidence?(id, evidence)
       when id in ["mipro_v2_durable_resume_and_tamper", "simba_durable_resume_and_tamper"],
       do:
         evidence["exact_resume"] == true and evidence["tamper_rejected"] == true and
           evidence["checkpoint_payload_included"] == false

  defp valid_failure_case_evidence?(_id, _evidence), do: false

  defp bounded_retry_evidence?(evidence, attempts) do
    evidence["attempts"] == attempts and evidence["max_attempts"] == attempts and
      evidence["idempotency_header_stable"] == true
  end

  defp valid_failure_runtime?(%{"leaks" => leaks, "after" => after_snapshot})
       when is_map(leaks) and is_map(after_snapshot) do
    expected_leaks =
      ~w(admission_active admission_queued added_linked_tasks added_unlinked_tasks added_processes added_ports added_telemetry_handlers)

    MapSet.new(Map.keys(leaks)) == MapSet.new(expected_leaks) and
      Enum.all?(Map.values(leaks), &(&1 == 0)) and
      get_in(after_snapshot, ["admission", "active"]) == 0 and
      get_in(after_snapshot, ["admission", "queued"]) == 0 and
      non_negative_integer?(after_snapshot["linked_tasks"]) and
      non_negative_integer?(after_snapshot["unlinked_tasks"]) and
      non_negative_integer?(after_snapshot["processes"]) and
      non_negative_integer?(after_snapshot["ports"]) and
      non_negative_integer?(after_snapshot["telemetry_handlers"])
  end

  defp valid_failure_runtime?(_runtime), do: false

  defp valid_failure_telemetry?(telemetry) when is_map(telemetry) do
    telemetry["handler_detached"] == true and telemetry["balanced_spans"] == true and
      telemetry["metadata_secret_free"] == true and is_map(telemetry["event_counts"])
  end

  defp valid_failure_telemetry?(_telemetry), do: false

  defp valid_failure_secret_scan?(scan) when is_map(scan) do
    scan["passing"] == true and scan["configured_secret_hits"] == 0 and
      scan["credential_pattern_hits"] == 0 and is_binary(scan["payload_sha256"])
  end

  defp valid_failure_secret_scan?(_scan), do: false

  defp failure_live_rows(artifact) do
    explicit = artifact["live_cases"] || []
    completed_remaining = Enum.filter(artifact["remaining"] || [], &(&1["status"] == "complete"))
    live_cases = Enum.filter(artifact["cases"] || [], &(&1["evidence_kind"] == "live"))

    cond do
      explicit != [] -> explicit
      completed_remaining != [] -> completed_remaining
      true -> live_cases
    end
  end

  defp valid_failure_live_row?(row) do
    checks = row["checks"]

    row["id"] in @failure_live_ids and row["required"] == true and
      row["evidence_kind"] == "live" and row["status"] == "complete" and
      row["passing"] == true and valid_time_window?(row["started_at"], row["completed_at"]) and
      is_list(checks) and checks != [] and
      valid_failure_live_checks?(row["id"], checks) and valid_failure_live_outcomes?(row) and
      get_in(row, ["runtime", "leak_free"]) == true and
      zero_leaks?(get_in(row, ["runtime", "leaks"]))
  end

  defp valid_failure_live_checks?(id, checks) when is_list(checks) do
    ids = checks |> Enum.filter(&(&1["passing"] == true)) |> Enum.map(& &1["id"]) |> MapSet.new()
    common = MapSet.new(~w(repeated_zero_flakes runtime_leak_free))

    required =
      case id do
        "provider_retry_timeout_idempotency_live" ->
          MapSet.new(
            ~w(local_provider_terminal_success bounded_injected_timeout stable_idempotency_key dummy_canary_absent)
          )

        "retrieval_and_tool_agent_recovery_live" ->
          MapSet.new(~w(live_retrieval_recovered recoverable_tool_failure_retry_submit))

        _ ->
          MapSet.new()
      end

    MapSet.subset?(MapSet.union(common, required), ids)
  end

  defp valid_failure_live_checks?(_id, _checks), do: false

  defp valid_failure_live_outcomes?(row) do
    iterations = row["iterations"]
    outcomes = row["outcomes"]

    is_integer(iterations) and iterations >= 2 and row["passing_iterations"] == iterations and
      row["failing_iterations"] == 0 and row["flake_rate"] == 0 and is_list(outcomes) and
      length(outcomes) == iterations and
      Enum.all?(outcomes, fn outcome ->
        outcome["passing"] == true and
          valid_failure_live_evidence?(row["id"], outcome["evidence"])
      end)
  end

  defp valid_failure_live_evidence?("provider_retry_timeout_idempotency_live", evidence) do
    evidence["provider"] == "local_injected_transport" and evidence["model"] == "local-fixture" and
      evidence["attempts"] == 2 and evidence["max_attempts"] == 2 and
      evidence["injected_timeout"] == true and evidence["timeout_reason"] == "timeout" and
      positive_integer?(evidence["attempt_timeout_ms"]) and
      positive_integer?(evidence["deadline_ms"]) and
      non_negative_integer?(evidence["elapsed_ms"]) and
      evidence["elapsed_ms"] >= evidence["attempt_timeout_ms"] and
      evidence["elapsed_ms"] <= evidence["deadline_ms"] and evidence["terminal_status"] == 200 and
      evidence["idempotency_header_stable"] == true and
      evidence["canary_included"] == false and is_binary(evidence["canary_sha256"])
  end

  defp valid_failure_live_evidence?("retrieval_and_tool_agent_recovery_live", evidence) do
    evidence["provider"] == "local_static_lm" and evidence["model"] == "local-fixture" and
      evidence["retrieval_attempts"] == 2 and evidence["retrieval_injected_error"] == "closed" and
      evidence["retrieval_terminal_network"] == "local_injected_transport" and
      evidence["tool_attempts"] == 2 and evidence["tool_failures"] == 1 and
      evidence["tool_successes"] == 1 and evidence["submit_calls"] == 1 and
      non_negative_integer?(evidence["elapsed_ms"]) and positive_integer?(evidence["deadline_ms"]) and
      evidence["elapsed_ms"] <= evidence["deadline_ms"] and
      evidence["canary_included"] == false and is_binary(evidence["canary_sha256"]) and
      evidence["history"] == [
        %{"tool" => "lookup", "result" => "transient_local_failure"},
        %{"tool" => "lookup", "result" => "pong"},
        %{"tool" => "submit", "result" => "completed"}
      ]
  end

  defp valid_failure_live_evidence?(_id, _evidence), do: false

  defp valid_time_window?(started_at, completed_at)
       when is_binary(started_at) and is_binary(completed_at) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, completed, _offset} <- DateTime.from_iso8601(completed_at) do
      DateTime.compare(completed, started) in [:eq, :gt]
    else
      _error -> false
    end
  end

  defp valid_time_window?(_started_at, _completed_at), do: false

  defp zero_leaks?(leaks) when is_map(leaks) and map_size(leaks) > 0,
    do: Enum.all?(Map.values(leaks), &(&1 == 0))

  defp zero_leaks?(_leaks), do: false

  defp ids(rows), do: rows |> Enum.map(& &1["id"]) |> Enum.uniq() |> Enum.sort()
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp unverifiable_failure_lane(path, reason) do
    %{
      "id" => "failure_recovery",
      "status" => "unverifiable",
      "passing" => false,
      "fresh" => false,
      "full_evidence" => false,
      "scale" => "unverifiable",
      "artifact" => %{"path" => path, "sha256" => file_sha256(path)},
      "summary" => %{"authority" => %{"run_envelope_verified" => false}},
      "limitation" => "Failure campaign artifact is legacy, tampered, or unverifiable: #{reason}",
      "blocking_requirements" => [
        %{
          "kind" => "failure_recovery_artifact_unverifiable",
          "message" => "Failure recovery authority requires a verified benchmark run envelope."
        }
      ]
    }
  end

  defp overhead_lane(dir, max_age_hours) do
    with {:ok, path} <-
           latest(Path.join(dir, "overhead-parity-*.json"), &valid_overhead_candidate?/1),
         {:ok, artifact} <- read_verified_overhead_artifact(path) do
      workspace_clean =
        get_in(artifact, ["run_context", "schema_version"]) == 2 and
          get_in(artifact, ["run_context", "workspace", "state"]) == "clean" and
          get_in(artifact, ["run_context", "workspace", "reproducible"]) == true

      policy_complete = OverheadPolicy.artifact_valid?(artifact)
      passing = policy_complete and workspace_clean

      "provider_free_overhead"
      |> artifact_lane(path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
        freshness: :source_revision,
        summary: %{
          "cases" => get_in(artifact, ["summary", "total"]),
          "passing_cases" => get_in(artifact, ["summary", "passing"]),
          "policy" => get_in(artifact, ["policy", "id"]),
          "workspace_clean" => workspace_clean,
          "ratios_are_measurements_not_speed_claims" =>
            get_in(artifact, ["policy", "ratios_are_measurements_not_speed_claims"]),
          "worst_ratio" => worst_ratio(artifact["cases"] || [])
        },
        limitation:
          "Named budgets are regression guards. Ratios remain measurements; the dashboard authorizes no speed or superiority claim."
      )
      |> maybe_reject_dirty_workspace(workspace_clean)
    else
      _ -> missing_lane("provider_free_overhead", "no overhead-parity artifact found in #{dir}")
    end
  end

  defp read_verified_overhead_artifact(path) do
    {:ok, ArtifactFile.read_run_json!(path)}
  rescue
    _error -> {:error, :unverifiable}
  end

  defp maybe_reject_dirty_workspace(lane, true), do: lane

  defp maybe_reject_dirty_workspace(lane, false) do
    lane
    |> put_in(["candidate_eligibility", "eligible"], false)
    |> update_in(["candidate_eligibility", "rejection_reasons"], fn reasons ->
      Enum.uniq((reasons || []) ++ ["workspace_not_clean"])
    end)
  end

  defp instruction_optimizer_contract_lane(dir, max_age_hours, code_revision) do
    with {:ok, path} <-
           latest(
             Path.join(dir, "instruction-optimizer-contract-*.json"),
             &valid_instruction_optimizer_candidate?/1
           ),
         {:ok, artifact} <- read_artifact(path) do
      authority = instruction_optimizer_authority(artifact)
      artifact_revision = artifact["git_sha"]
      implementation_matches = is_binary(code_revision) and artifact_revision == code_revision
      required_cases = get_in(artifact, ["summary", "required_cases"])
      required_passing = get_in(artifact, ["summary", "required_passing"])

      structural_complete =
        get_in(artifact, ["summary", "structural_contract_complete"]) == true and
          is_integer(required_cases) and required_cases > 0 and required_passing == required_cases

      passing = structural_complete and authority["complete"] and implementation_matches

      blockers =
        []
        |> maybe_add_requirement(not structural_complete, %{
          "kind" => "instruction_optimizer_structural_contract_failed",
          "message" => "The required MIPROv2/SIMBA structural differential did not pass."
        })
        |> maybe_add_requirement(not authority["complete"], %{
          "kind" => "instruction_optimizer_authority_mismatch",
          "authority" => authority,
          "message" => "The structural differential does not match the pinned DSPy authority."
        })
        |> maybe_add_requirement(not implementation_matches, %{
          "kind" => "instruction_optimizer_implementation_revision_mismatch",
          "expected_git_sha" => code_revision,
          "artifact_git_sha" => artifact_revision,
          "message" =>
            "Stale instruction-optimizer evidence: artifact git_sha #{inspect(artifact_revision)} does not match dashboard code revision #{inspect(code_revision)}."
        })

      artifact_lane("instruction_optimizer_contract", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
        summary: %{
          "evidence_tier" => artifact["evidence_tier"],
          "required_cases" => required_cases,
          "required_passing" => required_passing,
          "structural_contract_complete" => structural_complete,
          "implementation_revision_matches" => implementation_matches,
          "expected_git_sha" => code_revision,
          "authority" => authority,
          "declared_native_deviations" => artifact["declared_native_deviations"] || []
        },
        limitation:
          if(passing,
            do:
              "T1 structural control-flow parity is established; optimizer effectiveness and exact RNG/sampler sequence parity remain separate claims.",
            else:
              "Instruction-optimizer structural evidence is failed or does not match the pinned DSPy authority."
          ),
        blocking_requirements: blockers
      )
    else
      _ ->
        missing_lane(
          "instruction_optimizer_contract",
          "no instruction-optimizer-contract artifact found in #{dir}"
        )
    end
  end

  defp instruction_optimizer_authority(artifact) do
    dspy = if is_map(artifact["dspy"]), do: artifact["dspy"], else: %{}

    actual_sources =
      dspy
      |> Map.get("sources", [])
      |> Map.new(fn
        %{"path" => path, "sha256" => hash} when is_binary(path) and is_binary(hash) ->
          {path, hash}

        _source ->
          {nil, nil}
      end)

    checks = %{
      "evidence_tier" => artifact["evidence_tier"] == @instruction_optimizer_tier,
      "dspy_version" => dspy["version"] == @instruction_optimizer_dspy_version,
      "dspy_commit" => dspy["commit"] == @instruction_optimizer_dspy_commit,
      "source_hashes" => actual_sources == @instruction_optimizer_sources
    }

    %{
      "complete" => Enum.all?(checks, fn {_id, passing} -> passing end),
      "checks" => checks,
      "expected_dspy_version" => @instruction_optimizer_dspy_version,
      "expected_dspy_commit" => @instruction_optimizer_dspy_commit,
      "expected_sources" => @instruction_optimizer_sources
    }
  end

  defp optimizer_lift_lane(dir, max_age_hours, instruction_optimizer_contract) do
    with {:ok, path} <-
           latest(
             Path.join(dir, "optimizer-lift-parity-*.json"),
             &valid_optimizer_lift_candidate?/1
           ),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["summary", "all_passing"]) == true
      reported_full = get_in(artifact, ["summary", "full_optimizer_parity"]) == true
      structural_complete = instruction_optimizer_contract["full_evidence"] == true
      full = reported_full and structural_complete

      blockers =
        maybe_add_requirement([], not structural_complete, %{
          "kind" => "instruction_optimizer_contract_required",
          "lane" => "instruction_optimizer_contract",
          "status" => instruction_optimizer_contract["status"],
          "message" =>
            "Full optimizer parity requires a fresh, passing pinned instruction-optimizer structural contract."
        })

      artifact_lane("optimizer_lift", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing and full,
        scale: if(full, do: "full", else: "sample"),
        summary: %{
          "total" => get_in(artifact, ["summary", "total"]),
          "passing" => get_in(artifact, ["summary", "passing"]),
          "direct_comparisons" => get_in(artifact, ["summary", "direct_comparisons"]),
          "imp_only_or_deviation" => get_in(artifact, ["summary", "imp_only_or_deviation"]),
          "direct_optimizers" => row_names_by_status(artifact, "direct"),
          "imp_only_or_deviation_optimizers" => non_direct_row_names(artifact),
          "reported_full_optimizer_parity" => reported_full,
          "instruction_optimizer_contract_complete" => structural_complete,
          "full_optimizer_parity" => full
        },
        limitation:
          cond do
            not structural_complete ->
              "Optimizer lift cannot authorize full parity without fresh pinned MIPROv2/SIMBA structural differential evidence."

            full ->
              nil

            true ->
              "Optimizer lift artifact is passing as a sample, but direct DSPy comparisons do not yet cover every production optimizer/trainer path."
          end,
        blocking_requirements: blockers
      )
    else
      _ -> missing_lane("optimizer_lift", "no optimizer-lift-parity artifact found in #{dir}")
    end
  end

  defp gepa_replication_lane(dir, max_age_hours) do
    required_families = Imp.BenchmarkTruth.GepaReplicationContract.required_families()
    optimizer_fields = Imp.BenchmarkTruth.GepaReplicationContract.optimizer_fields()

    with {:ok, path} <-
           latest(Path.join(dir, "gepa-replication-*.json"), &valid_gepa_candidate?/1),
         {:ok, artifact} <- read_artifact(path) do
      rows = Map.get(artifact, "rows", [])
      validation = Imp.BenchmarkTruth.GepaReplicationContract.validate_rows(rows)
      present_families = rows |> Enum.map(& &1["family"]) |> Enum.uniq()
      missing_families = validation.missing_families
      missing_fields = validation.missing_fields

      passing = get_in(artifact, ["summary", "all_passing"]) == true
      full = Imp.BenchmarkTruth.GepaReplicationContract.full_artifact?(artifact)

      artifact_lane("gepa_replication", path, artifact, max_age_hours,
        passing: passing and full,
        full_evidence: passing and full,
        scale: if(full, do: "full", else: "sample"),
        summary: %{
          "total" => length(rows),
          "families" => present_families,
          "required_families" => required_families,
          "missing_families" => missing_families,
          "missing_fields" => missing_fields,
          "models" => rows |> Enum.map(& &1["model"]) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
          "evidence_level" => get_in(artifact, ["summary", "evidence_level"]),
          "optimizers" => optimizer_fields,
          "all_passing" => passing,
          "full_gepa_replication" => full
        },
        blocking_requirements:
          gepa_blocking_requirements(missing_families, missing_fields, passing, full),
        limitation:
          if(passing and full,
            do: nil,
            else:
              "GEPA paper-replication claims require fresh rows for every required family with optimizer, budget, cost, seed, and split-gap fields."
          )
      )
    else
      _ -> missing_lane("gepa_replication", "no gepa-replication artifact found in #{dir}")
    end
  end

  defp optimize_anything_lane(dir, max_age_hours) do
    with {:ok, path} <-
           latest(
             Path.join(dir, "*.json"),
             &valid_optimize_anything_candidate?/1
           ),
         {:ok, artifact} <- read_artifact(path) do
      full = Imp.BenchmarkTruth.OptimizeAnything.Artifact.full_artifact?(artifact)
      rows = if is_list(artifact["rows"]), do: artifact["rows"], else: []

      artifact_lane("optimize_anything", path, artifact, max_age_hours,
        passing: full,
        full_evidence: full,
        scale:
          if(full, do: "full", else: get_in(artifact, ["summary", "evidence_level"]) || "sample"),
        summary: %{
          "artifact_classes" => Enum.map(rows, & &1["artifact_class"]),
          "rows" =>
            Enum.map(rows, fn row ->
              %{
                "artifact_class" => row["artifact_class"],
                "baseline_score" => get_in(row, ["baseline", "score"]),
                "optimized_score" => get_in(row, ["optimized", "score"]),
                "absolute_lift" => row["absolute_lift"],
                "cost_usd" => row["cost_usd"],
                "wall_time_ms" => row["wall_time_ms"],
                "reproducibility_runs" =>
                  row |> get_in(["reproducibility", "runs"]) |> List.wrap() |> length()
              }
            end),
          "effectiveness_authorized" => full,
          "provider_models" =>
            rows
            |> Enum.map(&{&1["provider"], &1["model"]})
            |> Enum.uniq()
            |> Enum.map(fn {provider, model} -> %{"provider" => provider, "model" => model} end)
        },
        limitation:
          if(full,
            do: nil,
            else:
              "Optimize Anything effectiveness requires three live non-prompt artifact classes with positive aggregate lift, provider usage, checkpoints, and a majority of improving runs across at least three seeds."
          ),
        blocking_requirements:
          if(full,
            do: [],
            else: [
              %{
                "kind" => "optimize_anything_effectiveness_incomplete",
                "message" =>
                  "The latest Optimize Anything artifact does not authorize non-prompt effectiveness."
              }
            ]
          )
      )
    else
      _ ->
        missing_lane(
          "optimize_anything",
          "no optimize-anything-replication artifact found in #{dir}; run the live Optimize Anything campaign"
        )
    end
  end

  defp gepa_blocking_requirements([], [], true, true), do: []

  defp gepa_blocking_requirements(missing_families, missing_fields, passing, full) do
    Enum.reject(
      [
        if(passing, do: nil, else: "artifact summary.all_passing must be true"),
        if(missing_families == [], do: nil, else: %{"missing_families" => missing_families}),
        if(missing_fields == [], do: nil, else: %{"missing_fields" => missing_fields}),
        if(full,
          do: nil,
          else:
            "artifact must be a non-smoke imp-gepa-replication input artifact with research_campaign evidence"
        )
      ],
      &is_nil/1
    )
  end

  defp rag_tool_agent_lane(dir, max_age_hours) do
    globs =
      case dir do
        nil ->
          [
            "tmp/rag-tool-agent/rag-tool-agent-parity-*.json",
            Path.join(
              Imp.BenchmarkTruth.Paths.runs("rag-tool-agent"),
              "rag-tool-agent-parity-*.json"
            )
          ]

        path ->
          [Path.join(path, "rag-tool-agent-parity-*.json")]
      end

    with {:ok, path} <- latest(globs, &valid_rag_tool_agent_candidate?/1),
         {:ok, artifact} <- read_artifact(path) do
      authority = rag_tool_agent_authority(artifact)
      passing = authority["provider_free_complete"]
      full = authority["full"]

      artifact_lane("rag_tool_agent", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing and full,
        scale: if(full, do: "full", else: "sample"),
        summary: %{
          "total" => get_in(artifact, ["summary", "total"]),
          "passing" => get_in(artifact, ["summary", "passing"]),
          "direct_comparisons" => get_in(artifact, ["summary", "direct_comparisons"]),
          "imp_only_or_deviation" => get_in(artifact, ["summary", "imp_only_or_deviation"]),
          "provider_free_contract_complete" =>
            get_in(artifact, ["summary", "provider_free_contract_complete"]) == true,
          "live_matched_behavior_complete" =>
            get_in(artifact, ["summary", "live_matched_behavior_complete"]) == true,
          "full_rag_tool_agent_parity" => full,
          "authority" => authority
        },
        limitation:
          if(full,
            do: nil,
            else:
              "RAG/tool/agent artifact is passing as a provider-free sample, but live/provider and broader trace/error slices are still required."
          )
      )
    else
      _ ->
        missing_lane(
          "rag_tool_agent",
          "no rag-tool-agent-parity artifact found in #{Enum.join(globs, ", ")}"
        )
    end
  end

  defp rag_tool_agent_authority(artifact) do
    rows = if is_list(artifact["rows"]), do: artifact["rows"], else: []
    rows_by_id = Map.new(rows, &{&1["id"], &1})
    row_ids = Map.keys(rows_by_id) |> MapSet.new()
    provider_free_ids = MapSet.new(@rag_tool_agent_provider_free_ids)
    live_ids = MapSet.new(@rag_tool_agent_live_ids)
    summary = if is_map(artifact["summary"]), do: artifact["summary"], else: %{}

    source_bound =
      try do
        Mix.Tasks.Imp.Benchmark.RagToolAgent.validate_artifact!(artifact)
        true
      rescue
        _error -> false
      end

    rows_reconciled =
      length(rows) == MapSet.size(row_ids) and summary["total"] == length(rows) and
        summary["passing"] == Enum.count(rows, &(&1["passing"] == true)) and
        Enum.all?(rows, &(&1["passing"] == true)) and summary["all_passing"] == true

    provider_free_complete =
      source_bound and rows_reconciled and MapSet.subset?(provider_free_ids, row_ids) and
        Enum.all?(@rag_tool_agent_provider_free_ids, &(rows_by_id[&1]["passing"] == true))

    live_complete =
      MapSet.subset?(live_ids, row_ids) and
        Enum.all?(@rag_tool_agent_live_ids, &valid_live_rag_tool_agent_row?(rows_by_id[&1]))

    full =
      provider_free_complete and live_complete and
        summary["provider_free_contract_complete"] == true and
        summary["live_matched_behavior_complete"] == true and
        summary["full_rag_tool_agent_parity"] == true and
        summary["comparative_effectiveness_complete"] == true

    %{
      "rows_reconciled" => rows_reconciled,
      "source_bound" => source_bound,
      "provider_free_complete" => provider_free_complete,
      "live_complete" => live_complete,
      "full" => full
    }
  end

  defp valid_live_rag_tool_agent_row?(%{"id" => id, "imp" => imp, "dspy" => dspy}) do
    imp_evidence = imp["evidence"] || %{}
    dspy_evidence = dspy["evidence"] || %{}

    imp["passing"] == true and dspy["passing"] == true and
      imp_evidence["mode"] == "live" and dspy_evidence["mode"] == "live" and
      imp_evidence["provider"] == dspy_evidence["provider"] and
      imp_evidence["model_identity"] == dspy_evidence["model_identity"] and
      wire_api_family(imp_evidence["wire_api"]) == wire_api_family(dspy_evidence["wire_api"]) and
      imp_evidence["generation"] == dspy_evidence["generation"] and
      imp_evidence["prompt_contract"] == dspy_evidence["prompt_contract"] and
      imp_evidence["usage_complete"] == true and dspy_evidence["usage_complete"] == true and
      is_nil(imp_evidence["error"]) and is_nil(dspy_evidence["error"]) and
      valid_rag_tool_termination?(id, imp_evidence, dspy_evidence)
  end

  defp valid_live_rag_tool_agent_row?(_row), do: false

  defp valid_rag_tool_termination?("live_mcp_lookup_tool", imp, dspy),
    do: imp["termination_tool"] == "submit" and dspy["termination_tool"] == "finish"

  defp valid_rag_tool_termination?(_id, imp, dspy),
    do: is_nil(imp["termination_tool"]) and is_nil(dspy["termination_tool"])

  defp wire_api_family("anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("litellm_anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("google_generate_content"), do: "google_generate_content"
  defp wire_api_family("litellm_google_generate_content"), do: "google_generate_content"
  defp wire_api_family(value), do: value

  defp rlm_benchmark_lane(dir, max_age_hours) do
    with {:ok, path} <-
           latest(Path.join(dir, "rlm-benchmark-parity-*.json"), &valid_rlm_candidate?/1),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["summary", "all_passing"]) == true
      tier = artifact["evidence_tier"]
      protocol = Imp.BenchmarkTruth.RLMProtocol.evaluate(artifact)

      full =
        tier == "t3_paper_scale" and
          protocol["paper_protocol_complete"] == true

      blocking =
        protocol["checks"]
        |> Enum.reject(& &1["passing"])
        |> Enum.map(fn check ->
          %{
            "kind" => "rlm_t3_protocol_incomplete",
            "check" => check["id"],
            "message" => "RLM T3 mechanical check failed: #{check["id"]}"
          }
        end)

      artifact_lane("rlm_benchmark", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing and full,
        scale: if(full, do: "full", else: tier || "unknown"),
        summary: %{
          "total" => get_in(artifact, ["summary", "total"]),
          "passing" => get_in(artifact, ["summary", "passing"]),
          "approaches" => get_in(artifact, ["summary", "approaches"]),
          "evidence_tier" => tier,
          "paper_protocol_complete" => protocol["paper_protocol_complete"],
          "t3_gate_checks" => protocol["checks"],
          "full_rlm_benchmark_parity" => full
        },
        blocking_requirements: blocking,
        limitation:
          if(full,
            do: nil,
            else:
              "RLM evidence does not mechanically satisfy every T3 family, count, context, baseline, runtime, row-shape, and evidence condition."
          )
      )
    else
      _ -> missing_lane("rlm_benchmark", "no rlm-benchmark-parity artifact found in #{dir}")
    end
  end

  defp claims_gate(path, lanes, profile) do
    case read_claims(path, Map.keys(lanes)) do
      {:ok, claims} ->
        selected_claims = ReleaseProfile.select_claims(claims, profile)
        evaluated = Enum.map(selected_claims, &evaluate_claim(&1, lanes))
        canonical_inventory = canonical_claims_file?(path)

        blocking =
          Enum.filter(
            evaluated,
            &(&1["gate_policy"] == "blocking" and &1["evidence_state"] != "proven")
          )

        inventory_blockers =
          if canonical_inventory do
            []
          else
            [
              %{
                "kind" => "noncanonical_claims_inventory",
                "claim_id" => "claims_inventory",
                "statement" => "profile readiness uses the canonical public claims inventory",
                "missing_requirements" => ["claims_inventory.canonical"]
              }
            ]
          end

        blockers =
          inventory_blockers ++
            Enum.map(blocking, fn claim ->
              %{
                "kind" => "public_claim_blocked",
                "claim_id" => claim["id"],
                "statement" => claim["statement"],
                "missing_requirements" =>
                  claim
                  |> Map.get("requirements", [])
                  |> Enum.reject(&(&1["satisfied"] == true))
                  |> Enum.map(& &1["id"])
              }
            end)

        passing = canonical_inventory and blocking == []

        %{
          "status" => if(passing, do: "full", else: "failing"),
          "passing" => passing,
          "artifact" => %{
            "path" => path,
            "sha256" => file_sha256(path),
            "canonical" => canonical_inventory
          },
          "profile" => profile,
          "summary" => %{
            "total" => length(evaluated),
            "proven" => Enum.count(evaluated, &(&1["evidence_state"] == "proven")),
            "blocked" => length(blocking),
            "informational" => Enum.count(evaluated, &(&1["gate_policy"] == "informational"))
          },
          "claims" => evaluated,
          "blocking_requirements" => blockers,
          "limitation" =>
            cond do
              not canonical_inventory ->
                "Alternate claims inventories are diagnostic and cannot authorize profile readiness."

              blocking != [] ->
                "One or more release-blocking public claims lack fresh passing evidence."

              true ->
                nil
            end
        }

      {:error, reason} ->
        %{
          "status" => "missing",
          "passing" => false,
          "artifact" => nil,
          "summary" => %{"total" => 0, "proven" => 0, "blocked" => 1, "informational" => 0},
          "claims" => [],
          "blocking_requirements" => [
            %{
              "kind" => "public_claim_blocked",
              "claim_id" => "claims_inventory",
              "statement" => "machine-readable public claims inventory exists",
              "missing_requirements" => [inspect(reason)]
            }
          ],
          "limitation" => "No readable public claims inventory found at #{path}."
        }
    end
  end

  defp read_claims(path, known_lanes) do
    with :ok <- if(File.exists?(path), do: :ok, else: {:error, :missing_claims_file}),
         {:ok, artifact} <- read_artifact(path),
         2 <- artifact["schema_version"],
         claims when is_list(claims) <- artifact["claims"],
         true <- claims != [],
         true <- Enum.all?(claims, &valid_claim?(&1, known_lanes)),
         true <- unique_claim_ids?(claims),
         true <- unique_requirement_ids?(claims) do
      {:ok, claims}
    else
      {:error, :missing_claims_file} -> {:error, :missing_claims_file}
      nil -> {:error, :missing_claims_array}
      _other -> {:error, :invalid_claims_file}
    end
  end

  defp valid_claim?(claim, known_lanes) when is_map(claim) do
    is_binary(claim["id"]) and claim["claim_state"] in ~w(asserted target retired) and
      claim["target_rung"] in ~w(C0 C1 C2 C3 C4 C5) and
      claim["gate_policy"] in ~w(blocking informational) and is_binary(claim["release"]) and
      claim["release"] in known_claim_releases() and is_binary(claim["statement"]) and
      is_binary(claim["scope"]) and is_binary(claim["category"]) and
      is_binary(claim["claim_type"]) and is_binary(claim["comparison"]) and
      nonempty_string_list?(claim["surface"]) and nonempty_string_list?(claim["sources"]) and
      is_list(claim["requirements"]) and claim["requirements"] != [] and
      Enum.all?(claim["requirements"], fn requirement ->
        is_binary(requirement["id"]) and is_binary(requirement["lane"]) and
          requirement["evidence"] in ~w(passing full) and is_binary(requirement["kind"]) and
          is_binary(requirement["threshold"]) and
          (is_nil(known_lanes) or requirement["lane"] in known_lanes)
      end)
  end

  defp valid_claim?(_claim, _known_lanes), do: false

  defp unique_claim_ids?(claims) do
    ids = Enum.map(claims, & &1["id"])
    ids == Enum.uniq(ids)
  end

  defp unique_requirement_ids?(claims) do
    ids = claims |> Enum.flat_map(& &1["requirements"]) |> Enum.map(& &1["id"])
    ids == Enum.uniq(ids)
  end

  defp nonempty_string_list?(values),
    do: is_list(values) and values != [] and Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp known_claim_releases do
    ReleaseProfile.names()
    |> Enum.flat_map(&ReleaseProfile.fetch!(&1)["claim_releases"])
    |> Enum.uniq()
  end

  defp canonical_claims_file?(path),
    do: Path.expand(path) == Path.expand(@default_claims_file)

  defp evaluate_claim(claim, lanes) do
    requirements =
      claim
      |> Map.get("requirements", [])
      |> Enum.map(&evaluate_claim_requirement(&1, lanes))

    satisfied? = requirements != [] and Enum.all?(requirements, &(&1["satisfied"] == true))
    _gate_policy = Map.fetch!(claim, "gate_policy")

    claim
    |> Map.take([
      "id",
      "statement",
      "category",
      "surface",
      "claim_type",
      "comparison",
      "sources",
      "claim_state",
      "target_rung",
      "release",
      "scope",
      "limitations",
      "gate_policy"
    ])
    |> Map.put(
      "evidence_state",
      cond do
        satisfied? -> "proven"
        Enum.any?(requirements, &(&1["satisfied"] == true)) -> "partial"
        true -> "missing"
      end
    )
    |> Map.put("requirements", requirements)
  end

  defp evaluate_claim_requirement(%{"lane" => lane_id} = requirement, lanes) do
    lane = lanes[lane_id]
    evidence = requirement["evidence"] || "full"

    satisfied? =
      case {lane, evidence} do
        {%{"full_evidence" => true}, "full"} -> true
        {%{"passing" => true, "fresh" => true}, "passing"} -> true
        _other -> false
      end

    requirement
    |> Map.take(["id", "kind", "lane", "evidence", "threshold", "notes"])
    |> Map.put("evidence", evidence)
    |> Map.put("satisfied", satisfied?)
    |> Map.put("lane_status", lane && lane["status"])
    |> Map.put("lane_fresh", lane && lane["fresh"])
    |> Map.put("lane_full_evidence", lane && lane["full_evidence"])
    |> Map.put("lane_limitation", lane && lane["limitation"])
    |> Map.put("artifact", lane && lane["artifact"])
    |> Map.put("blocking_requirements", (lane && lane["blocking_requirements"]) || [])
  end

  defp evaluate_claim_requirement(requirement, _lanes) do
    requirement
    |> Map.take(["id", "kind", "evidence", "threshold", "notes"])
    |> Map.put("satisfied", false)
    |> Map.put("blocking_requirements", ["claim requirement does not name a dashboard lane"])
  end

  defp row_names_by_status(artifact, status) do
    artifact
    |> Map.get("rows", [])
    |> Enum.filter(&(&1["comparison_status"] == status))
    |> Enum.map(& &1["optimizer"])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp non_direct_row_names(artifact) do
    artifact
    |> Map.get("rows", [])
    |> Enum.reject(&(&1["comparison_status"] == "direct"))
    |> Enum.map(& &1["optimizer"])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp live_matched_model_lane(matrix_dir, campaign_dir, max_age_hours) do
    matrix_globs = [
      Path.join(matrix_dir, "live-matched-model-matrix-*.json"),
      Path.join(campaign_dir, "live-matched-model-matrix-*.json")
    ]

    case live_matrix_lane(matrix_globs, max_age_hours) do
      {:ok, lane} -> lane
      {:error, _reason} -> live_campaign_lane(campaign_dir, max_age_hours)
    end
  end

  defp live_matrix_lane(globs, max_age_hours) do
    with {:ok, path} <- latest(globs, &valid_live_matrix_candidate?/1),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["summary", "matrix_complete"]) == true

      {:ok,
       artifact_lane("live_matched_model", path, artifact, max_age_hours,
         passing: passing,
         full_evidence: passing,
         scale: if(passing, do: "full", else: "sample"),
         summary: %{
           "matrix_complete" => passing,
           "models" => get_in(artifact, ["summary", "models"]),
           "full_parity_models" => get_in(artifact, ["summary", "full_parity_models"]),
           "required_lanes" => get_in(artifact, ["summary", "required_lanes"]),
           "blocking_requirements" => live_matrix_blocking_requirements(artifact),
           "prompt_contract" => get_in(artifact, ["summary", "prompt_contract"]),
           "execution" => get_in(artifact, ["summary", "execution"]),
           "imp_instrumentation" => get_in(artifact, ["summary", "imp_instrumentation"]),
           "runtime_shape" => get_in(artifact, ["summary", "runtime_shape"]),
           "disagreements" => get_in(artifact, ["summary", "disagreements"]),
           "latency" => get_in(artifact, ["summary", "latency"]),
           "transport" => get_in(artifact, ["summary", "transport"])
         },
         blocking_requirements: live_matrix_blocking_requirements(artifact),
         limitation:
           if(passing,
             do: nil,
             else:
               "Live matched-model matrix is present but does not yet have fresh full-evidence current low-cost, frontier, and historical/research lanes."
           )
       )}
    else
      _ -> {:error, :missing_matrix}
    end
  end

  defp live_campaign_lane(dir, max_age_hours) do
    with {:ok, path} <-
           latest(
             Path.join(dir, "imp-dspy-parity-campaign-*.json"),
             &valid_live_campaign_candidate?/1
           ),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["parity", "full_parity"]) == true

      artifact_lane("live_matched_model", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: if(get_in(artifact, ["coverage", "full"]), do: "full", else: "smoke"),
        summary: %{
          "provider" => artifact["provider"],
          "model" => artifact["model"],
          "coverage" => artifact["coverage"],
          "parity" => artifact["parity"],
          "blocking_requirements" => live_campaign_blocking_requirements(artifact),
          "imp_instrumentation" => campaign_instrumentation_summary(artifact["tasks"] || []),
          "runtime_shape" => campaign_runtime_shape_summary(artifact["tasks"] || [])
        },
        blocking_requirements: live_campaign_blocking_requirements(artifact),
        limitation:
          if(passing,
            do: nil,
            else: "Latest campaign aggregate does not prove full matched-model parity."
          )
      )
    else
      _ ->
        missing_lane(
          "live_matched_model",
          "no live-matched-model matrix or imp-dspy-parity-campaign artifact found"
        )
    end
  end

  defp artifact_lane(id, path, artifact, max_age_hours, opts) do
    freshness = Keyword.get(opts, :freshness, :age)
    full_freshness = Keyword.get(opts, :full_freshness, freshness)
    status_freshness = Keyword.get(opts, :status_freshness, freshness)
    fresh = fresh?(artifact, path, max_age_hours, freshness)
    full_fresh = fresh?(artifact, path, max_age_hours, full_freshness)
    status_fresh = fresh?(artifact, path, max_age_hours, status_freshness)
    passing = Keyword.fetch!(opts, :passing)
    full_evidence = Keyword.fetch!(opts, :full_evidence) and full_fresh
    scale = Keyword.fetch!(opts, :scale)
    candidate_eligibility = candidate_eligibility(artifact, path, max_age_hours, freshness)

    %{
      "id" => id,
      "status" => status(passing, full_evidence, scale, status_fresh),
      "passing" => passing,
      "fresh" => fresh,
      "candidate_eligibility" => candidate_eligibility,
      "full_evidence" => full_evidence,
      "scale" => scale,
      "artifact" => %{
        "path" => path,
        "sha256" => file_sha256(path),
        "generated_at" => artifact["generated_at"],
        "git_sha" => artifact["git_sha"]
      },
      "summary" => Keyword.fetch!(opts, :summary),
      "limitation" => Keyword.get(opts, :limitation),
      "blocking_requirements" => Keyword.get(opts, :blocking_requirements, [])
    }
  end

  defp missing_lane(id, reason) do
    %{
      "id" => id,
      "status" => "missing",
      "passing" => false,
      "fresh" => false,
      "candidate_eligibility" => %{
        "policy" => "missing",
        "eligible" => false,
        "recency_valid" => false,
        "source_compatible" => false,
        "rejection_reasons" => ["artifact_missing"]
      },
      "full_evidence" => false,
      "scale" => "missing",
      "artifact" => nil,
      "summary" => %{},
      "limitation" => reason,
      "blocking_requirements" => [reason]
    }
  end

  defp live_matrix_blocking_requirements(artifact) do
    summary = artifact["summary"] || %{}
    required_lanes = summary["required_lanes"] || %{}

    lane_requirements =
      required_lanes
      |> Enum.flat_map(fn {lane, status} ->
        cond do
          status["satisfied"] == true ->
            []

          status["present"] == true ->
            [
              %{
                "kind" => "live_lane_full_evidence",
                "lane" => lane,
                "status" => status["best_status"],
                "models" => status["models"] || [],
                "best_model" => status["best_model"],
                "policy" => status["policy"],
                "parity" => status["best_parity"],
                "proof" => status["best_proof"],
                "coverage" => status["coverage"],
                "cost" => status["cost"],
                "message" =>
                  "#{lane} is present but does not yet satisfy its live release-evidence policy."
              }
            ]

          true ->
            [
              %{
                "kind" => "live_lane_missing",
                "lane" => lane,
                "status" => status["best_status"] || "missing",
                "models" => status["models"] || [],
                "best_model" => status["best_model"],
                "policy" => status["policy"],
                "coverage" => status["coverage"],
                "cost" => status["cost"],
                "message" => "#{lane} is missing from the live matched-model matrix."
              }
            ]
        end
      end)

    instrumentation_requirements =
      []
      |> maybe_add_requirement(
        latency_failures(artifact) != [],
        %{
          "kind" => "live_latency_parity_false",
          "models" => Enum.map(latency_failures(artifact), & &1["model"]),
          "failures" =>
            Enum.map(latency_failures(artifact), fn model ->
              %{
                "model" => model["model"],
                "lane_tags" => model["lane_tags"],
                "latency" => model["latency"],
                "parity" => model["parity"],
                "transport" => model["transport"],
                "artifact" => model["artifact"]
              }
            end),
          "message" =>
            "One or more selected live model artifacts fail latency parity; inspect latency and Imp transport metadata before claiming performance parity."
        }
      )
      |> maybe_add_requirement(
        execution_failures(artifact) != [],
        %{
          "kind" => "live_max_concurrency_inconsistent",
          "failures" =>
            Enum.map(execution_failures(artifact), fn model ->
              %{
                "model" => model["model"],
                "lane_tags" => model["lane_tags"],
                "execution" => model["execution"],
                "proof" =>
                  Map.take(model["proof"] || %{}, [
                    "max_concurrency_consistent",
                    "max_concurrency",
                    "max_concurrency_values"
                  ]),
                "artifact" => model["artifact"]
              }
            end),
          "execution" => summary["execution"],
          "message" =>
            "One or more selected live model artifacts lack a single consistent max_concurrency setting; rerun or reaggregate with matched concurrency before claiming live parity."
        }
      )
      |> maybe_add_requirement(
        prompt_contract_failures(artifact) != [],
        %{
          "kind" => "prompt_contract_incomplete",
          "failures" => prompt_contract_failures(artifact),
          "prompt_contract" => summary["prompt_contract"],
          "message" =>
            "Live matched-model release candidates do not all use the current prompt/signature contract."
        }
      )
      |> maybe_add_requirement(
        get_in(summary, ["imp_instrumentation", "complete"]) != true,
        %{
          "kind" => "imp_instrumentation_incomplete",
          "message" => "Imp live runtime instrumentation is not complete for every covered model."
        }
      )
      |> maybe_add_requirement(
        get_in(summary, ["runtime_shape", "complete"]) != true,
        %{
          "kind" => "runtime_shape_incomplete",
          "runtime_shape" => summary["runtime_shape"],
          "message" =>
            "Runtime shape evidence is not complete for every covered model with comparable Imp and DSPy instrumentation."
        }
      )

    lane_requirements ++ instrumentation_requirements
  end

  defp latency_failures(artifact) do
    artifact
    |> Map.get("models", [])
    |> Enum.filter(&(get_in(&1, ["parity", "latency_parity"]) == false))
  end

  defp execution_failures(artifact) do
    artifact
    |> Map.get("models", [])
    |> Enum.filter(&(get_in(&1, ["proof", "max_concurrency_consistent"]) != true))
  end

  defp prompt_contract_failures(artifact) do
    required = get_in(artifact, ["summary", "required_lanes"]) || %{}
    by_model = Map.new(artifact["models"] || [], &{&1["model"], &1})

    required
    |> Enum.flat_map(fn {_lane, status} ->
      cond do
        get_in(status, ["availability", "status"]) == "explicit_unavailable" ->
          []

        status["satisfied"] == true and is_binary(status["best_model"]) ->
          [status["best_model"]]

        status["satisfied"] == true ->
          status["models"] || []

        true ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn model_name ->
      model = by_model[model_name] || %{"model" => model_name}

      if get_in(model, ["proof", "prompt_contract_current"]) == true do
        []
      else
        [
          %{
            "model" => model_name,
            "lane_tags" => model["lane_tags"] || [],
            "prompt_contract" => get_in(model, ["proof", "prompt_contract"]),
            "expected_prompt_contract" => get_in(model, ["proof", "expected_prompt_contract"]),
            "artifact" => model["artifact"]
          }
        ]
      end
    end)
  end

  defp live_campaign_blocking_requirements(artifact) do
    []
    |> maybe_add_requirement(
      get_in(artifact, ["coverage", "full"]) != true,
      %{
        "kind" => "campaign_coverage_incomplete",
        "coverage" => artifact["coverage"],
        "message" =>
          "Latest live campaign aggregate does not cover the full expected benchmark row set."
      }
    )
    |> maybe_add_requirement(
      get_in(artifact, ["parity", "full_parity"]) != true,
      %{
        "kind" => "campaign_full_parity_false",
        "parity" => artifact["parity"],
        "message" => "Latest live campaign aggregate does not satisfy full parity thresholds."
      }
    )
  end

  defp maybe_add_requirement(requirements, true, requirement), do: requirements ++ [requirement]
  defp maybe_add_requirement(requirements, false, _requirement), do: requirements

  defp status(false, _full_evidence, _scale, _fresh), do: "failing"
  defp status(true, false, _scale, false), do: "stale"
  defp status(true, true, "full", true), do: "full"
  defp status(true, _full_evidence, scale, true) when scale in ["smoke", "sample"], do: scale
  defp status(true, _full_evidence, _scale, true), do: "passing"

  defp latest_eligible(glob, policy, _max_age_hours, validator) do
    candidates =
      glob
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case read_artifact(path) do
          {:ok, artifact} ->
            if valid_candidate?(validator, artifact), do: [{path, artifact}], else: []

          {:error, _reason} ->
            []
        end
      end)

    eligible =
      Enum.filter(candidates, fn {path, artifact} ->
        policy_candidate?(artifact, path, policy)
      end)

    choose_latest_candidate(eligible)
  end

  defp latest(glob, validator) when is_binary(glob), do: latest([glob], validator)

  defp latest(globs, validator) do
    candidates =
      globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn path ->
        case read_artifact(path) do
          {:ok, artifact} ->
            if valid_candidate?(validator, artifact), do: [{path, artifact}], else: []

          {:error, _reason} ->
            []
        end
      end)

    choose_latest_candidate(candidates)
  end

  defp valid_candidate?(validator, artifact) do
    validator.(artifact) == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_golden_trace_candidate?(%{"summary" => summary}) when is_map(summary) do
    is_boolean(summary["all_cases_passing"]) and
      is_map(summary["imp_semantic_checks"]) and
      is_boolean(summary["imp_semantic_checks"]["all_passing"])
  end

  defp valid_golden_trace_candidate?(_artifact), do: false

  defp valid_gate_candidate?(%{"summary" => summary} = artifact, id, expected_mix_task)
       when is_map(summary) do
    artifact["gate"] == id and summary["mix_task"] == expected_mix_task and
      is_boolean(summary["passing"])
  end

  defp valid_gate_candidate?(_artifact, _id, _expected_mix_task), do: false

  defp valid_overhead_candidate?(artifact), do: OverheadPolicy.artifact_valid?(artifact)

  defp valid_instruction_optimizer_candidate?(%{"summary" => summary, "dspy" => dspy})
       when is_map(summary) and is_map(dspy) do
    is_boolean(summary["structural_contract_complete"]) and
      is_integer(summary["required_cases"]) and is_integer(summary["required_passing"])
  end

  defp valid_instruction_optimizer_candidate?(_artifact), do: false

  defp valid_optimizer_lift_candidate?(%{"summary" => summary, "rows" => rows})
       when is_map(summary) and is_list(rows),
       do: is_boolean(summary["all_passing"])

  defp valid_optimizer_lift_candidate?(_artifact), do: false

  defp valid_gepa_candidate?(%{"summary" => summary, "rows" => rows})
       when is_map(summary) and is_list(rows),
       do: is_boolean(summary["all_passing"])

  defp valid_gepa_candidate?(_artifact), do: false

  defp valid_optimize_anything_candidate?(%{"summary" => summary, "rows" => rows})
       when is_map(summary) and is_list(rows),
       do: is_boolean(summary["all_passing"])

  defp valid_optimize_anything_candidate?(_artifact), do: false

  defp valid_rag_tool_agent_candidate?(%{"summary" => summary, "rows" => rows})
       when is_map(summary) and is_list(rows),
       do: is_boolean(summary["all_passing"])

  defp valid_rag_tool_agent_candidate?(_artifact), do: false

  defp valid_rlm_candidate?(%{"summary" => summary, "evidence_tier" => tier})
       when is_map(summary) and is_binary(tier),
       do: is_boolean(summary["all_passing"])

  defp valid_rlm_candidate?(_artifact), do: false

  defp valid_live_matrix_candidate?(%{"summary" => summary}) when is_map(summary),
    do: is_boolean(summary["matrix_complete"])

  defp valid_live_matrix_candidate?(_artifact), do: false

  defp valid_live_campaign_candidate?(%{"coverage" => coverage, "parity" => parity})
       when is_map(coverage) and is_map(parity),
       do: is_boolean(coverage["full"]) and is_boolean(parity["full_parity"])

  defp valid_live_campaign_candidate?(_artifact), do: false

  defp choose_latest_candidate([]), do: {:error, :missing}

  defp choose_latest_candidate(candidates) do
    {path, _artifact} =
      Enum.max_by(candidates, fn {path, artifact} ->
        {artifact_timestamp(artifact), mtime_unix!(path)}
      end)

    {:ok, path}
  end

  defp read_artifact(path) do
    {:ok, path |> File.read!() |> Jason.decode!()}
  rescue
    _error -> {:error, :invalid_json}
  end

  defp fresh?(artifact, path, max_age_hours, freshness)

  defp fresh?(artifact, _path, _max_age_hours, :source_revision),
    do: current_git_sha_bound?(artifact)

  defp fresh?(artifact, path, max_age_hours, :age),
    do: fresh_by_age?(artifact, path, max_age_hours)

  defp fresh?(artifact, path, max_age_hours, :source_and_age),
    do: current_git_sha_bound?(artifact) and fresh_by_age?(artifact, path, max_age_hours)

  defp policy_candidate?(artifact, _path, :source_revision),
    do: current_git_sha_bound?(artifact)

  defp policy_candidate?(artifact, _path, :age), do: valid_artifact_time?(artifact)

  defp policy_candidate?(artifact, _path, :source_and_age),
    do: current_git_sha_bound?(artifact) and valid_artifact_time?(artifact)

  defp candidate_eligibility(artifact, path, max_age_hours, policy) do
    recency_valid = fresh_by_age?(artifact, path, max_age_hours)
    source_compatible = current_git_sha_bound?(artifact)
    eligible = fresh?(artifact, path, max_age_hours, policy)

    rejection_reasons =
      []
      |> maybe_reject(policy in [:age, :source_and_age] and not recency_valid, "recency_invalid")
      |> maybe_reject(
        policy in [:source_revision, :source_and_age] and not source_compatible,
        "source_revision_mismatch"
      )

    %{
      "policy" => Atom.to_string(policy),
      "eligible" => eligible,
      "recency_valid" => recency_valid,
      "source_compatible" => source_compatible,
      "max_age_hours" => max_age_hours,
      "rejection_reasons" => rejection_reasons
    }
  end

  defp maybe_reject(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reject(reasons, false, _reason), do: reasons

  defp fresh_by_age?(artifact, _path, max_age_hours) do
    case artifact_generated_at(artifact) do
      {:ok, datetime} ->
        age_seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)
        age_seconds >= -300 and age_seconds <= max_age_hours * 60 * 60

      :error ->
        false
    end
  end

  defp valid_artifact_time?(artifact) do
    case artifact_generated_at(artifact) do
      {:ok, datetime} -> DateTime.diff(DateTime.utc_now(), datetime, :second) >= -300
      :error -> false
    end
  end

  defp current_git_sha_bound?(artifact) do
    case git_sha() do
      current when is_binary(current) -> artifact["git_sha"] == current
      _other -> false
    end
  end

  defp artifact_generated_at(artifact) do
    case artifact["generated_at"] && DateTime.from_iso8601(artifact["generated_at"]) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> :error
    end
  end

  defp artifact_timestamp(artifact) do
    case artifact_generated_at(artifact) do
      {:ok, datetime} -> DateTime.to_unix(datetime, :microsecond)
      :error -> 0
    end
  end

  defp mtime_unix!(path) do
    {:ok, stat} = File.stat(path, time: :posix)
    stat.mtime
  end

  defp worst_ratio([]), do: nil

  defp worst_ratio(cases) do
    cases
    |> Enum.map(fn row ->
      row["median_ratio_imp_over_dspy"] ||
        get_in(row, ["measurements", "median_ratio_imp_over_dspy"])
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ratios -> Enum.max(ratios)
    end
  end

  defp campaign_instrumentation_summary(tasks) do
    summaries =
      tasks
      |> Enum.map(&(&1["imp_instrumentation"] || %{}))
      |> Enum.reject(&(&1 == %{}))

    shares =
      summaries
      |> Enum.map(&get_in(&1, ["lm_duration_share", "total"]))
      |> Enum.filter(&is_number/1)

    local_overhead_means =
      summaries
      |> Enum.map(&get_in(&1, ["local_overhead_ms", "mean_ms"]))
      |> Enum.filter(&is_number/1)

    %{
      "instrumented_rows" =>
        summaries
        |> Enum.map(&(get_in(&1, ["coverage", "instrumented_rows"]) || 0))
        |> Enum.sum(),
      "total_rows" =>
        summaries
        |> Enum.map(&(get_in(&1, ["coverage", "total_rows"]) || 0))
        |> Enum.sum(),
      "complete" =>
        summaries != [] and Enum.all?(summaries, &(get_in(&1, ["coverage", "complete"]) == true)),
      "mean_lm_duration_share" => average(shares),
      "max_local_overhead_mean_ms" => Enum.max(local_overhead_means, fn -> nil end),
      "json_fallbacks" => Enum.sum(Enum.map(summaries, &(&1["json_fallbacks"] || 0))),
      "parse_retries" => Enum.sum(Enum.map(summaries, &(&1["parse_retries"] || 0)))
    }
  end

  defp campaign_runtime_shape_summary(tasks) do
    summaries =
      tasks
      |> Enum.map(&(&1["runtime_shape"] || %{}))
      |> Enum.reject(&(&1 == %{}))

    message_ratios =
      summaries
      |> Enum.map(& &1["message_chars_ratio_imp_over_dspy_mean"])
      |> Enum.filter(&is_number/1)

    raw_ratios =
      summaries
      |> Enum.map(& &1["raw_chars_ratio_imp_over_dspy_mean"])
      |> Enum.filter(&is_number/1)

    coverages =
      summaries
      |> Enum.map(&(&1["coverage"] || %{}))
      |> Enum.reject(&(&1 == %{}))

    %{
      "complete" =>
        summaries != [] and length(message_ratios) == length(summaries) and
          length(raw_ratios) == length(summaries) and
          Enum.all?(summaries, &runtime_shape_complete?/1),
      "tasks_with_runtime_shape" => length(summaries),
      "coverage" => %{
        "total_rows" => Enum.sum(Enum.map(coverages, &(&1["total_rows"] || 0))),
        "message_chars_comparable_rows" =>
          Enum.sum(Enum.map(coverages, &(&1["message_chars_comparable_rows"] || 0))),
        "raw_chars_comparable_rows" =>
          Enum.sum(Enum.map(coverages, &(&1["raw_chars_comparable_rows"] || 0))),
        "complete" => coverages != [] and Enum.all?(coverages, &(&1["complete"] == true))
      },
      "mean_message_chars_ratio_imp_over_dspy" => average(message_ratios),
      "mean_raw_chars_ratio_imp_over_dspy" => average(raw_ratios)
    }
  end

  defp runtime_shape_complete?(%{"coverage" => %{"complete" => complete}}), do: complete == true
  defp runtime_shape_complete?(_summary), do: false

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)

  defp file_sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end

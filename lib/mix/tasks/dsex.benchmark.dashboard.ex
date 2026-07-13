defmodule Mix.Tasks.Dsex.Benchmark.Dashboard do
  @moduledoc """
  Aggregate DSEx-vs-DSPy validation evidence into one dashboard artifact.

      mix dsex.benchmark.dashboard

  By default the task writes a dashboard even when lanes are missing. Use
  `--require-full` for the release gate that refuses full parity claims unless
  every required lane is present and passing at full-evidence scale.

  Public claims are evaluated from `benchmarks/claims.json` by default. Pass
  `--claims-file path/to/claims.json` to evaluate a different inventory.

  Select `--profile v0.1`, `--profile telos`, or `--profile research` to choose
  the release claim scope. The default is the conservative `telos` profile.
  """

  use Mix.Task

  alias DSEx.BenchmarkTruth.ReleaseProfile

  @shortdoc "Aggregate parity and performance evidence into a dashboard"

  @default_results_dir "benchmarks/results"
  @failure_case_ids ~w(
    task_cancellation_releases_admission
    task_timeout_is_explicit_and_terminal
    async_concurrency_is_bounded
    partial_stream_failure_is_terminal
    training_retry_and_idempotency_are_bounded
    mipro_v2_durable_resume_and_tamper
    simba_durable_resume_and_tamper
  )
  @failure_live_ids ~w(
    provider_retry_timeout_idempotency_live
    training_retrieval_tool_agent_recovery_live
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
          results_dir: :string,
          gate_dir: :string,
          claims_file: :string,
          out: :string,
          max_age_hours: :integer,
          profile: :string,
          require_full: :boolean
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
    out_path = Path.join(out_dir, "parity-dashboard-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(dashboard, pretty: true) <> "\n")

    Mix.shell().info("parity dashboard: #{out_path}")
    Mix.shell().info("release profile: #{dashboard["profile"]["id"]}")
    Mix.shell().info("full parity: #{dashboard["full_parity"]}")
    Mix.shell().info("performance claim supported: #{dashboard["performance_claim_supported"]}")

    if Keyword.get(opts, :require_full, false) and not dashboard["full_parity"] do
      Mix.raise(release_gate_failure_message(dashboard, out_path))
    end
  end

  defp dashboard(opts) do
    max_age_hours = Keyword.get(opts, :max_age_hours, 24)
    profile = opts |> Keyword.fetch!(:profile) |> ReleaseProfile.fetch!()
    claims_path = Keyword.get(opts, :claims_file, "benchmarks/claims.json")

    instruction_optimizer_contract =
      instruction_optimizer_contract_lane(
        Keyword.get(opts, :instruction_optimizer_dir, "tmp/instruction-optimizer-contract"),
        max_age_hours
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
          "package.check"
        ),
      "livebook_execute" =>
        gate_lane(
          "livebook_execute",
          Keyword.get(opts, :gate_dir, "tmp/gate-evidence"),
          max_age_hours,
          "livebook.execute.check"
        ),
      "live_provider_smoke" =>
        gate_lane(
          "live_provider_smoke",
          Keyword.get(opts, :gate_dir, "tmp/gate-evidence"),
          max_age_hours,
          "live.check"
        ),
      "protocol_gates" =>
        gate_lane(
          "protocol_gates",
          Keyword.get(opts, :gate_dir, "tmp/gate-evidence"),
          max_age_hours,
          "protocol.check"
        ),
      "failure_recovery" =>
        failure_recovery_lane(
          Keyword.get(opts, :failure_campaign_dir, "tmp/failure-campaign"),
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
      "gepa_replication" =>
        gepa_replication_lane(
          Keyword.get(opts, :gepa_dir, "tmp/gepa-replication"),
          max_age_hours
        ),
      "optimize_anything" =>
        optimize_anything_lane(
          Keyword.get(opts, :optimize_anything_dir, "benchmarks/results"),
          max_age_hours
        ),
      "rag_tool_agent" =>
        rag_tool_agent_lane(
          Keyword.get(opts, :rag_tool_agent_dir, "tmp/rag-tool-agent"),
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

    required = profile_lane_requirements(claims_path, profile)
    claims = claims_gate(claims_path, lanes, profile)
    gate_checks = release_gate_checks(required, lanes, claims)
    full_parity = Enum.all?(gate_checks, &(&1["passing"] == true))
    performance_supported = get_in(lanes, ["provider_free_overhead", "passing"]) == true

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "max_age_hours" => max_age_hours,
      "profile" => profile,
      "required_lanes" => Enum.map(required, & &1["lane"]),
      "required_lane_requirements" => required,
      "full_parity" => full_parity,
      "performance_claim_supported" => performance_supported,
      "release_gate" => %{
        "passing" => full_parity,
        "checks" => gate_checks,
        "blocking_lanes" =>
          gate_checks
          |> Enum.reject(& &1["passing"])
          |> Enum.map(& &1["lane"]),
        "note" =>
          "Full parity requires every required lane to be fresh, passing, and backed by full-evidence artifacts."
      },
      "claims" => claims,
      "summary" => %{
        "passing_lanes" => Enum.count(lanes, fn {_id, lane} -> lane["passing"] end),
        "full_evidence_lanes" => Enum.count(lanes, fn {_id, lane} -> lane["full_evidence"] end),
        "total_lanes" => map_size(lanes),
        "public_claims" => claims["summary"],
        "note" =>
          "Full parity is true only when all required lanes pass with full-evidence artifacts. Passing smoke or deterministic slices are preserved but cannot authorize full parity claims."
      },
      "lanes" => lanes
    }
  end

  defp results_dir(opts), do: Keyword.get(opts, :results_dir, @default_results_dir)

  defp profile_lane_requirements(path, profile) do
    case read_claims(path) do
      {:ok, claims} -> ReleaseProfile.lane_requirements(claims, profile)
      {:error, _reason} -> []
    end
  end

  defp release_gate_checks(required, lanes, claims) do
    lane_checks =
      Enum.map(required, fn requirement ->
        lane_id = requirement["lane"]
        lane = Map.fetch!(lanes, lane_id)
        evidence = requirement["evidence"]

        passing =
          lane["passing"] == true and lane["fresh"] == true and
            (evidence == "passing" or lane["full_evidence"] == true)

        %{
          "lane" => lane_id,
          "status" => lane["status"],
          "passing" => passing,
          "fresh" => lane["fresh"],
          "full_evidence" => lane["full_evidence"],
          "required_evidence" => evidence,
          "claim_ids" => requirement["claim_ids"],
          "requirement_ids" => requirement["requirement_ids"],
          "limitation" => lane["limitation"],
          "blocking_requirements" => lane["blocking_requirements"] || []
        }
      end)

    lane_checks ++
      [
        %{
          "lane" => "public_claims",
          "status" => claims["status"],
          "passing" => claims["passing"] == true,
          "fresh" => true,
          "full_evidence" => claims["passing"] == true,
          "limitation" => claims["limitation"],
          "blocking_requirements" => claims["blocking_requirements"] || []
        }
      ]
  end

  defp release_gate_failure_message(dashboard, out_path) do
    blocking =
      dashboard
      |> get_in(["release_gate", "checks"])
      |> List.wrap()
      |> Enum.reject(& &1["passing"])
      |> Enum.flat_map(&blocking_lines/1)

    """
    full parity release gate failed; inspect #{out_path}
    blocking requirements:
    #{Enum.map_join(blocking, "\n", &"- #{&1}")}
    """
    |> String.trim()
  end

  defp blocking_lines(%{"lane" => lane, "blocking_requirements" => requirements})
       when is_list(requirements) and requirements != [] do
    Enum.map(requirements, &format_blocking_requirement(lane, &1))
  end

  defp blocking_lines(%{"lane" => lane, "limitation" => limitation}) when is_binary(limitation),
    do: ["#{lane}: #{limitation}"]

  defp blocking_lines(%{"lane" => lane, "status" => status}),
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
      |> Enum.find_value(&get_in(&1, ["latency", "latency_ratio_dsex_over_dspy"]))

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
    with {:ok, path} <- latest(Path.join(dir, "golden-trace-parity-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      passing =
        get_in(artifact, ["summary", "all_cases_passing"]) == true and
          get_in(artifact, ["summary", "dsex_semantic_checks", "all_passing"]) == true

      artifact_lane("golden_trace", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
        summary: %{
          "cases" => get_in(artifact, ["summary", "total"]),
          "passing_cases" => get_in(artifact, ["summary", "passing"]),
          "prediction_parity" => get_in(artifact, ["summary", "prediction_parity"]),
          "tool_trace_parity" => get_in(artifact, ["summary", "tool_trace_parity"]),
          "semantic_checks" => get_in(artifact, ["summary", "dsex_semantic_checks"])
        },
        limitation:
          "Golden trace is passing for the current fixture corpus. Byte-identical prompt-template parity is intentionally not asserted; normalized semantic parity and retained message histories are the release evidence."
      )
    else
      _ -> missing_lane("golden_trace", "no golden-trace-parity artifact found in #{dir}")
    end
  end

  defp gate_lane(id, dir, max_age_hours, expected_mix_task) do
    with {:ok, path} <- latest(Path.join(dir, "gate-evidence-#{id}-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      passing =
        artifact["gate"] == id and
          get_in(artifact, ["summary", "mix_task"]) == expected_mix_task and
          get_in(artifact, ["summary", "passing"]) == true

      artifact_lane(id, path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
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
          "no #{id} source-checkout gate evidence artifact found in #{dir}; run mix dsex.gate_evidence --gate #{id} --mix-task #{expected_mix_task}"
        )
    end
  end

  defp failure_recovery_lane(dir, max_age_hours) do
    with {:ok, path} <- latest(Path.join(dir, "failure-campaign-*.json")),
         {:ok, artifact} <- read_verified_failure_artifact(path) do
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
    {:ok, DSEx.BenchmarkTruth.ArtifactFile.read_run_json!(path)}
  rescue
    error -> {:error, {:unverifiable, path, Exception.message(error)}}
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
      artifact["schema_version"] == 2 and artifact["runner"] == "dsex-failure-campaign" and
        artifact["evidence_tier"] == "t0_deterministic_failure_recovery"

    deterministic_complete =
      envelope_current and valid_case_ids == expected_case_ids and runtime_complete and
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
          outcome["duration_ms"] >= 0 and is_map(outcome["evidence"])
      end)
  end

  defp valid_failure_runtime?(%{"leaks" => leaks, "after" => after_snapshot})
       when is_map(leaks) and is_map(after_snapshot) do
    expected_leaks =
      ~w(admission_active admission_queued added_linked_tasks added_unlinked_tasks)

    MapSet.new(Map.keys(leaks)) == MapSet.new(expected_leaks) and
      Enum.all?(Map.values(leaks), &(&1 == 0)) and
      get_in(after_snapshot, ["admission", "active"]) == 0 and
      get_in(after_snapshot, ["admission", "queued"]) == 0 and
      non_negative_integer?(after_snapshot["linked_tasks"]) and
      non_negative_integer?(after_snapshot["unlinked_tasks"])
  end

  defp valid_failure_runtime?(_runtime), do: false

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
      Enum.all?(checks, &(is_binary(&1["id"]) and &1["passing"] == true)) and
      get_in(row, ["runtime", "leak_free"]) == true and
      zero_leaks?(get_in(row, ["runtime", "leaks"]))
  end

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
    with {:ok, path} <- latest(Path.join(dir, "overhead-parity-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["summary", "all_passing"]) == true

      artifact_lane("provider_free_overhead", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
        summary: %{
          "cases" => get_in(artifact, ["summary", "total"]),
          "passing_cases" => get_in(artifact, ["summary", "passing"]),
          "max_ratio" => artifact["max_ratio"],
          "worst_ratio" => worst_ratio(artifact["cases"] || [])
        },
        limitation:
          "Performance claims must name the covered path and artifact; the dashboard does not authorize blanket speed claims."
      )
    else
      _ -> missing_lane("provider_free_overhead", "no overhead-parity artifact found in #{dir}")
    end
  end

  defp instruction_optimizer_contract_lane(dir, max_age_hours) do
    with {:ok, path} <- latest(Path.join(dir, "instruction-optimizer-contract-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      authority = instruction_optimizer_authority(artifact)
      required_cases = get_in(artifact, ["summary", "required_cases"])
      required_passing = get_in(artifact, ["summary", "required_passing"])

      structural_complete =
        get_in(artifact, ["summary", "structural_contract_complete"]) == true and
          is_integer(required_cases) and required_cases > 0 and required_passing == required_cases

      passing = structural_complete and authority["complete"]

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

      artifact_lane("instruction_optimizer_contract", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing,
        scale: "full",
        summary: %{
          "evidence_tier" => artifact["evidence_tier"],
          "required_cases" => required_cases,
          "required_passing" => required_passing,
          "structural_contract_complete" => structural_complete,
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
    with {:ok, path} <- latest(Path.join(dir, "optimizer-lift-parity-*.json")),
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
          "dsex_only_or_deviation" => get_in(artifact, ["summary", "dsex_only_or_deviation"]),
          "direct_optimizers" => row_names_by_status(artifact, "direct"),
          "dsex_only_or_deviation_optimizers" => non_direct_row_names(artifact),
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
    required_families = DSEx.BenchmarkTruth.GepaReplicationContract.required_families()
    optimizer_fields = DSEx.BenchmarkTruth.GepaReplicationContract.optimizer_fields()

    with {:ok, path} <- latest(Path.join(dir, "gepa-replication-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      rows = Map.get(artifact, "rows", [])
      validation = DSEx.BenchmarkTruth.GepaReplicationContract.validate_rows(rows)
      present_families = rows |> Enum.map(& &1["family"]) |> Enum.uniq()
      missing_families = validation.missing_families
      missing_fields = validation.missing_fields

      passing = get_in(artifact, ["summary", "all_passing"]) == true
      full = DSEx.BenchmarkTruth.GepaReplicationContract.full_artifact?(artifact)

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
    with {:ok, path} <- latest(Path.join(dir, "optimize-anything-replication-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      full = DSEx.BenchmarkTruth.OptimizeAnything.Artifact.full_artifact?(artifact)
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
            "artifact must be a non-smoke dsex-gepa-replication input artifact with research_campaign evidence"
        )
      ],
      &is_nil/1
    )
  end

  defp rag_tool_agent_lane(dir, max_age_hours) do
    with {:ok, path} <- latest(Path.join(dir, "rag-tool-agent-parity-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["summary", "all_passing"]) == true
      full = get_in(artifact, ["summary", "full_rag_tool_agent_parity"]) == true

      artifact_lane("rag_tool_agent", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing and full,
        scale: if(full, do: "full", else: "sample"),
        summary: %{
          "total" => get_in(artifact, ["summary", "total"]),
          "passing" => get_in(artifact, ["summary", "passing"]),
          "direct_comparisons" => get_in(artifact, ["summary", "direct_comparisons"]),
          "dsex_only_or_deviation" => get_in(artifact, ["summary", "dsex_only_or_deviation"]),
          "full_rag_tool_agent_parity" => full
        },
        limitation:
          if(full,
            do: nil,
            else:
              "RAG/tool/agent artifact is passing as a provider-free sample, but live/provider and broader trace/error slices are still required."
          )
      )
    else
      _ -> missing_lane("rag_tool_agent", "no rag-tool-agent-parity artifact found in #{dir}")
    end
  end

  defp rlm_benchmark_lane(dir, max_age_hours) do
    with {:ok, path} <- latest(Path.join(dir, "rlm-benchmark-parity-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["summary", "all_passing"]) == true
      tier = artifact["evidence_tier"]

      full =
        tier == "t3_paper_scale" and
          get_in(artifact, ["summary", "paper_protocol_complete"]) == true

      artifact_lane("rlm_benchmark", path, artifact, max_age_hours,
        passing: passing,
        full_evidence: passing and full,
        scale: if(full, do: "full", else: tier || "unknown"),
        summary: %{
          "total" => get_in(artifact, ["summary", "total"]),
          "passing" => get_in(artifact, ["summary", "passing"]),
          "approaches" => get_in(artifact, ["summary", "approaches"]),
          "evidence_tier" => tier,
          "paper_protocol_complete" => get_in(artifact, ["summary", "paper_protocol_complete"]),
          "full_rlm_benchmark_parity" => full
        },
        limitation:
          if(full,
            do: nil,
            else:
              "RLM evidence is below T3 paper scale; the deterministic mix benchmark.rlm.check replay cannot satisfy this release lane."
          )
      )
    else
      _ -> missing_lane("rlm_benchmark", "no rlm-benchmark-parity artifact found in #{dir}")
    end
  end

  defp claims_gate(path, lanes, profile) do
    case read_claims(path) do
      {:ok, claims} ->
        selected_claims = ReleaseProfile.select_claims(claims, profile)
        evaluated = Enum.map(selected_claims, &evaluate_claim(&1, lanes))

        blocking =
          Enum.filter(evaluated, &(&1["release_blocking"] == true and &1["status"] != "proven"))

        %{
          "status" => if(blocking == [], do: "full", else: "failing"),
          "passing" => blocking == [],
          "artifact" => %{"path" => path, "sha256" => file_sha256(path)},
          "profile" => profile,
          "summary" => %{
            "total" => length(evaluated),
            "proven" => Enum.count(evaluated, &(&1["status"] == "proven")),
            "blocked" => length(blocking),
            "non_blocking" => Enum.count(evaluated, &(&1["release_blocking"] != true))
          },
          "claims" => evaluated,
          "blocking_requirements" =>
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
            end),
          "limitation" =>
            if(blocking == [],
              do: nil,
              else: "One or more release-blocking public claims lack fresh passing evidence."
            )
        }

      {:error, reason} ->
        %{
          "status" => "missing",
          "passing" => false,
          "artifact" => nil,
          "summary" => %{"total" => 0, "proven" => 0, "blocked" => 1, "non_blocking" => 0},
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

  defp read_claims(path) do
    with true <- File.exists?(path),
         {:ok, artifact} <- read_artifact(path),
         claims when is_list(claims) <- artifact["claims"] do
      {:ok, claims}
    else
      false -> {:error, :missing_claims_file}
      nil -> {:error, :missing_claims_array}
      _other -> {:error, :invalid_claims_file}
    end
  end

  defp evaluate_claim(claim, lanes) do
    requirements =
      claim
      |> Map.get("requirements", [])
      |> Enum.map(&evaluate_claim_requirement(&1, lanes))

    satisfied? = requirements != [] and Enum.all?(requirements, &(&1["satisfied"] == true))
    release_blocking = Map.get(claim, "release_blocking", true)

    claim
    |> Map.take([
      "id",
      "statement",
      "category",
      "surface",
      "claim_type",
      "comparison",
      "sources",
      "decision",
      "release",
      "scope",
      "limitations",
      "release_blocking"
    ])
    |> Map.put("release_blocking", release_blocking)
    |> Map.put(
      "status",
      cond do
        satisfied? -> "proven"
        release_blocking -> "blocked"
        true -> "not_release_blocking"
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
    with {:ok, path} <- latest(globs),
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
           "dsex_instrumentation" => get_in(artifact, ["summary", "dsex_instrumentation"]),
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
    with {:ok, path} <- latest(Path.join(dir, "dsex-dspy-parity-campaign-*.json")),
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
          "dsex_instrumentation" => campaign_instrumentation_summary(artifact["tasks"] || []),
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
          "no live-matched-model matrix or dsex-dspy-parity-campaign artifact found"
        )
    end
  end

  defp artifact_lane(id, path, artifact, max_age_hours, opts) do
    fresh = fresh?(artifact, path, max_age_hours)
    passing = Keyword.fetch!(opts, :passing)
    full_evidence = Keyword.fetch!(opts, :full_evidence) and fresh
    scale = Keyword.fetch!(opts, :scale)

    %{
      "id" => id,
      "status" => status(passing, full_evidence, scale, fresh),
      "passing" => passing,
      "fresh" => fresh,
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
            "One or more selected live model artifacts fail latency parity; inspect latency and DSEx transport metadata before claiming performance parity."
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
        get_in(summary, ["dsex_instrumentation", "complete"]) != true,
        %{
          "kind" => "dsex_instrumentation_incomplete",
          "message" =>
            "DSEx live runtime instrumentation is not complete for every covered model."
        }
      )
      |> maybe_add_requirement(
        get_in(summary, ["runtime_shape", "complete"]) != true,
        %{
          "kind" => "runtime_shape_incomplete",
          "runtime_shape" => summary["runtime_shape"],
          "message" =>
            "Runtime shape evidence is not complete for every covered model with comparable DSEx and DSPy instrumentation."
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

  defp latest(glob) when is_binary(glob), do: latest([glob])

  defp latest(globs) do
    paths =
      globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()

    case paths do
      [] -> {:error, :missing}
      paths -> {:ok, Enum.max_by(paths, &mtime_unix!/1)}
    end
  end

  defp read_artifact(path) do
    {:ok, path |> File.read!() |> Jason.decode!()}
  rescue
    _error -> {:error, :invalid_json}
  end

  defp fresh?(artifact, path, max_age_hours) do
    case artifact_generated_at(artifact) do
      {:ok, datetime} ->
        DateTime.diff(DateTime.utc_now(), datetime, :second) <= max_age_hours * 60 * 60

      :error ->
        age_seconds = System.system_time(:second) - mtime_unix!(path)
        age_seconds <= max_age_hours * 60 * 60
    end
  end

  defp artifact_generated_at(artifact) do
    case artifact["generated_at"] && DateTime.from_iso8601(artifact["generated_at"]) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> :error
    end
  end

  defp mtime_unix!(path) do
    {:ok, stat} = File.stat(path, time: :posix)
    stat.mtime
  end

  defp worst_ratio([]), do: nil

  defp worst_ratio(cases) do
    cases
    |> Enum.map(& &1["median_ratio_dsex_over_dspy"])
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ratios -> Enum.max(ratios)
    end
  end

  defp campaign_instrumentation_summary(tasks) do
    summaries =
      tasks
      |> Enum.map(&(&1["dsex_instrumentation"] || %{}))
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
      |> Enum.map(& &1["message_chars_ratio_dsex_over_dspy_mean"])
      |> Enum.filter(&is_number/1)

    raw_ratios =
      summaries
      |> Enum.map(& &1["raw_chars_ratio_dsex_over_dspy_mean"])
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
      "mean_message_chars_ratio_dsex_over_dspy" => average(message_ratios),
      "mean_raw_chars_ratio_dsex_over_dspy" => average(raw_ratios)
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

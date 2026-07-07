defmodule Mix.Tasks.Dsex.Benchmark.Dashboard do
  @moduledoc """
  Aggregate DSEx-vs-DSPy validation evidence into one dashboard artifact.

      mix dsex.benchmark.dashboard

  By default the task writes a dashboard even when lanes are missing. Use
  `--require-full` for the release gate that refuses full parity claims unless
  every required lane is present and passing at full-evidence scale.
  """

  use Mix.Task

  @shortdoc "Aggregate parity and performance evidence into a dashboard"

  @default_results_dir "benchmarks/results"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          trace_dir: :string,
          overhead_dir: :string,
          optimizer_dir: :string,
          rag_tool_agent_dir: :string,
          live_matrix_dir: :string,
          results_dir: :string,
          out: :string,
          max_age_hours: :integer,
          require_full: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = Keyword.get(opts, :out, @default_results_dir)
    File.mkdir_p!(out_dir)

    dashboard = dashboard(opts)
    out_path = Path.join(out_dir, "parity-dashboard-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(dashboard, pretty: true) <> "\n")

    Mix.shell().info("parity dashboard: #{out_path}")
    Mix.shell().info("full parity: #{dashboard["full_parity"]}")
    Mix.shell().info("performance claim supported: #{dashboard["performance_claim_supported"]}")

    if Keyword.get(opts, :require_full, false) and not dashboard["full_parity"] do
      Mix.raise("full parity release gate failed; inspect #{out_path}")
    end
  end

  defp dashboard(opts) do
    max_age_hours = Keyword.get(opts, :max_age_hours, 24)

    lanes = %{
      "golden_trace" =>
        golden_trace_lane(Keyword.get(opts, :trace_dir, "tmp/golden-trace"), max_age_hours),
      "live_matched_model" =>
        live_matched_model_lane(
          Keyword.get(opts, :live_matrix_dir, "tmp/live-matrix"),
          results_dir(opts),
          max_age_hours
        ),
      "optimizer_lift" =>
        optimizer_lift_lane(
          Keyword.get(opts, :optimizer_dir, "tmp/optimizer-lift"),
          max_age_hours
        ),
      "rag_tool_agent" =>
        rag_tool_agent_lane(
          Keyword.get(opts, :rag_tool_agent_dir, "tmp/rag-tool-agent"),
          max_age_hours
        ),
      "provider_free_overhead" =>
        overhead_lane(Keyword.get(opts, :overhead_dir, "tmp/overhead"), max_age_hours)
    }

    required = [
      "golden_trace",
      "live_matched_model",
      "optimizer_lift",
      "rag_tool_agent",
      "provider_free_overhead"
    ]

    gate_checks = release_gate_checks(required, lanes)
    full_parity = Enum.all?(gate_checks, &(&1["passing"] == true))
    performance_supported = get_in(lanes, ["provider_free_overhead", "passing"]) == true

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "max_age_hours" => max_age_hours,
      "required_lanes" => required,
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
      "summary" => %{
        "passing_lanes" => Enum.count(lanes, fn {_id, lane} -> lane["passing"] end),
        "full_evidence_lanes" => Enum.count(lanes, fn {_id, lane} -> lane["full_evidence"] end),
        "total_lanes" => map_size(lanes),
        "note" =>
          "Full parity is true only when all required lanes pass with full-evidence artifacts. Passing smoke or deterministic slices are preserved but cannot authorize full parity claims."
      },
      "lanes" => lanes
    }
  end

  defp results_dir(opts), do: Keyword.get(opts, :results_dir, @default_results_dir)

  defp release_gate_checks(required, lanes) do
    Enum.map(required, fn lane_id ->
      lane = Map.fetch!(lanes, lane_id)

      %{
        "lane" => lane_id,
        "status" => lane["status"],
        "passing" => lane["passing"] == true and lane["full_evidence"] == true,
        "fresh" => lane["fresh"],
        "full_evidence" => lane["full_evidence"],
        "limitation" => lane["limitation"],
        "blocking_requirements" => lane["blocking_requirements"] || []
      }
    end)
  end

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

  defp optimizer_lift_lane(dir, max_age_hours) do
    with {:ok, path} <- latest(Path.join(dir, "optimizer-lift-parity-*.json")),
         {:ok, artifact} <- read_artifact(path) do
      passing = get_in(artifact, ["summary", "all_passing"]) == true
      full = get_in(artifact, ["summary", "full_optimizer_parity"]) == true

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
          "full_optimizer_parity" => full
        },
        limitation:
          if(full,
            do: nil,
            else:
              "Optimizer lift artifact is passing as a sample, but direct DSPy comparisons do not yet cover every production optimizer/trainer path."
          )
      )
    else
      _ -> missing_lane("optimizer_lift", "no optimizer-lift-parity artifact found in #{dir}")
    end
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
           "dsex_instrumentation" => get_in(artifact, ["summary", "dsex_instrumentation"]),
           "runtime_shape" => get_in(artifact, ["summary", "runtime_shape"]),
           "disagreements" => get_in(artifact, ["summary", "disagreements"])
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
        get_in(summary, ["prompt_contract", "complete"]) != true,
        %{
          "kind" => "prompt_contract_incomplete",
          "prompt_contract" => summary["prompt_contract"],
          "message" =>
            "Live matched-model evidence is not current for every selected prompt/signature contract."
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

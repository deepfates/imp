defmodule Imp.BenchmarkTruth.RLMCampaign do
  @moduledoc false

  alias Imp.BenchmarkTruth.{
    ArtifactFile,
    CampaignBudget,
    RLMCheckpoint,
    RLMDataset,
    RLMManifest,
    RLMProtocol,
    RLMStatistics
  }

  def plan(manifest_path, opts \\ []) do
    manifest = RLMManifest.load!(manifest_path, allow_pending: true)
    root = Keyword.get(opts, :root, File.cwd!())
    source_status = source_status(manifest, root)
    selection = selection!(manifest, opts)
    ensure_runnable_selection!(manifest, selection)
    datasets = plan_selected_datasets!(manifest, selection)
    planned_jobs = jobs(manifest, datasets, selection)

    %{
      "campaign_id" => manifest["campaign_id"],
      "requested_evidence_tier" => manifest["evidence_tier"],
      "evidence_tier" => evidence_tier(manifest, selection),
      "subset" => subset?(manifest, selection),
      "selection" => selection,
      "job_count" => length(planned_jobs),
      "jobs" => Enum.map(planned_jobs, &job_evidence/1),
      "families" => Map.new(datasets, fn {family, data} -> {family, data["evaluated_rows"]} end),
      "pending_acquisition" => false,
      "source_validation" => source_status,
      "dataset_validation" => dataset_status(manifest, selection),
      "provider_calls" => 0
    }
  end

  def run(manifest_path, opts \\ []) do
    manifest = RLMManifest.load!(manifest_path, allow_pending: true)
    RLMManifest.verify_sources!(manifest, Keyword.get(opts, :root, File.cwd!()))
    selection = selection!(manifest, opts)
    ensure_runnable_selection!(manifest, selection)
    datasets = load_selected_datasets!(manifest, selection)
    runtimes = selection["runtimes"]
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    checkpoint_dir = Keyword.get(opts, :checkpoint_dir, Path.join(out_dir, "rlm-checkpoints"))
    File.mkdir_p!(out_dir)
    File.mkdir_p!(checkpoint_dir)

    identity = identity(manifest, datasets, selection)

    checkpoint_path =
      Path.join(checkpoint_dir, "#{slug(manifest["campaign_id"])}-#{selection["runtime"]}.json")

    checkpoint = start_checkpoint!(checkpoint_path, identity)
    existing = RLMCheckpoint.rows(checkpoint)
    budgets = start_budgets!(manifest, runtimes, existing)
    planned_jobs = jobs(manifest, datasets, selection)
    execute_jobs!(planned_jobs, manifest, checkpoint, budgets, opts)
    rows = RLMCheckpoint.rows(checkpoint)
    artifact = artifact(manifest, datasets, rows, selection, checkpoint_path)
    protocol = RLMProtocol.evaluate(artifact)

    artifact =
      artifact
      |> put_in(["summary", "paper_protocol_complete"], protocol["paper_protocol_complete"])
      |> put_in(["summary", "t3_gate_checks"], protocol["checks"])

    path = Path.join(out_dir, "rlm-benchmark-parity-#{timestamp_slug()}.json")

    %{
      artifact: artifact,
      path: ArtifactFile.write_json!(path, artifact),
      checkpoint_path: checkpoint_path
    }
  end

  defp execute_jobs!(jobs, manifest, checkpoint, budgets, opts) do
    timeout = manifest["execution"]["row_timeout_ms"]
    concurrency = manifest["execution"]["concurrency"]

    jobs
    |> Task.async_stream(fn job -> execute_job!(job, manifest, checkpoint, budgets, opts) end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.each(fn
      {:ok, :ok} ->
        :ok

      {:ok, {:ambiguous_dispatch, reason}} ->
        raise RuntimeError,
              "RLM campaign row crashed after durable intent: #{inspect(reason)}"

      {:exit, :timeout} ->
        raise RuntimeError,
              "RLM campaign row timed out; durable intent retained and replay is refused"

      {:exit, reason} ->
        raise RuntimeError, "RLM campaign row crashed after durable intent: #{inspect(reason)}"
    end)
  end

  defp execute_job!(job, manifest, checkpoint, budgets, opts) do
    key = Enum.join([job.runtime, job.approach, job.row["family"], job.row["id"]], ":")

    intent = %{
      "key" => key,
      "runtime" => job.runtime,
      "approach" => job.approach,
      "family" => job.row["family"],
      "example_id" => job.row["id"]
    }

    case RLMCheckpoint.claim(checkpoint, key, intent) do
      :already_committed ->
        :ok

      {:error, :ambiguous} ->
        raise "ambiguous RLM dispatch: #{key}"

      :claimed ->
        budget = Map.fetch!(budgets, {job.runtime, job.approach})
        runtime = runtime_module(job.runtime, opts)

        context = %{
          "manifest" => manifest,
          "approach" => manifest["approaches"][job.approach],
          "budget" => budget,
          "row_timeout_ms" => manifest["execution"]["row_timeout_ms"],
          "work_dir" => Keyword.get(opts, :work_dir, "tmp/rlm-campaign"),
          "python" => Keyword.get(opts, :python, default_python())
        }

        case safe_execute_runtime(runtime, job, context, budget) do
          {:ambiguous_dispatch, _reason} = ambiguous ->
            ambiguous

          outcome ->
            row = safe_outcome_row(key, job, outcome)
            :ok = RLMCheckpoint.commit(checkpoint, key, row)
            :ok
        end
    end
  end

  defp safe_execute_runtime(runtime, job, context, budget) do
    execute_runtime(runtime, job, context, budget)
  rescue
    error -> {:ambiguous_dispatch, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:ambiguous_dispatch, {kind, reason}}
  end

  defp execute_runtime(runtime, job, context, budget) do
    execute = fn ->
      # DSPy rows are serialized by budget; take the remaining-budget snapshot
      # inside that same critical section so concurrent rows cannot use stale limits.
      context = Map.put(context, "budget_remaining", CampaignBudget.snapshot(budget))
      result = runtime.execute(RLMDataset.prompt_payload(job.row), job.approach, context)

      case result do
        {:ok, %{"budget_accounted" => true}} ->
          result

        {:ok, %{"usage" => usage} = outcome} ->
          case account_external_usage(budget, usage) do
            :ok -> result
            {:error, reason} -> charged_error(reason, usage, outcome)
          end

        {:error, %{"usage" => usage} = error} ->
          if error["budget_accounted"] == true do
            result
          else
            case account_external_usage(budget, usage) do
              :ok -> result
              {:error, reason} -> charged_error(reason, usage, error)
            end
          end

        other ->
          other
      end
    end

    if runtime == Imp.BenchmarkTruth.RLMRuntime.DSPy do
      :global.trans({__MODULE__, budget}, execute)
    else
      execute.()
    end
  end

  defp account_external_usage(budget, usage) when is_map(usage) do
    requests = usage["requests"]

    reservation_result =
      if is_integer(requests) and requests >= 0,
        do: reserve_requests(budget, requests, []),
        else: {:error, :malformed_runtime_usage, []}

    reservations = elem(reservation_result, tuple_size(reservation_result) - 1)
    :ok = CampaignBudget.record_usage(budget, observed_budget_usage(usage))
    Enum.each(reservations, &CampaignBudget.release(budget, &1))

    case reservation_result do
      {:error, :malformed_runtime_usage, _reservations} ->
        {:error, :malformed_runtime_usage}

      {:error, dimension, _reservations} ->
        {:error, {:campaign_budget_exhausted, dimension}}

      {:ok, _reservations} ->
        cond do
          not valid_usage_dimensions?(usage) ->
            {:error, :malformed_runtime_usage}

          not valid_cost_usage?(usage) ->
            {:error, :unaudited_runtime_cost}

          dimension = CampaignBudget.snapshot(budget)["exhausted"] ->
            {:error, {:campaign_budget_exhausted, dimension}}

          true ->
            :ok
        end
    end
  end

  defp observed_budget_usage(usage) do
    %{
      "input_tokens" => observed_token_count(usage["input_tokens"]),
      "output_tokens" => observed_token_count(usage["output_tokens"]),
      "usd" => observed_usd(usage["usd"])
    }
  end

  defp observed_token_count(value) when is_integer(value) and value >= 0, do: value
  defp observed_token_count(_value), do: 0
  defp observed_usd(value) when is_number(value) and value >= 0, do: value
  defp observed_usd(_value), do: 0.0

  defp charged_error(reason, usage, source) do
    runtime_reason = source["error"] || source["reason"]

    evidence =
      source
      |> Map.take(~w(latency_ms trace_shape trace))
      |> Map.merge(%{
        "reason" =>
          %{accounting: reason, runtime: runtime_reason}
          |> Imp.Redaction.redact()
          |> inspect(),
        "usage" => usage,
        "call_semantics" => source["call_semantics"] || empty_call_semantics(),
        "budget_accounted" => true
      })

    {:error, evidence}
  end

  defp reserve_requests(_budget, 0, reservations), do: {:ok, reservations}

  defp reserve_requests(budget, count, reservations) do
    case CampaignBudget.reserve(budget, [], max_tokens: 0) do
      {:ok, reservation} -> reserve_requests(budget, count - 1, [reservation | reservations])
      {:error, dimension} -> {:error, dimension, reservations}
    end
  end

  defp safe_outcome_row(key, job, outcome) do
    outcome_row(key, job, outcome)
  rescue
    error in ArgumentError ->
      error_row(
        key,
        job,
        inspect({:malformed_runtime_output, Exception.message(error)}),
        outcome_usage(outcome),
        outcome_metadata(outcome)
      )
  end

  defp outcome_usage({_, %{"usage" => usage}}) when is_map(usage), do: usage
  defp outcome_usage(_), do: empty_usage()
  defp outcome_metadata({_, metadata}) when is_map(metadata), do: metadata
  defp outcome_metadata(_), do: %{}

  defp outcome_row(key, job, {:ok, outcome}) do
    validate_outcome!(outcome)

    case score_result(outcome["answer"], job.row["gold"], job.metric) do
      {:ok, score} ->
        %{
          "key" => key,
          "example_id" => job.row["id"],
          "family" => job.row["family"],
          "model_family" => model_family(job),
          "approach" => job.approach,
          "runtime" => job.runtime,
          "status" => "ok",
          "answer" => outcome["answer"],
          "score" => score,
          "latency_ms" => outcome["latency_ms"],
          "usage" => outcome["usage"],
          "query_id" => job.row["query_id"] || job.row["id"],
          "context_size" => job.row["context_size"],
          "metric" => job.metric,
          "scorer_evidence" => scorer_evidence(outcome, job),
          "trace_shape" => outcome["trace_shape"],
          "trace" => outcome["trace"],
          "call_semantics" => outcome["call_semantics"],
          "provenance" => provenance(job),
          "error" => nil
        }

      {:error, reason} ->
        error_row(key, job, reason, outcome["usage"], outcome)
    end
  end

  defp outcome_row(key, job, {:error, %{"usage" => usage} = error}),
    do: error_row(key, job, error["reason"] || error["error"] || "runtime error", usage, error)

  defp outcome_row(key, job, {:error, reason}),
    do: error_row(key, job, inspect(reason), empty_usage(), %{})

  defp error_row(key, job, reason, usage, error),
    do: %{
      "key" => key,
      "example_id" => job.row["id"],
      "family" => job.row["family"],
      "model_family" => model_family(job),
      "approach" => job.approach,
      "runtime" => job.runtime,
      "status" => "error",
      "answer" => nil,
      "score" => 0.0,
      "latency_ms" => error["latency_ms"] || 0.0,
      "usage" => normalize_row_usage(usage),
      "query_id" => job.row["query_id"] || job.row["id"],
      "context_size" => job.row["context_size"],
      "metric" => job.metric,
      "scorer_evidence" => error["scorer_evidence"],
      "trace_shape" => error["trace_shape"] || ["error"],
      "trace" => error["trace"] || [],
      "call_semantics" => error["call_semantics"] || empty_call_semantics(),
      "provenance" => provenance(job),
      "error" => to_string(reason)
    }

  defp validate_outcome!(%{
         "answer" => answer,
         "latency_ms" => latency,
         "usage" => usage,
         "trace_shape" => shape,
         "trace" => trace,
         "call_semantics" => semantics
       })
       when is_binary(answer) and answer != "" and is_number(latency) and latency >= 0 and
              is_map(usage) and is_list(shape) and shape != [] and is_list(trace) and
              is_map(semantics) do
    unless Enum.all?(
             ~w(requests root_calls sub_calls input_tokens output_tokens),
             &(is_integer(usage[&1]) and usage[&1] >= 0)
           ) and is_number(usage["usd"]) and usage["usd"] >= 0,
           do: raise(ArgumentError, "malformed RLM runtime usage")

    unless usage["requests"] > 0 and usage["input_tokens"] > 0 and usage["output_tokens"] > 0,
      do:
        raise(
          ArgumentError,
          "successful RLM runtime usage must include positive calls and tokens"
        )

    unless valid_cost_usage?(usage),
      do: raise(ArgumentError, "unaudited or inconsistent RLM runtime cost")

    unless semantics["provider_calls"] == usage["requests"] and
             Enum.all?(
               ~w(root_calls sub_calls configured_max_depth max_observed_depth),
               &(is_integer(semantics[&1]) and semantics[&1] >= 0)
             ) and is_binary(semantics["max_llm_calls_scope"]),
           do: raise(ArgumentError, "malformed RLM call semantics")

    :ok
  end

  defp validate_outcome!(other),
    do: raise(ArgumentError, "malformed RLM runtime output: #{inspect(other)}")

  defp valid_usage_dimensions?(usage) do
    Enum.all?(~w(requests root_calls sub_calls input_tokens output_tokens), fn key ->
      is_integer(usage[key]) and usage[key] >= 0
    end) and is_number(usage["usd"]) and usage["usd"] >= 0 and
      usage["requests"] == usage["root_calls"] + usage["sub_calls"]
  end

  defp valid_cost_usage?(usage) when is_map(usage) do
    rates = usage["cost_rates"]
    audits = usage["cost_audit"]
    requests = usage["requests"]

    valid_rates?(rates) and is_list(audits) and Enum.all?(audits, &is_map/1) and
      is_integer(requests) and requests > 0 and
      length(audits) == requests and
      Enum.map(audits, & &1["request"]) |> Enum.sort() == Enum.to_list(1..requests) and
      Enum.all?(audits, &valid_cost_audit?(&1, rates)) and
      Enum.sum(Enum.map(audits, & &1["input_tokens"])) == usage["input_tokens"] and
      Enum.sum(Enum.map(audits, & &1["output_tokens"])) == usage["output_tokens"] and
      Enum.count(audits, &(&1["role"] == "root")) == usage["root_calls"] and
      Enum.count(audits, &(&1["role"] == "sub")) == usage["sub_calls"] and
      close?(Enum.sum(Enum.map(audits, & &1["usd"])), usage["usd"]) and
      aggregate_cost_authority(audits) == usage["cost_authority"]
  end

  defp valid_cost_usage?(_usage), do: false

  defp valid_rates?(
         %{
           "input_per_million" => input,
           "output_per_million" => output
         } = rates
       ),
       do:
         Map.keys(rates) |> Enum.sort() == ~w(input_per_million output_per_million) and
           is_number(input) and input >= 0 and is_number(output) and output >= 0

  defp valid_rates?(_rates), do: false

  defp valid_cost_audit?(audit, rates) when is_map(audit) do
    input = audit["input_tokens"]
    output = audit["output_tokens"]
    usd = audit["usd"]
    reported = audit["provider_reported_usd"]

    is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and
      is_number(usd) and usd >= 0 and audit["role"] in ~w(root sub) and
      audit["rates"] == rates and
      case audit["authority"] do
        "provider_reported" ->
          is_number(reported) and reported > 0 and close?(reported, usd)

        "pricing_derived" ->
          is_nil(reported) and usd > 0 and close?(derived_cost(input, output, rates), usd)

        "free" ->
          reported == 0.0 and usd == 0.0

        _ ->
          false
      end
  end

  defp valid_cost_audit?(_audit, _rates), do: false

  defp derived_cost(input, output, rates),
    do:
      input / 1_000_000 * rates["input_per_million"] +
        output / 1_000_000 * rates["output_per_million"]

  defp aggregate_cost_authority(audits) do
    case audits |> Enum.map(& &1["authority"]) |> Enum.uniq() do
      [authority] -> authority
      [_first | _rest] -> "mixed"
      [] -> "unavailable"
    end
  end

  defp close?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) <= max(1.0e-12, max(abs(left), abs(right)) * 1.0e-9)

  defp close?(_left, _right), do: false

  defp jobs(manifest, datasets, selection) do
    for runtime <- selection["runtimes"],
        approach <- selection["approaches"],
        runtime in manifest["approaches"][approach]["runtimes"],
        {_family, dataset} <- Enum.sort(datasets),
        row <- dataset["rows"] do
      %{
        runtime: runtime,
        approach: approach,
        row: row,
        metric: manifest["datasets"][row["family"]]["metric"],
        dataset_sha256: dataset["sha256"],
        manifest_sha256: manifest["manifest_sha256"],
        root_model: manifest["models"]["root"]["logical"]
      }
    end
  end

  defp start_budgets!(manifest, runtimes, existing) do
    for runtime <- runtimes,
        approach <- RLMManifest.approach_ids(),
        runtime in manifest["approaches"][approach]["runtimes"],
        into: %{} do
      config = manifest["approaches"][approach]

      pricing =
        config["settings"]["reservation_pricing"] ||
          %{"input_per_million" => 1000.0, "output_per_million" => 1000.0}

      initial_rows =
        Enum.filter(existing, &(&1["runtime"] == runtime and &1["approach"] == approach))

      initial = %{
        "requests" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["requests"])),
        "usage" => %{
          "input_tokens" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["input_tokens"])),
          "output_tokens" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["output_tokens"])),
          "usd" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["usd"]))
        },
        "reservations" => []
      }

      {:ok, pid} =
        CampaignBudget.start_link(
          limits: config["budget"],
          pricing: pricing,
          default_max_output_tokens: manifest["models"]["root"]["max_output_tokens"],
          initial: initial
        )

      {{runtime, approach}, pid}
    end
  end

  defp artifact(manifest, datasets, rows, selection, checkpoint_path) do
    dataset_evidence =
      Map.new(datasets, fn {family, data} ->
        spec = manifest["datasets"][family]

        {family,
         data
         |> Map.drop(["rows", "path", "sample_ids"])
         |> Map.put("docs_per_instance", spec["docs_per_instance"])
         |> Map.put("context_grid", spec["context_grid"])
         |> Map.put(
           "evidence_in_dataset",
           family != "browsecomp_plus" or
             Enum.all?(data["rows"], &is_list(&1["evidence_document_ids"]))
         )}
      end)

    stats = RLMStatistics.aggregate(rows, manifest)
    all_passing = rows != [] and Enum.all?(rows, &(&1["status"] == "ok"))

    %{
      "schema_version" => 2,
      "runner" => "imp-rlm-campaign",
      "evidence_tier" => evidence_tier(manifest, selection),
      "requested_evidence_tier" => manifest["evidence_tier"],
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "tracked_worktree_dirty" => tracked_worktree_dirty?(),
      "manifest" => Map.drop(manifest, ["manifest_path"]),
      "datasets" => dataset_evidence,
      "execution" => %{
        "runtime_selection" => selection["runtime"],
        "selection" => selection,
        "subset" => subset?(manifest, selection),
        "checkpoint_path" => checkpoint_path,
        "concurrency" => manifest["execution"]["concurrency"],
        "row_timeout_ms" => manifest["execution"]["row_timeout_ms"]
      },
      "rows" => rows,
      "aggregate" => stats,
      "summary" => %{
        "total" => length(rows),
        "passing" => Enum.count(rows, &(&1["status"] == "ok")),
        "all_passing" => all_passing,
        "approaches" => stats["approaches"],
        "paper_protocol_complete" => false
      }
    }
  end

  defp dataset_status(manifest, selection) do
    manifest["datasets"]
    |> Map.take(selection["families"])
    |> Map.new(fn {family, spec} ->
      {family,
       %{
         "path" => spec["path"],
         "hash_pinned" => spec["sha256"] != "ACQUIRE_AND_PIN_SHA256",
         "ids_frozen" => is_list(spec["sample_ids"]),
         "present" =>
           File.regular?(Path.expand(spec["path"], Path.dirname(manifest["manifest_path"])))
       }}
    end)
  end

  defp start_checkpoint!(path, identity) do
    case RLMCheckpoint.start(path: path, identity: identity) do
      {:ok, pid} -> pid
      {:error, {%ArgumentError{} = error, _stack}} -> raise error
      {:error, reason} -> raise RuntimeError, "failed to start RLM checkpoint: #{inspect(reason)}"
    end
  end

  defp source_status(manifest, root) do
    try do
      RLMManifest.verify_sources!(manifest, root)
      %{"valid" => true}
    rescue
      error -> %{"valid" => false, "error" => Exception.message(error)}
    end
  end

  defp runtime_module(runtime, opts),
    do:
      Keyword.get(opts, :runtime_modules, %{})
      |> Map.get(
        runtime,
        if(runtime == "imp",
          do: Imp.BenchmarkTruth.RLMRuntime.Native,
          else: Imp.BenchmarkTruth.RLMRuntime.DSPy
        )
      )

  defp selected_runtimes!("imp"), do: ["imp"]
  defp selected_runtimes!("dspy"), do: ["dspy"]
  defp selected_runtimes!("both"), do: ["imp", "dspy"]

  defp selected_runtimes!(other),
    do: raise(ArgumentError, "runtime must be imp, dspy, or both; got #{inspect(other)}")

  defp selection!(manifest, opts) do
    runtime = Keyword.get(opts, :runtime, "imp")
    runtimes = selected_runtimes!(runtime)

    available_families =
      RLMManifest.family_ids()
      |> Enum.filter(&Map.has_key?(manifest["datasets"], &1))

    families = selected_ids!(Keyword.get(opts, :families, []), available_families, "family")

    approaches =
      selected_ids!(Keyword.get(opts, :approaches, []), RLMManifest.approach_ids(), "approach")

    row_limit = Keyword.get(opts, :row_limit)

    unless is_nil(row_limit) or (is_integer(row_limit) and row_limit > 0),
      do: raise(ArgumentError, "row limit must be a positive integer")

    unsupported =
      for runtime_id <- runtimes,
          approach <- approaches,
          runtime_id not in manifest["approaches"][approach]["runtimes"],
          do: "#{runtime_id}:#{approach}"

    unless unsupported == [],
      do:
        raise(
          ArgumentError,
          "unsupported runtime/approach selections: #{Enum.join(unsupported, ", ")}"
        )

    %{
      "runtime" => runtime,
      "runtimes" => runtimes,
      "families" => families,
      "approaches" => approaches,
      "row_limit_per_family" => row_limit
    }
  end

  defp selected_ids!([], allowed, _label), do: allowed

  defp selected_ids!(values, allowed, label) when is_list(values) do
    values = Enum.uniq(values)
    invalid = values -- allowed

    unless invalid == [],
      do: raise(ArgumentError, "invalid #{label} filter: #{Enum.join(invalid, ", ")}")

    Enum.filter(allowed, &(&1 in values))
  end

  defp ensure_runnable_selection!(manifest, selection) do
    pending =
      selection["families"]
      |> Enum.filter(fn family ->
        spec = manifest["datasets"][family]
        spec["sha256"] == "ACQUIRE_AND_PIN_SHA256" or not is_list(spec["sample_ids"])
      end)

    unless pending == [],
      do:
        raise(
          ArgumentError,
          "selected RLM families are unavailable or unpinned: #{Enum.join(pending, ", ")}"
        )
  end

  defp load_selected_datasets!(manifest, selection) do
    selected_manifest =
      put_in(manifest["datasets"], Map.take(manifest["datasets"], selection["families"]))

    selected_manifest
    |> RLMDataset.load_all!(row_limit: selection["row_limit_per_family"])
    |> Map.new(fn {family, data} ->
      {family, limit_dataset(data, selection["row_limit_per_family"])}
    end)
  end

  defp plan_selected_datasets!(manifest, selection) do
    selected_manifest =
      put_in(manifest["datasets"], Map.take(manifest["datasets"], selection["families"]))

    selected_manifest
    |> RLMDataset.metadata_all!()
    |> Map.new(fn {family, data} ->
      {family, limit_dataset(data, selection["row_limit_per_family"])}
    end)
  end

  defp limit_dataset(data, nil), do: data

  defp limit_dataset(data, limit) do
    rows = Enum.take(data["rows"], limit)
    keys = Enum.take(data["evaluated_keys"], limit)
    sample_ids = rows |> Enum.map(&(&1["query_id"] || &1["id"])) |> Enum.uniq()

    data
    |> Map.put("rows", rows)
    |> Map.put("evaluated_keys", keys)
    |> Map.put("evaluated_rows", length(rows))
    |> Map.put("logical_instances", length(sample_ids))
    |> Map.put("sample_ids", sample_ids)
    |> Map.put("sample_ids_sha256", sha256(Jason.encode!(sample_ids)))
  end

  defp subset?(manifest, selection) do
    selection["families"] != RLMManifest.family_ids() or
      selection["approaches"] != RLMManifest.approach_ids() or
      selection["runtimes"] != all_manifest_runtimes(manifest) or
      not is_nil(selection["row_limit_per_family"])
  end

  defp all_manifest_runtimes(manifest) do
    manifest["approaches"]
    |> Map.values()
    |> Enum.flat_map(& &1["runtimes"])
    |> Enum.uniq()
    |> Enum.sort_by(&Enum.find_index(~w(imp dspy), fn id -> id == &1 end))
  end

  defp evidence_tier(manifest, selection) do
    if subset?(manifest, selection), do: "t2_live_sample", else: manifest["evidence_tier"]
  end

  defp job_evidence(job),
    do: %{
      "key" => Enum.join([job.runtime, job.approach, job.row["family"], job.row["id"]], ":"),
      "runtime" => job.runtime,
      "approach" => job.approach,
      "family" => job.row["family"],
      "example_id" => job.row["id"],
      "query_id" => job.row["query_id"] || job.row["id"],
      "context_size" => job.row["context_size"]
    }

  def score(answer, gold, "token_f1"), do: token_f1(answer, gold)
  def score(answer, gold, "pair_set_f1"), do: pair_set_f1(answer, gold)
  def score(answer, gold, "set_f1"), do: pair_set_f1(answer, gold)
  def score(answer, gold, "oolong_official"), do: oolong_official(answer, gold)

  def score(_answer, _gold, "official_llm_judge"),
    do:
      raise(
        ArgumentError,
        "BrowseComp+ requires the pinned official LLM judge and trec_eval retrieval evidence"
      )

  def score(answer, gold, _metric),
    do: if(normalize(answer) == normalize(gold), do: 1.0, else: 0.0)

  defp score_result(answer, gold, metric) do
    {:ok, score(answer, gold, metric)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp oolong_official(answer, gold) do
    case {strict_number(answer), strict_number(gold)} do
      {{:ok, predicted}, {:ok, expected}} -> :math.pow(0.75, abs(expected - predicted))
      {:error, {:ok, _expected}} -> 0.0
      _ -> if(String.trim(to_string(answer)) == String.trim(to_string(gold)), do: 1.0, else: 0.0)
    end
  end

  defp strict_number(value) when is_number(value), do: {:ok, value * 1.0}

  defp strict_number(value) do
    case Float.parse(String.trim(to_string(value))) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp pair_set_f1(answer, gold) do
    with {:ok, predicted} <- pair_set(answer),
         {:ok, expected} <- pair_set(gold) do
      cond do
        MapSet.size(predicted) == 0 and MapSet.size(expected) == 0 ->
          1.0

        MapSet.size(predicted) == 0 or MapSet.size(expected) == 0 ->
          0.0

        true ->
          common = predicted |> MapSet.intersection(expected) |> MapSet.size()
          2 * common / (MapSet.size(predicted) + MapSet.size(expected))
      end
    else
      :error -> 0.0
    end
  end

  defp pair_set(value) do
    lines = value |> to_string() |> String.split("\n") |> Enum.map(&String.trim/1)

    parsed = Enum.map(lines, &parse_pair_line/1)
    pairs = for {:pair, pair} <- parsed, do: pair

    cond do
      Enum.any?(parsed, &(&1 == :invalid)) ->
        :error

      pairs != [] and Enum.all?(parsed, &(match?({:pair, _}, &1) or &1 == :blank)) ->
        {:ok, MapSet.new(pairs)}

      pairs == [] and Enum.all?(parsed, &(&1 in [:blank, :empty])) ->
        {:ok, MapSet.new()}

      true ->
        :error
    end
  end

  defp parse_pair_line(""), do: :blank

  defp parse_pair_line(line) do
    case Regex.run(
           ~r/^\(\s*([A-Za-z0-9_.:-]+)\s*,\s*([A-Za-z0-9_.:-]+)\s*\)$/,
           line,
           capture: :all_but_first
         ) do
      [left, right] ->
        {:pair, if(left <= right, do: {left, right}, else: {right, left})}

      nil ->
        if empty_pair_marker?(line), do: :empty, else: :invalid
    end
  end

  defp empty_pair_marker?(line) do
    line
    |> String.downcase()
    |> String.replace(~r/^[^a-z0-9]+|[^a-z0-9]+$/, "")
    |> then(
      &(&1 in ["none", "no pairs", "no pairs found", "no such pairs", "no such pairs exist"])
    )
  end

  defp token_f1(answer, gold) do
    a = String.split(normalize(answer))
    g = String.split(normalize(gold))

    common =
      Enum.sum(
        Enum.map(
          Enum.uniq(a),
          &min(Enum.count(a, fn x -> x == &1 end), Enum.count(g, fn x -> x == &1 end))
        )
      )

    if common == 0, do: 0.0, else: 2 * common / (length(a) + length(g))
  end

  defp normalize(value),
    do:
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.reject(&(&1 in ~w(a an the)))
      |> Enum.join(" ")

  defp identity(manifest, datasets, selection),
    do: %{
      "campaign_id" => manifest["campaign_id"],
      "manifest_sha256" => manifest["manifest_sha256"],
      "datasets" =>
        Map.new(datasets, fn {family, data} ->
          {family,
           %{"sha256" => data["sha256"], "sample_ids_sha256" => data["sample_ids_sha256"]}}
        end),
      "selection" => selection
    }

  defp slug(value), do: String.replace(value, ~r/[^a-zA-Z0-9_.-]+/, "-")

  defp provenance(job),
    do: %{
      "manifest_sha256" => job.manifest_sha256,
      "dataset_sha256" => job.dataset_sha256,
      "dataset_key" => job.row["id"]
    }

  defp scorer_evidence(%{"scorer_evidence" => evidence}, _job) when is_map(evidence),
    do: evidence

  defp scorer_evidence(outcome, job) do
    input =
      Jason.encode!(%{
        "answer" => outcome["answer"],
        "gold" => job.row["gold"],
        "metric" => job.metric
      })

    %{
      "contract" => job.metric,
      "implementation" => "imp_rlm_campaign",
      "input_sha256" => sha256(input)
    }
  end

  defp model_family(job) do
    job.root_model
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp normalize_row_usage(usage) when is_map(usage),
    do: %{
      "requests" => usage["requests"] || 0,
      "root_calls" => usage["root_calls"] || 0,
      "sub_calls" => usage["sub_calls"] || 0,
      "input_tokens" => usage["input_tokens"] || 0,
      "output_tokens" => usage["output_tokens"] || 0,
      "usd" => usage["usd"] || 0.0,
      "cost_authority" => usage["cost_authority"] || "unavailable",
      "cost_rates" => usage["cost_rates"] || %{},
      "cost_audit" => usage["cost_audit"] || []
    }

  defp normalize_row_usage(_), do: empty_usage()

  defp empty_usage,
    do: %{
      "requests" => 0,
      "root_calls" => 0,
      "sub_calls" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "usd" => 0.0,
      "cost_authority" => "unavailable",
      "cost_rates" => %{},
      "cost_audit" => []
    }

  defp empty_call_semantics,
    do: %{
      "provider_calls" => 0,
      "root_calls" => 0,
      "sub_calls" => 0,
      "max_llm_calls_scope" => "unknown",
      "configured_max_depth" => 0,
      "max_observed_depth" => 0
    }

  defp timestamp_slug, do: DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

  defp default_python do
    local = Path.expand("tmp/dspy-current-venv/bin/python")
    if File.exists?(local), do: local, else: System.find_executable("python3") || "python3"
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp tracked_worktree_dirty? do
    case System.cmd("git", ["diff", "--quiet", "HEAD", "--"], stderr_to_stdout: true) do
      {_output, 0} -> false
      {_output, 1} -> true
      _other -> nil
    end
  end
end

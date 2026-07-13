defmodule DSEx.BenchmarkTruth.RLMCampaign do
  @moduledoc false

  alias DSEx.BenchmarkTruth.{
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
    dataset_status = dataset_status(manifest)

    %{
      "campaign_id" => manifest["campaign_id"],
      "evidence_tier" => manifest["evidence_tier"],
      "pending_acquisition" => RLMManifest.pending?(manifest),
      "source_validation" => source_status,
      "dataset_validation" => dataset_status,
      "provider_calls" => 0
    }
  end

  def run(manifest_path, opts \\ []) do
    manifest = RLMManifest.load!(manifest_path)
    RLMManifest.verify_sources!(manifest, Keyword.get(opts, :root, File.cwd!()))
    datasets = RLMDataset.load_all!(manifest)
    runtime_selection = Keyword.get(opts, :runtime, "dsex")
    runtimes = selected_runtimes!(runtime_selection)
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    checkpoint_dir = Keyword.get(opts, :checkpoint_dir, Path.join(out_dir, "rlm-checkpoints"))
    File.mkdir_p!(out_dir)
    File.mkdir_p!(checkpoint_dir)

    identity = identity(manifest, datasets, runtime_selection)

    checkpoint_path =
      Path.join(checkpoint_dir, "#{slug(manifest["campaign_id"])}-#{runtime_selection}.json")

    checkpoint = start_checkpoint!(checkpoint_path, identity)
    existing = RLMCheckpoint.rows(checkpoint)
    budgets = start_budgets!(manifest, runtimes, existing)
    jobs = jobs(manifest, datasets, runtimes)
    execute_jobs!(jobs, manifest, checkpoint, budgets, opts)
    rows = RLMCheckpoint.rows(checkpoint)
    artifact = artifact(manifest, datasets, rows, runtime_selection, checkpoint_path)
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
          "budget_remaining" => CampaignBudget.snapshot(budget),
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
      result = runtime.execute(RLMDataset.prompt_payload(job.row), job.approach, context)

      case result do
        {:ok, %{"budget_accounted" => true}} ->
          result

        {:ok, %{"usage" => usage}} ->
          case account_external_usage(budget, usage) do
            :ok -> result
            {:error, reason} -> {:error, reason}
          end

        other ->
          other
      end
    end

    if runtime == DSEx.BenchmarkTruth.RLMRuntime.DSPy do
      :global.trans({__MODULE__, budget}, execute)
    else
      execute.()
    end
  end

  defp account_external_usage(budget, usage) when is_map(usage) do
    requests = usage["requests"]

    with true <- is_integer(requests) and requests >= 0,
         {:ok, reservations} <- reserve_requests(budget, requests, []),
         :ok <- CampaignBudget.record_usage(budget, usage) do
      Enum.each(reservations, &CampaignBudget.release(budget, &1))

      case CampaignBudget.snapshot(budget)["exhausted"] do
        nil -> :ok
        dimension -> {:error, {:campaign_budget_exhausted, dimension}}
      end
    else
      false ->
        {:error, :malformed_runtime_usage}

      {:error, dimension, reservations} ->
        Enum.each(reservations, &CampaignBudget.release(budget, &1))
        {:error, {:campaign_budget_exhausted, dimension}}
    end
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
      outcome_row(key, job, {:error, {:malformed_runtime_output, Exception.message(error)}})
  end

  defp outcome_row(key, job, {:ok, outcome}) do
    validate_outcome!(outcome)

    %{
      "key" => key,
      "example_id" => job.row["id"],
      "family" => job.row["family"],
      "approach" => job.approach,
      "runtime" => job.runtime,
      "status" => "ok",
      "answer" => outcome["answer"],
      "score" => score(outcome["answer"], job.row["gold"], job.metric),
      "latency_ms" => outcome["latency_ms"],
      "usage" => outcome["usage"],
      "trace_shape" => outcome["trace_shape"],
      "trace" => outcome["trace"],
      "error" => nil
    }
  end

  defp outcome_row(key, job, {:error, reason}),
    do: %{
      "key" => key,
      "example_id" => job.row["id"],
      "family" => job.row["family"],
      "approach" => job.approach,
      "runtime" => job.runtime,
      "status" => "error",
      "answer" => nil,
      "score" => 0.0,
      "latency_ms" => 0.0,
      "usage" => %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0},
      "trace_shape" => ["error"],
      "trace" => [],
      "error" => inspect(reason)
    }

  defp validate_outcome!(%{
         "answer" => answer,
         "latency_ms" => latency,
         "usage" => usage,
         "trace_shape" => shape,
         "trace" => trace
       })
       when is_binary(answer) and answer != "" and is_number(latency) and latency >= 0 and
              is_map(usage) and is_list(shape) and shape != [] and is_list(trace) do
    unless Enum.all?(
             ~w(requests input_tokens output_tokens),
             &(is_integer(usage[&1]) and usage[&1] >= 0)
           ) and is_number(usage["usd"]) and usage["usd"] >= 0,
           do: raise(ArgumentError, "malformed RLM runtime usage")

    :ok
  end

  defp validate_outcome!(other),
    do: raise(ArgumentError, "malformed RLM runtime output: #{inspect(other)}")

  defp jobs(manifest, datasets, runtimes) do
    for runtime <- runtimes,
        approach <- RLMManifest.approach_ids(),
        runtime in manifest["approaches"][approach]["runtimes"],
        {_family, dataset} <- Enum.sort(datasets),
        row <- dataset["rows"] do
      %{
        runtime: runtime,
        approach: approach,
        row: row,
        metric: manifest["datasets"][row["family"]]["metric"]
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
        Enum.filter(
          existing,
          &(&1["runtime"] == runtime and &1["approach"] == approach and &1["status"] == "ok")
        )

      initial = %{
        "requests" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["requests"])),
        "usage" => %{
          "input_tokens" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["input_tokens"])),
          "output_tokens" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["output_tokens"])),
          "usd" => Enum.sum(Enum.map(initial_rows, & &1["usage"]["usd"]))
        }
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

  defp artifact(manifest, datasets, rows, runtime_selection, checkpoint_path) do
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
      "runner" => "dsex-rlm-campaign",
      "evidence_tier" => manifest["evidence_tier"],
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "manifest" => Map.drop(manifest, ["manifest_path"]),
      "datasets" => dataset_evidence,
      "execution" => %{
        "runtime_selection" => runtime_selection,
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

  defp dataset_status(manifest) do
    Map.new(manifest["datasets"], fn {family, spec} ->
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
        if(runtime == "dsex",
          do: DSEx.BenchmarkTruth.RLMRuntime.Dsex,
          else: DSEx.BenchmarkTruth.RLMRuntime.DSPy
        )
      )

  defp selected_runtimes!("dsex"), do: ["dsex"]
  defp selected_runtimes!("dspy"), do: ["dspy"]
  defp selected_runtimes!("both"), do: ["dsex", "dspy"]

  defp selected_runtimes!(other),
    do: raise(ArgumentError, "runtime must be dsex, dspy, or both; got #{inspect(other)}")

  defp score(answer, gold, "token_f1"), do: token_f1(answer, gold)

  defp score(answer, gold, _metric),
    do: if(normalize(answer) == normalize(gold), do: 1.0, else: 0.0)

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

  defp identity(manifest, datasets, runtime),
    do: %{
      "campaign_id" => manifest["campaign_id"],
      "manifest_sha256" => manifest["manifest_sha256"],
      "datasets" =>
        Map.new(datasets, fn {family, data} ->
          {family,
           %{"sha256" => data["sha256"], "sample_ids_sha256" => data["sample_ids_sha256"]}}
        end),
      "runtime" => runtime
    }

  defp slug(value), do: String.replace(value, ~r/[^a-zA-Z0-9_.-]+/, "-")
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
end

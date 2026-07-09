defmodule Mix.Tasks.Dsex.Benchmark.LiveMatrix do
  @moduledoc """
  Aggregate live matched-model campaign artifacts into a matrix report.

      mix dsex.benchmark.live_matrix

  This task does not call providers. It consumes campaign artifacts emitted by
  `mix dsex.benchmark.parity.aggregate` or `mix dsex.benchmark.parity.campaign`
  and reports which required live model lanes have evidence.
  """

  use Mix.Task

  @shortdoc "Aggregate live matched-model parity campaigns into a matrix"

  @default_in "benchmarks/results/dsex-dspy-parity-campaign-*.json"
  @default_out "tmp/live-matrix"
  @current_prompt_contract DSEx.BenchmarkTruth.Contract.current_prompt_contract()
  @current_evidence_policy_version 2

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          in: :string,
          out: :string,
          max_age_hours: :integer,
          campaign_id: :string,
          campaign_ids: :string,
          availability_file: :string,
          historical_unavailable_note: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input_glob = Keyword.get(opts, :in, @default_in)
    out_dir = Keyword.get(opts, :out, @default_out)
    max_age_hours = Keyword.get(opts, :max_age_hours, 168)
    campaign_ids = campaign_ids(opts)
    unavailable_notes = unavailable_notes(opts)
    File.mkdir_p!(out_dir)

    loaded =
      input_paths(input_glob, argv)
      |> Enum.map(&load_artifact/1)
      |> filter_campaigns(campaign_ids)

    skipped = Enum.count(loaded, &(not valid_identity?(&1)))

    failed_attempts =
      loaded
      |> Enum.filter(&valid_identity?/1)
      |> Enum.reject(&evidence_artifact?/1)
      |> failed_attempt_summary()

    artifacts =
      loaded
      |> Enum.filter(&valid_identity?/1)
      |> Enum.filter(&evidence_artifact?/1)
      |> best_by_identity(max_age_hours)

    report =
      matrix_report(
        artifacts,
        max_age_hours,
        skipped,
        failed_attempts,
        campaign_ids,
        unavailable_notes
      )

    out_path = Path.join(out_dir, "live-matched-model-matrix-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("live matched-model matrix: #{out_path}")
    Mix.shell().info("matrix complete: #{report["summary"]["matrix_complete"]}")
    Mix.shell().info("models covered: #{report["summary"]["models"]}")
  end

  defp input_paths(input_glob, argv) do
    [input_glob | argv]
    |> Enum.flat_map(&expand_input/1)
    |> Enum.uniq()
  end

  defp expand_input(path) do
    if File.dir?(path) do
      path |> Path.join("dsex-dspy-parity-campaign-*.json") |> Path.wildcard()
    else
      Path.wildcard(path)
    end
  end

  defp load_artifact(path) do
    artifact = path |> File.read!() |> Jason.decode!()

    artifact
    |> Map.put("__path__", path)
    |> Map.put("__mtime__", mtime_unix!(path))
  end

  defp campaign_ids(opts) do
    []
    |> add_csv(Keyword.get(opts, :campaign_id))
    |> add_csv(Keyword.get(opts, :campaign_ids))
    |> add_csv(System.get_env("DSEX_BENCH_CAMPAIGN_ID"))
    |> add_csv(System.get_env("DSEX_BENCH_CAMPAIGN_IDS"))
    |> Enum.uniq()
  end

  defp add_csv(values, nil), do: values

  defp add_csv(values, csv) do
    values ++
      (csv
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)
       |> Enum.reject(&(&1 == "")))
  end

  defp filter_campaigns(artifacts, []), do: artifacts

  defp filter_campaigns(artifacts, campaign_ids),
    do: Enum.filter(artifacts, &(&1["campaign_id"] in campaign_ids))

  defp unavailable_notes(opts) do
    file_notes =
      opts
      |> Keyword.get(:availability_file, "benchmarks/model_availability.json")
      |> unavailable_notes_from_file()

    note =
      Keyword.get(opts, :historical_unavailable_note) ||
        System.get_env("DSEX_HISTORICAL_UNAVAILABLE_NOTE")

    explicit_notes =
      case blank?(note) do
        true -> %{}
        false -> %{"historical_research" => String.trim(note)}
      end

    Map.merge(file_notes, explicit_notes)
  end

  defp unavailable_notes_from_file(nil), do: %{}

  defp unavailable_notes_from_file(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("unavailable_lanes", %{})
      |> Enum.reduce(%{}, fn
        {lane, %{"note" => note}}, acc when is_binary(note) ->
          Map.put(acc, lane, String.trim(note))

        {lane, note}, acc when is_binary(note) ->
          Map.put(acc, lane, String.trim(note))

        _other, acc ->
          acc
      end)
      |> Enum.reject(fn {_lane, note} -> blank?(note) end)
      |> Map.new()
    else
      %{}
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""

  defp best_by_identity(artifacts, max_age_hours) do
    artifacts
    |> Enum.group_by(&{&1["provider"], &1["model"]})
    |> Enum.map(fn {_identity, candidates} ->
      Enum.max_by(candidates, &artifact_rank(&1, max_age_hours))
    end)
    |> Enum.sort_by(&{&1["provider"], &1["model"]})
  end

  defp artifact_rank(artifact, max_age_hours) do
    coverage = get_in(artifact, ["coverage", "covered"]) || 0
    full_parity = if get_in(artifact, ["parity", "full_parity"]) == true, do: 1, else: 0
    full_coverage = if get_in(artifact, ["coverage", "full"]) == true, do: 1, else: 0
    latency_parity = if get_in(artifact, ["parity", "latency_parity"]) == true, do: 1, else: 0
    generation = generation_proof(artifact["generation"])
    generation_consistent = if generation["requested_consistent"], do: 1, else: 0
    generation_complete = if generation["complete"], do: 1, else: 0
    generation_matched = if generation["matched"], do: 1, else: 0
    wire_api_matched = if generation["wire_api_matched"], do: 1, else: 0
    prompt_contract_current = if generation["prompt_contract_current"], do: 1, else: 0
    evidence_policy_current = if current_evidence_policy?(artifact), do: 1, else: 0
    execution = execution_proof(artifact)
    execution_consistent = if execution["max_concurrency_consistent"], do: 1, else: 0
    instrumentation_complete = if artifact_instrumentation_complete?(artifact), do: 1, else: 0
    runtime_shape_complete = if artifact_runtime_shape_complete?(artifact), do: 1, else: 0
    fresh = if fresh?(artifact, max_age_hours), do: 1, else: 0

    {
      full_parity,
      full_coverage,
      generation_consistent,
      prompt_contract_current,
      evidence_policy_current,
      execution_consistent,
      instrumentation_complete,
      runtime_shape_complete,
      coverage,
      generation_complete,
      generation_matched,
      wire_api_matched,
      fresh,
      latency_parity,
      artifact["generated_at"] || "",
      artifact["__mtime__"]
    }
  end

  defp artifact_instrumentation_complete?(artifact) do
    get_in(model_instrumentation_summary(artifact["tasks"] || []), ["coverage", "complete"]) ==
      true
  end

  defp artifact_runtime_shape_complete?(artifact) do
    get_in(model_runtime_shape_summary(artifact["tasks"] || []), ["complete"]) == true
  end

  defp current_evidence_policy?(artifact) do
    get_in(artifact, ["evidence_policy", "version"]) == @current_evidence_policy_version
  end

  defp valid_identity?(%{"provider" => provider, "model" => model})
       when is_binary(provider) and is_binary(model),
       do: true

  defp valid_identity?(_artifact), do: false

  defp evidence_artifact?(artifact), do: (get_in(artifact, ["coverage", "covered"]) || 0) > 0

  defp failed_attempt_summary(artifacts) do
    by_lane =
      artifacts
      |> Enum.flat_map(fn artifact ->
        Enum.map(lane_tags(artifact["model"]), &{&1, artifact})
      end)
      |> Enum.group_by(fn {lane, _artifact} -> lane end, fn {_lane, artifact} -> artifact end)
      |> Map.new(fn {lane, lane_artifacts} ->
        {lane, Enum.map(lane_artifacts, &failed_attempt_row/1)}
      end)

    %{
      "count" => length(artifacts),
      "by_lane" => by_lane,
      "note" =>
        "Zero-accepted live attempts are retained as endpoint diagnostics but are not selected as DSEx-vs-DSPy parity evidence."
    }
  end

  defp failed_attempt_row(artifact) do
    %{
      "provider" => artifact["provider"],
      "model" => artifact["model"],
      "campaign_id" => artifact["campaign_id"],
      "generated_at" => artifact["generated_at"],
      "artifact" => %{
        "path" => artifact["__path__"],
        "sha256" => file_sha256(artifact["__path__"])
      },
      "source_report_count" => length(artifact["source_reports"] || []),
      "coverage" => coverage_progress(artifact["coverage"])
    }
  end

  defp matrix_report(
         artifacts,
         max_age_hours,
         skipped_malformed,
         failed_attempts,
         campaign_ids,
         unavailable_notes
       ) do
    models = Enum.map(artifacts, &model_row(&1, max_age_hours))
    required = required_lanes(models, unavailable_notes)
    complete = Enum.all?(required, fn {_lane, row} -> row["satisfied"] == true end)

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "max_age_hours" => max_age_hours,
      "campaign_ids" => campaign_ids,
      "campaign_id" => single_campaign_id(campaign_ids),
      "summary" => %{
        "models" => length(models),
        "skipped_malformed_artifacts" => skipped_malformed,
        "skipped_zero_coverage_artifacts" => failed_attempts["count"],
        "failed_attempts" => failed_attempts,
        "unavailable_lanes" => unavailable_notes,
        "full_parity_models" => Enum.count(models, & &1["full_parity"]),
        "matrix_complete" => complete,
        "required_lanes" => required,
        "prompt_contract" => matrix_prompt_contract_summary(models),
        "execution" => matrix_execution_summary(models),
        "dsex_instrumentation" => matrix_instrumentation_summary(models),
        "runtime_shape" => matrix_runtime_shape_summary(models),
        "disagreements" => matrix_disagreement_summary(models),
        "latency" => matrix_latency_summary(models),
        "transport" => matrix_transport_summary(models),
        "note" =>
          "Live matrix is complete only when required lanes satisfy their lane-specific release policies: full current low-cost coverage plus matched research-sample frontier and historical/research evidence."
      },
      "models" => models
    }
  end

  defp single_campaign_id([campaign_id]), do: campaign_id
  defp single_campaign_id(_campaign_ids), do: nil

  defp model_row(artifact, max_age_hours) do
    path = artifact["__path__"]
    covered = get_in(artifact, ["coverage", "covered"]) || 0
    expected = get_in(artifact, ["coverage", "expected"]) || 0
    full_coverage = get_in(artifact, ["coverage", "full"]) == true
    full_parity = get_in(artifact, ["parity", "full_parity"]) == true
    fresh = fresh?(artifact, max_age_hours)
    generation_proof = generation_proof(artifact["generation"])
    execution_proof = execution_proof(artifact)

    full_evidence =
      fresh and full_parity and generation_proof["requested_consistent"] and
        generation_proof["complete"] and generation_proof["matched"] and
        generation_proof["wire_api_matched"] and generation_proof["prompt_contract_current"] and
        execution_proof["max_concurrency_consistent"]

    %{
      "provider" => artifact["provider"],
      "model" => artifact["model"],
      "lane_tags" => lane_tags(artifact["model"]),
      "status" => status(full_parity, full_coverage, covered),
      "fresh" => fresh,
      "full_evidence" => full_evidence,
      "full_parity" => full_parity,
      "evidence_scale" => evidence_scale(covered, expected),
      "coverage" => artifact["coverage"],
      "coverage_progress" => coverage_progress(artifact["coverage"]),
      "parity" => artifact["parity"],
      "proof" => %{
        "fresh" => fresh,
        "full_parity" => full_parity,
        "evidence_policy_current" => current_evidence_policy?(artifact),
        "evidence_policy" => artifact["evidence_policy"],
        "max_concurrency_consistent" => execution_proof["max_concurrency_consistent"],
        "max_concurrency" => execution_proof["max_concurrency"],
        "max_concurrency_values" => execution_proof["max_concurrency_values"],
        "requested_generation_consistent" => generation_proof["requested_consistent"],
        "effective_generation_complete" => generation_proof["complete"],
        "effective_generation_matched" => generation_proof["matched"],
        "wire_api_matched" => generation_proof["wire_api_matched"],
        "prompt_contract_current" => generation_proof["prompt_contract_current"],
        "prompt_contract" => generation_proof["prompt_contract"],
        "expected_prompt_contract" => @current_prompt_contract
      },
      "score" =>
        Map.take(artifact["aggregate"] || %{}, ["dsex_score", "dspy_score", "score_delta"]),
      "latency" =>
        Map.take(artifact["aggregate"] || %{}, [
          "dsex_duration_ms",
          "dspy_duration_ms",
          "latency_ratio_dsex_over_dspy"
        ]),
      "execution" => artifact["execution"],
      "transport" => model_transport(artifact["generation"]),
      "dsex_instrumentation" => model_instrumentation_summary(artifact["tasks"] || []),
      "runtime_shape" => model_runtime_shape_summary(artifact["tasks"] || []),
      "disagreements" => model_disagreement_summary(artifact["tasks"] || []),
      "generation" => artifact["generation"],
      "cost" => cost_estimate(artifact),
      "errors" => error_summary(artifact),
      "artifact" => %{
        "path" => path,
        "sha256" => file_sha256(path),
        "generated_at" => artifact["generated_at"],
        "git_sha" => artifact["git_sha"]
      }
    }
  end

  defp required_lanes(models, unavailable_notes) do
    %{
      "current_low_cost" => required_lane(models, "current_low_cost", unavailable_notes),
      "frontier_sanity" => required_lane(models, "frontier_sanity", unavailable_notes),
      "historical_research" => required_lane(models, "historical_research", unavailable_notes)
    }
  end

  defp generation_proof(%{"effective" => %{} = effective} = generation) do
    prompt_contract = generation_prompt_contract(generation)

    %{
      "requested_consistent" => effective["requested_consistent"] != false,
      "complete" => effective["complete"] == true,
      "matched" => effective["matched"] == true,
      "wire_api_matched" => effective["wire_api_matched"] == true,
      "prompt_contract" => prompt_contract,
      "prompt_contract_current" => prompt_contract == @current_prompt_contract
    }
  end

  defp generation_proof(%{"dsex" => dsex_generation, "dspy" => dspy_generation})
       when is_map(dsex_generation) and is_map(dspy_generation) do
    dsex_effective = dsex_generation["effective"]
    dspy_effective = dspy_generation["effective"]

    prompt_contract =
      generation_prompt_contract(%{"dsex" => dsex_generation, "dspy" => dspy_generation})

    %{
      "requested_consistent" => true,
      "complete" => is_map(dsex_effective) and is_map(dspy_effective),
      "matched" => is_map(dsex_effective) and dsex_effective == dspy_effective,
      "wire_api_matched" =>
        is_binary(dsex_generation["wire_api"]) and
          wire_api_family(dsex_generation["wire_api"]) ==
            wire_api_family(dspy_generation["wire_api"]),
      "prompt_contract" => prompt_contract,
      "prompt_contract_current" => prompt_contract == @current_prompt_contract
    }
  end

  defp generation_proof(%{"consistent" => consistent} = generation) do
    prompt_contract = generation_prompt_contract(generation)

    %{
      "requested_consistent" => consistent == true,
      "complete" => false,
      "matched" => false,
      "wire_api_matched" => false,
      "prompt_contract" => prompt_contract,
      "prompt_contract_current" => prompt_contract == @current_prompt_contract
    }
  end

  defp generation_proof(_generation),
    do: %{
      "requested_consistent" => false,
      "complete" => false,
      "matched" => false,
      "wire_api_matched" => false,
      "prompt_contract" => nil,
      "prompt_contract_current" => false
    }

  defp execution_proof(%{"execution" => %{} = execution}) do
    execution_proof(execution)
  end

  defp execution_proof(%{"source_reports" => source_reports}) when is_list(source_reports) do
    values =
      source_reports
      |> Enum.map(& &1["max_concurrency"])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.uniq()
      |> Enum.sort()

    complete? =
      values != [] and length(values) <= 1 and
        source_report_count(source_reports) == length(source_reports)

    %{
      "max_concurrency_consistent" => complete?,
      "max_concurrency" => if(complete?, do: List.first(values), else: nil),
      "max_concurrency_values" => values
    }
  end

  defp execution_proof(%{"max_concurrency_consistent" => consistent} = execution) do
    %{
      "max_concurrency_consistent" => consistent == true,
      "max_concurrency" => execution["max_concurrency"],
      "max_concurrency_values" => execution["max_concurrency_values"] || []
    }
  end

  defp execution_proof(%{"max_concurrency" => max_concurrency})
       when is_integer(max_concurrency) and max_concurrency > 0 do
    %{
      "max_concurrency_consistent" => true,
      "max_concurrency" => max_concurrency,
      "max_concurrency_values" => [max_concurrency]
    }
  end

  defp execution_proof(_execution) do
    %{
      "max_concurrency_consistent" => false,
      "max_concurrency" => nil,
      "max_concurrency_values" => []
    }
  end

  defp source_report_count(source_reports) do
    Enum.count(source_reports, fn report ->
      is_integer(report["max_concurrency"]) and report["max_concurrency"] > 0
    end)
  end

  defp generation_prompt_contract(%{"value" => %{"prompt_contract" => prompt_contract}})
       when is_map(prompt_contract),
       do: prompt_contract

  defp generation_prompt_contract(%{"prompt_contract" => prompt_contract})
       when is_map(prompt_contract),
       do: prompt_contract

  defp generation_prompt_contract(%{"dsex" => dsex_generation, "dspy" => dspy_generation}) do
    case {dsex_generation["prompt_contract"], dspy_generation["prompt_contract"]} do
      {dsex, dspy} when is_binary(dsex) and is_binary(dspy) ->
        %{"dsex_req_llm" => dsex, "python_dspy" => dspy}

      _other ->
        nil
    end
  end

  defp generation_prompt_contract(_generation), do: nil

  defp wire_api_family("openai_responses"), do: "openai_responses"
  defp wire_api_family("openai_chat_completions"), do: "openai_chat_completions"
  defp wire_api_family("litellm_chat_completion"), do: "openai_chat_completions"

  defp wire_api_family("litellm_chat_completion_with_max_completion_tokens"),
    do: "openai_chat_completions"

  defp wire_api_family("anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("litellm_anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("google_generate_content"), do: "google_generate_content"
  defp wire_api_family("litellm_google_generate_content"), do: "google_generate_content"

  defp wire_api_family(other), do: other

  defp matrix_prompt_contract_summary(models) do
    current =
      Enum.filter(models, fn model ->
        get_in(model, ["proof", "prompt_contract_current"]) == true
      end)

    %{
      "models_with_current_prompt_contract" => length(current),
      "total_models" => length(models),
      "complete" => models != [] and length(current) == length(models),
      "expected" => @current_prompt_contract,
      "by_model" =>
        Map.new(models, fn model ->
          {
            model["model"],
            %{
              "current" => get_in(model, ["proof", "prompt_contract_current"]) == true,
              "prompt_contract" => get_in(model, ["proof", "prompt_contract"])
            }
          }
        end),
      "note" =>
        "Prompt-contract currency means the selected artifact was produced with the benchmark prompt/signature contract shipped by this DSEx version. Obsolete prompt contracts are retained as historical evidence, not release evidence."
    }
  end

  defp matrix_execution_summary(models) do
    consistent =
      Enum.filter(models, &get_in(&1, ["proof", "max_concurrency_consistent"]))

    %{
      "models_with_consistent_max_concurrency" => length(consistent),
      "total_models" => length(models),
      "complete" => models != [] and length(consistent) == length(models),
      "by_model" =>
        Map.new(models, fn model ->
          {
            model["model"],
            %{
              "max_concurrency_consistent" =>
                get_in(model, ["proof", "max_concurrency_consistent"]) == true,
              "max_concurrency" => get_in(model, ["proof", "max_concurrency"]),
              "max_concurrency_values" => get_in(model, ["proof", "max_concurrency_values"]) || []
            }
          }
        end),
      "note" =>
        "Release live evidence requires one consistent max_concurrency setting per selected campaign artifact, so latency and throughput claims do not mix serial and concurrent runs."
    }
  end

  defp matrix_instrumentation_summary(models) do
    instrumented =
      Enum.filter(models, &get_in(&1, ["dsex_instrumentation", "coverage", "complete"]))

    shares =
      instrumented
      |> Enum.map(&get_in(&1, ["dsex_instrumentation", "lm_duration_share", "mean"]))
      |> Enum.filter(&is_number/1)

    %{
      "models_with_complete_instrumentation" => length(instrumented),
      "total_models" => length(models),
      "complete" => models != [] and length(instrumented) == length(models),
      "mean_lm_duration_share" => average(shares),
      "dominant_latency_source" => dominant_latency_source(average(shares)),
      "note" =>
        "Complete DSEx live instrumentation means the selected campaign artifact has instrumentation for every covered row in every covered task."
    }
  end

  defp model_instrumentation_summary(tasks) do
    summaries =
      tasks
      |> Enum.map(fn task -> {task["task"], task["dsex_instrumentation"] || %{}} end)
      |> Enum.reject(fn {_task, summary} -> summary == %{} end)

    instrumented_rows =
      summaries
      |> Enum.map(fn {_task, summary} ->
        get_in(summary, ["coverage", "instrumented_rows"]) || 0
      end)
      |> Enum.sum()

    total_rows =
      summaries
      |> Enum.map(fn {_task, summary} -> get_in(summary, ["coverage", "total_rows"]) || 0 end)
      |> Enum.sum()

    shares =
      summaries
      |> Enum.map(fn {_task, summary} -> get_in(summary, ["lm_duration_share", "total"]) end)
      |> Enum.filter(&is_number/1)

    local_overhead_means =
      summaries
      |> Enum.map(fn {_task, summary} -> get_in(summary, ["local_overhead_ms", "mean_ms"]) end)
      |> Enum.filter(&is_number/1)

    %{
      "coverage" => %{
        "instrumented_rows" => instrumented_rows,
        "total_rows" => total_rows,
        "complete" =>
          summaries != [] and instrumented_rows == total_rows and
            Enum.all?(summaries, fn {_task, summary} ->
              get_in(summary, ["coverage", "complete"]) == true
            end)
      },
      "lm_calls" => sum_instrumentation(summaries, "lm_calls"),
      "json_fallbacks" => sum_instrumentation(summaries, "json_fallbacks"),
      "parse_retries" => sum_instrumentation(summaries, "parse_retries"),
      "lm_duration_share" => %{
        "mean" => average(shares),
        "min" => Enum.min(shares, fn -> nil end),
        "max" => Enum.max(shares, fn -> nil end)
      },
      "max_local_overhead_mean_ms" => Enum.max(local_overhead_means, fn -> nil end),
      "dominant_latency_source" => dominant_latency_source(average(shares)),
      "by_task" => Map.new(summaries)
    }
  end

  defp sum_instrumentation(summaries, key) do
    summaries
    |> Enum.map(fn {_task, summary} -> summary[key] || 0 end)
    |> Enum.sum()
  end

  defp matrix_runtime_shape_summary(models) do
    shaped =
      Enum.filter(models, fn model ->
        runtime_shape_has_ratios?(model["runtime_shape"])
      end)

    complete = Enum.filter(shaped, &runtime_shape_complete?(&1["runtime_shape"]))

    message_ratios =
      shaped
      |> Enum.map(& &1["runtime_shape"]["message_chars_ratio_dsex_over_dspy_mean"])
      |> Enum.filter(&is_number/1)

    raw_ratios =
      shaped
      |> Enum.map(& &1["runtime_shape"]["raw_chars_ratio_dsex_over_dspy_mean"])
      |> Enum.filter(&is_number/1)

    %{
      "models_with_runtime_shape" => length(shaped),
      "models_with_complete_runtime_shape" => length(complete),
      "total_models" => length(models),
      "complete" => models != [] and length(complete) == length(models),
      "mean_message_chars_ratio_dsex_over_dspy" => average(message_ratios),
      "mean_raw_chars_ratio_dsex_over_dspy" => average(raw_ratios),
      "by_model" => Map.new(models, &model_runtime_shape_gate_summary/1),
      "note" =>
        "Runtime shape compares DSEx and DSPy prompt/output size instrumentation. It is diagnostic evidence for efficiency, not a byte-for-byte prompt compatibility requirement."
    }
  end

  defp model_runtime_shape_gate_summary(model) do
    runtime_shape = model["runtime_shape"] || %{}

    task_coverage =
      runtime_shape
      |> Map.get("by_task", %{})
      |> Map.new(fn {task, summary} ->
        {task,
         %{
           "complete" => runtime_shape_complete?(summary),
           "coverage" => summary["coverage"] || %{}
         }}
      end)

    {model["model"],
     %{
       "complete" => runtime_shape_complete?(runtime_shape),
       "coverage" => runtime_shape["coverage"] || %{},
       "by_task" => task_coverage
     }}
  end

  defp model_runtime_shape_summary(tasks) do
    summaries =
      tasks
      |> Enum.map(fn task -> {task["task"], task["runtime_shape"] || %{}} end)
      |> Enum.reject(fn {_task, summary} -> summary == %{} end)
      |> Enum.reject(fn {_task, summary} -> get_in(summary, ["coverage", "total_rows"]) == 0 end)

    message_ratios =
      summaries
      |> Enum.map(fn {_task, summary} ->
        summary["message_chars_ratio_dsex_over_dspy_mean"]
      end)
      |> Enum.filter(&is_number/1)

    raw_ratios =
      summaries
      |> Enum.map(fn {_task, summary} -> summary["raw_chars_ratio_dsex_over_dspy_mean"] end)
      |> Enum.filter(&is_number/1)

    complete? =
      summaries != [] and length(message_ratios) == length(summaries) and
        length(raw_ratios) == length(summaries) and
        Enum.all?(summaries, fn {_task, summary} -> runtime_shape_complete?(summary) end)

    %{
      "complete" => complete?,
      "tasks_with_runtime_shape" => length(summaries),
      "coverage" => runtime_shape_coverage_summary(summaries),
      "message_chars_ratio_dsex_over_dspy_mean" => average(message_ratios),
      "raw_chars_ratio_dsex_over_dspy_mean" => average(raw_ratios),
      "by_task" => Map.new(summaries)
    }
  end

  defp runtime_shape_complete?(%{"coverage" => %{"complete" => complete}}), do: complete == true
  defp runtime_shape_complete?(_runtime_shape), do: false

  defp runtime_shape_has_ratios?(%{} = runtime_shape) do
    is_number(runtime_shape["message_chars_ratio_dsex_over_dspy_mean"]) or
      is_number(runtime_shape["raw_chars_ratio_dsex_over_dspy_mean"])
  end

  defp runtime_shape_has_ratios?(_runtime_shape), do: false

  defp runtime_shape_coverage_summary(summaries) do
    coverages =
      summaries
      |> Enum.map(fn {_task, summary} -> summary["coverage"] || %{} end)
      |> Enum.reject(&(&1 == %{}))

    %{
      "total_rows" => Enum.sum(Enum.map(coverages, &(&1["total_rows"] || 0))),
      "message_chars_comparable_rows" =>
        Enum.sum(Enum.map(coverages, &(&1["message_chars_comparable_rows"] || 0))),
      "raw_chars_comparable_rows" =>
        Enum.sum(Enum.map(coverages, &(&1["raw_chars_comparable_rows"] || 0))),
      "complete" => coverages != [] and Enum.all?(coverages, &(&1["complete"] == true))
    }
  end

  defp matrix_disagreement_summary(models) do
    summaries = Enum.map(models, &(&1["disagreements"] || %{}))

    %{
      "count" => Enum.sum(Enum.map(summaries, &(&1["count"] || 0))),
      "pass_disagreements" => Enum.sum(Enum.map(summaries, &(&1["pass_disagreements"] || 0))),
      "answer_disagreements" => Enum.sum(Enum.map(summaries, &(&1["answer_disagreements"] || 0))),
      "directions" => merge_counts(Enum.map(summaries, &(&1["directions"] || %{}))),
      "by_model" => Map.new(models, &{&1["model"], &1["disagreements"] || %{}}),
      "note" =>
        "Disagreement summaries are bounded triage evidence from the selected campaign artifacts; inspect the referenced campaign for full samples."
    }
  end

  defp model_disagreement_summary(tasks) do
    summaries =
      tasks
      |> Enum.map(fn task -> {task["task"], task["disagreements"] || %{}} end)
      |> Enum.reject(fn {_task, summary} -> summary == %{} end)

    %{
      "count" => sum_disagreement(summaries, "count"),
      "pass_disagreements" => sum_disagreement(summaries, "pass_disagreements"),
      "answer_disagreements" => sum_disagreement(summaries, "answer_disagreements"),
      "directions" =>
        merge_counts(Enum.map(summaries, fn {_task, summary} -> summary["directions"] || %{} end)),
      "by_task" => Map.new(summaries),
      "examples" =>
        summaries
        |> Enum.flat_map(fn {task, summary} ->
          summary
          |> Map.get("examples", [])
          |> Enum.map(&Map.put(&1, "task", task))
        end)
        |> Enum.sort_by(&(&1["absolute_index"] || 0))
        |> Enum.take(20)
    }
  end

  defp sum_disagreement(summaries, key) do
    summaries
    |> Enum.map(fn {_task, summary} -> summary[key] || 0 end)
    |> Enum.sum()
  end

  defp merge_counts(count_maps) do
    Enum.reduce(count_maps, %{}, fn counts, acc ->
      Enum.reduce(counts, acc, fn {key, value}, merged ->
        Map.update(merged, key, value || 0, &(&1 + (value || 0)))
      end)
    end)
  end

  defp dominant_latency_source(nil), do: "unknown"
  defp dominant_latency_source(value) when value >= 0.9, do: "provider_model"
  defp dominant_latency_source(_value), do: "local_or_mixed"

  defp matrix_latency_summary(models) do
    by_model =
      Map.new(models, fn model ->
        {
          model["model"],
          %{
            "latency_parity" => get_in(model, ["parity", "latency_parity"]) == true,
            "ratio_dsex_over_dspy" => get_in(model, ["latency", "latency_ratio_dsex_over_dspy"]),
            "dsex_duration_ms" => get_in(model, ["latency", "dsex_duration_ms"]),
            "dspy_duration_ms" => get_in(model, ["latency", "dspy_duration_ms"]),
            "transport" => model["transport"]
          }
        }
      end)

    failing =
      models
      |> Enum.filter(&(get_in(&1, ["parity", "latency_parity"]) == false))
      |> Enum.map(& &1["model"])

    %{
      "complete" => models != [] and failing == [],
      "failing_models" => failing,
      "by_model" => by_model,
      "note" =>
        "Latency parity is evaluated from the selected campaign aggregate for each model; transport records DSEx ReqLLM pool settings when the run configured them explicitly."
    }
  end

  defp matrix_transport_summary(models) do
    by_model = Map.new(models, &{&1["model"], &1["transport"]})

    %{
      "recorded_models" => Enum.count(models, &is_map(&1["transport"])),
      "total_models" => length(models),
      "by_model" => by_model,
      "note" =>
        "Nil transport means the artifact used the default ReqLLM transport profile or predates explicit transport metadata."
    }
  end

  defp model_transport(%{"value" => %{"dsex_transport" => transport}}) when is_map(transport),
    do: transport

  defp model_transport(%{"dsex" => %{"transport" => transport}}) when is_map(transport),
    do: transport

  defp model_transport(_generation), do: nil

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)

  defp required_lane(models, tag, unavailable_notes) do
    candidates = Enum.filter(models, &(tag in &1["lane_tags"]))
    best = best_lane_candidate(candidates)
    policy = lane_policy(tag)
    unavailable_note = unavailable_notes[tag]
    evidence_satisfied = Enum.any?(candidates, &lane_candidate_satisfies?(&1, policy))
    unavailable_satisfied = unavailable_note_allowed?(tag, unavailable_note)
    satisfied = evidence_satisfied or unavailable_satisfied

    %{
      "present" => candidates != [],
      "satisfied" => satisfied,
      "satisfaction" => satisfaction_status(evidence_satisfied, unavailable_satisfied),
      "availability" => availability_status(unavailable_note),
      "policy" => policy,
      "full_evidence" => Enum.any?(candidates, & &1["full_evidence"]),
      "models" => Enum.map(candidates, & &1["model"]),
      "best_model" => best && best["model"],
      "best_status" => best_status(candidates),
      "best_parity" => best && parity_summary(best["parity"]),
      "best_proof" =>
        best &&
          Map.take(best["proof"] || %{}, [
            "fresh",
            "evidence_policy_current",
            "prompt_contract_current",
            "effective_generation_complete",
            "effective_generation_matched",
            "wire_api_matched",
            "max_concurrency_consistent"
          ]),
      "coverage" => lane_coverage_progress(candidates, best),
      "cost" => lane_cost_progress(candidates, best)
    }
  end

  defp parity_summary(%{} = parity) do
    Map.take(parity, [
      "aggregate_gap",
      "max_task_score_gap",
      "strict_aggregate_gap",
      "strict_task_gap",
      "latency_parity",
      "max_latency_ratio_dsex_over_dspy"
    ])
  end

  defp parity_summary(_parity), do: nil

  defp unavailable_note_allowed?("historical_research", note) when is_binary(note), do: true
  defp unavailable_note_allowed?(_tag, _note), do: false

  defp satisfaction_status(true, _unavailable), do: "evidence"
  defp satisfaction_status(false, true), do: "explicit_unavailable"
  defp satisfaction_status(false, false), do: "unsatisfied"

  defp availability_status(note) when is_binary(note),
    do: %{
      "status" => "explicit_unavailable",
      "note" => note
    }

  defp availability_status(_note), do: %{"status" => "unresolved"}

  defp lane_policy("current_low_cost") do
    %{
      "required_scale" => "full",
      "description" =>
        "At least one current low-cost model must have full accepted canonical benchmark coverage with current prompt and matched effective generation evidence."
    }
  end

  defp lane_policy("frontier_sanity") do
    %{
      "required_scale" => "research_sample",
      "min_accepted_rows" => 200,
      "description" =>
        "At least one current frontier model must have a fresh matched research sample with score, latency, prompt-contract, and generation proof."
    }
  end

  defp lane_policy("historical_research") do
    %{
      "required_scale" => "research_sample",
      "min_accepted_rows" => 200,
      "description" =>
        "At least one historical or research-style model must have a fresh matched research sample, or the release must explicitly document unavailability outside this matrix."
    }
  end

  defp lane_policy(_tag), do: %{"required_scale" => "full"}

  defp lane_candidate_satisfies?(model, %{"required_scale" => "full"}) do
    model["full_evidence"] == true
  end

  defp lane_candidate_satisfies?(model, %{"required_scale" => "research_sample"} = policy) do
    min_rows = policy["min_accepted_rows"] || 200

    model["full_evidence"] == true or
      (base_release_proof?(model) and
         (get_in(model, ["coverage_progress", "covered_rows"]) || 0) >= min_rows and
         score_parity?(model["parity"]) and
         get_in(model, ["parity", "latency_parity"]) == true)
  end

  defp base_release_proof?(model) do
    proof = model["proof"] || %{}

    model["fresh"] == true and
      proof["requested_generation_consistent"] == true and
      proof["effective_generation_complete"] == true and
      proof["effective_generation_matched"] == true and
      proof["wire_api_matched"] == true and
      proof["prompt_contract_current"] == true and
      proof["max_concurrency_consistent"] == true
  end

  defp score_parity?(%{} = parity) do
    aggregate_gap = parity["aggregate_gap"]
    max_task_gap = parity["max_task_score_gap"]
    strict_aggregate_gap = parity["strict_aggregate_gap"] || 0.01
    strict_task_gap = parity["strict_task_gap"] || 0.01

    is_number(aggregate_gap) and is_number(max_task_gap) and
      within?(abs(aggregate_gap), strict_aggregate_gap) and
      within?(abs(max_task_gap), strict_task_gap)
  end

  defp score_parity?(_parity), do: false

  defp within?(value, threshold), do: value <= threshold + 1.0e-12

  defp best_lane_candidate([]), do: nil

  defp best_lane_candidate(candidates) do
    Enum.max_by(candidates, &lane_candidate_rank/1)
  end

  defp lane_candidate_rank(model) do
    proof = model["proof"] || %{}

    {
      if(model["full_evidence"], do: 1, else: 0),
      if(proof["prompt_contract_current"], do: 1, else: 0),
      if(proof["evidence_policy_current"], do: 1, else: 0),
      if(base_release_proof?(model), do: 1, else: 0),
      status_rank(model["status"]),
      if(model["fresh"], do: 1, else: 0),
      get_in(model, ["coverage_progress", "covered_rows"]) || 0,
      model["model"] || ""
    }
  end

  defp status_rank("full"), do: 3
  defp status_rank("research_sample"), do: 2
  defp status_rank("smoke"), do: 1
  defp status_rank(_status), do: 0

  defp best_status([]), do: "missing"

  defp best_status(candidates) do
    cond do
      Enum.any?(candidates, &(&1["status"] == "full")) -> "full"
      Enum.any?(candidates, &(&1["status"] == "research_sample")) -> "research_sample"
      Enum.any?(candidates, &(&1["status"] == "smoke")) -> "smoke"
      true -> "failing"
    end
  end

  defp lane_tags(model) do
    downcased = model |> to_string() |> String.downcase()

    cond do
      historical_research_model?(downcased) ->
        ["historical_research"]

      current_low_cost_model?(downcased) ->
        ["current_low_cost"]

      frontier_sanity_model?(downcased) ->
        ["frontier_sanity"]

      true ->
        []
    end
  end

  defp current_low_cost_model?(model),
    do: String.match?(model, ~r/(mini|nano|small|haiku|flash|lite)/)

  defp frontier_sanity_model?(model),
    do: String.match?(model, ~r/(gpt-(5(\.|$)|4\.1|4o|4$)|claude-(sonnet|opus)|gemini.*pro)/)

  defp historical_research_model?(model),
    do: String.match?(model, ~r/(3\.5|davinci|legacy|research|claude-3-|gemini-1\.)/)

  defp cost_estimate(artifact) do
    covered = get_in(artifact, ["coverage", "covered"]) || 0
    expected = get_in(artifact, ["coverage", "expected"]) || covered
    remaining = max(expected - covered, 0)
    source_count = max(length(artifact["source_reports"] || []), 1)
    input_per_example = env_int("DSEX_BENCH_INPUT_TOKENS_PER_EXAMPLE", 1_500)
    output_per_example = env_int("DSEX_BENCH_OUTPUT_TOKENS_PER_EXAMPLE", 128)
    input_tokens = covered * input_per_example * 2
    output_tokens = covered * output_per_example * 2
    remaining_input_tokens = remaining * input_per_example * 2
    remaining_output_tokens = remaining * output_per_example * 2
    full_input_tokens = expected * input_per_example * 2
    full_output_tokens = expected * output_per_example * 2
    input_usd_per_1m = env_float("DSEX_BENCH_INPUT_USD_PER_1M")
    output_usd_per_1m = env_float("DSEX_BENCH_OUTPUT_USD_PER_1M")

    usd =
      estimate_usd(input_tokens, output_tokens, input_usd_per_1m, output_usd_per_1m)

    remaining_usd =
      estimate_usd(
        remaining_input_tokens,
        remaining_output_tokens,
        input_usd_per_1m,
        output_usd_per_1m
      )

    full_usd =
      estimate_usd(full_input_tokens, full_output_tokens, input_usd_per_1m, output_usd_per_1m)

    %{
      "status" => if(usd, do: "estimated_usd", else: "token_estimate"),
      "estimated_input_tokens" => input_tokens,
      "estimated_output_tokens" => output_tokens,
      "estimated_total_tokens" => input_tokens + output_tokens,
      "estimated_usd" => usd,
      "estimated_remaining_input_tokens" => remaining_input_tokens,
      "estimated_remaining_output_tokens" => remaining_output_tokens,
      "estimated_remaining_total_tokens" => remaining_input_tokens + remaining_output_tokens,
      "estimated_remaining_usd" => remaining_usd,
      "estimated_full_input_tokens" => full_input_tokens,
      "estimated_full_output_tokens" => full_output_tokens,
      "estimated_full_total_tokens" => full_input_tokens + full_output_tokens,
      "estimated_full_usd" => full_usd,
      "assumptions" => %{
        "covered_examples" => covered,
        "expected_examples" => expected,
        "remaining_examples" => remaining,
        "source_reports" => source_count,
        "runtimes_per_example" => 2,
        "input_tokens_per_example" => input_per_example,
        "output_tokens_per_example" => output_per_example,
        "pricing_env" => %{
          "input_usd_per_1m" => input_usd_per_1m,
          "output_usd_per_1m" => output_usd_per_1m
        }
      },
      "note" =>
        if(usd,
          do:
            "Estimated from covered, remaining, and full examples for DSEx and DSPy runs using operator-supplied pricing env vars.",
          else:
            "Token-only estimate from covered, remaining, and full examples for DSEx and DSPy runs. Set DSEX_BENCH_INPUT_USD_PER_1M and DSEX_BENCH_OUTPUT_USD_PER_1M from current provider pricing to include USD estimates."
        )
    }
  end

  defp coverage_progress(coverage) when is_map(coverage) do
    covered = coverage["covered"] || 0
    expected = coverage["expected"] || covered
    remaining = max(expected - covered, 0)

    %{
      "covered_rows" => covered,
      "expected_rows" => expected,
      "remaining_rows" => remaining,
      "coverage_fraction" => ratio(covered, expected),
      "coverage_percent" => percent(covered, expected),
      "full" => coverage["full"] == true
    }
  end

  defp coverage_progress(_coverage), do: coverage_progress(%{})

  defp lane_coverage_progress([], _best) do
    %{
      "covered_rows" => 0,
      "expected_rows" => 0,
      "remaining_rows" => 0,
      "coverage_fraction" => nil,
      "coverage_percent" => nil,
      "full" => false
    }
  end

  defp lane_coverage_progress(models, best) do
    best_progress = (best && best["coverage_progress"]) || lane_coverage_progress([], nil)
    covered = sum_model_coverage(models, "covered_rows")
    expected = sum_model_coverage(models, "expected_rows")

    best_progress
    |> Map.put("best_model", best && best["model"])
    |> Map.put("candidate_count", length(models))
    |> Map.put("cumulative", %{
      "covered_rows" => covered,
      "expected_rows" => expected,
      "remaining_rows" => max(expected - covered, 0),
      "coverage_fraction" => ratio(covered, expected),
      "coverage_percent" => percent(covered, expected),
      "full" => expected > 0 and covered >= expected
    })
  end

  defp sum_model_coverage(models, key) do
    models
    |> Enum.map(&(get_in(&1, ["coverage_progress", key]) || 0))
    |> Enum.sum()
  end

  defp lane_cost_progress(models, best) do
    if models == [] do
      %{
        "estimated_remaining_total_tokens" => 0,
        "estimated_full_total_tokens" => 0,
        "estimated_remaining_usd" => nil,
        "estimated_full_usd" => nil,
        "status" => "token_estimate"
      }
    else
      best_cost = (best && best["cost"]) || %{}

      best_cost
      |> Map.put("best_model", best && best["model"])
      |> Map.put("candidate_count", length(models))
      |> Map.put("cumulative", %{
        "estimated_remaining_total_tokens" =>
          sum_model_cost(models, "estimated_remaining_total_tokens"),
        "estimated_full_total_tokens" => sum_model_cost(models, "estimated_full_total_tokens"),
        "estimated_remaining_usd" => sum_model_usd(models, "estimated_remaining_usd"),
        "estimated_full_usd" => sum_model_usd(models, "estimated_full_usd"),
        "status" =>
          if(Enum.all?(models, &is_number(get_in(&1, ["cost", "estimated_full_usd"]))),
            do: "estimated_usd",
            else: "token_estimate"
          )
      })
    end
  end

  defp sum_model_cost(models, key) do
    models
    |> Enum.map(&(get_in(&1, ["cost", key]) || 0))
    |> Enum.sum()
  end

  defp sum_model_usd(models, key) do
    values =
      models
      |> Enum.map(&get_in(&1, ["cost", key]))
      |> Enum.filter(&is_number/1)

    if length(values) == length(models), do: Float.round(Enum.sum(values), 6)
  end

  defp estimate_usd(_input_tokens, _output_tokens, nil, _output_usd_per_1m), do: nil
  defp estimate_usd(_input_tokens, _output_tokens, _input_usd_per_1m, nil), do: nil

  defp estimate_usd(input_tokens, output_tokens, input_usd_per_1m, output_usd_per_1m) do
    Float.round(
      input_tokens / 1_000_000 * input_usd_per_1m +
        output_tokens / 1_000_000 * output_usd_per_1m,
      6
    )
  end

  defp ratio(_numerator, denominator) when denominator in [nil, 0], do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  defp percent(numerator, denominator) do
    case ratio(numerator, denominator) do
      nil -> nil
      value -> Float.round(value * 100, 4)
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> default
  end

  defp env_float(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.to_float(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp status(true, true, _covered), do: "full"
  defp status(false, true, _covered), do: "failing"
  defp status(_full_parity, _full_coverage, covered) when covered >= 200, do: "research_sample"
  defp status(_full_parity, _full_coverage, covered) when covered > 0, do: "smoke"
  defp status(_full_parity, _full_coverage, _covered), do: "missing"

  defp evidence_scale(covered, expected) when expected > 0 and covered >= expected, do: "full"
  defp evidence_scale(covered, _expected) when covered >= 200, do: "research_sample"
  defp evidence_scale(covered, _expected) when covered > 0, do: "smoke"
  defp evidence_scale(_covered, _expected), do: "missing"

  defp error_summary(artifact) do
    artifact
    |> Map.get("tasks", [])
    |> Enum.map(fn task ->
      %{
        "task" => task["task"],
        "dsex_errors" => length(task["dsex_errors"] || []),
        "dspy_errors" => length(task["dspy_errors"] || [])
      }
    end)
  end

  defp fresh?(artifact, max_age_hours) do
    case artifact_generated_at(artifact) do
      {:ok, datetime} ->
        DateTime.diff(DateTime.utc_now(), datetime, :second) <= max_age_hours * 60 * 60

      :error ->
        System.system_time(:second) - mtime_unix!(artifact["__path__"]) <= max_age_hours * 60 * 60
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

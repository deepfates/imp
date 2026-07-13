defmodule DSEx.BenchmarkTruth.RLMProtocol do
  @moduledoc false

  @expected %{
    "s_niah" => %{"logical" => 50, "rows" => 50},
    "browsecomp_plus" => %{"logical" => 150, "rows" => 150, "docs" => 1000},
    "oolong" => %{"logical" => 50, "rows" => 50, "split" => "trec_coarse"},
    "oolong_pairs" => %{
      "logical" => 20,
      "rows" => 220,
      "split" => "trec_coarse",
      "grid" => Enum.map(10..20, &(:math.pow(2, &1) |> round()))
    },
    "longbench_v2_codeqa" => %{"logical" => 50, "rows" => 50}
  }
  @paper_rlm_methods ~w(base_model codeact_bm25 codeact_subcalls compaction_agent opencode opencode_context_offloading rlm_depth_0 rlm_depth_1 rlm_depth_2 rlm_depth_3)
  @paper_model_method_matrix %{
    "gpt_5" => @paper_rlm_methods,
    "qwen3_coder_480b_a35b" => @paper_rlm_methods,
    "claude_opus_4_1" => ~w(claude_code claude_code_context_offloading)
  }
  @paper_runtimes ~w(dsex standalone_rlm)
  @published_pairs_scorer_sha256 nil
  @sha256 ~r/\A[0-9a-f]{64}\z/

  def evaluate(artifact) do
    rows = artifact["rows"] || []
    datasets = artifact["datasets"] || %{}
    manifest = artifact["manifest"] || %{}

    checks = [
      check("tier", artifact["evidence_tier"] == "t3_paper_scale"),
      check("authorities", authority_complete?(manifest)),
      check("models", model_roles_complete?(manifest)),
      check("exact_paper_manifest", exact_paper_manifest?(manifest)),
      check("families", Map.keys(datasets) |> Enum.sort() == Map.keys(@expected) |> Enum.sort()),
      check("dataset_protocol", dataset_protocol?(datasets)),
      check("dataset_authority", dataset_authority?(manifest, datasets)),
      check("metric_contracts", metric_contracts?(manifest)),
      check("official_scorers", official_scorers?(artifact, rows)),
      check("dataset_key_sets", dataset_key_sets?(rows, datasets)),
      check("approaches", approach_coverage?(rows, datasets)),
      check("runtime_comparison", runtime_coverage?(rows, datasets)),
      check("call_semantics_equivalent", call_semantics_equivalent?(rows)),
      check("cost_accounting", rows != [] and Enum.all?(rows, &valid_cost_row?/1)),
      check("row_outcomes", rows != [] and Enum.all?(rows, &valid_row?/1)),
      check("evidence", evidence_complete?(rows, datasets)),
      check("deviations", is_list(manifest["deviations"]))
    ]

    %{"paper_protocol_complete" => Enum.all?(checks, & &1["passing"]), "checks" => checks}
  end

  defp exact_paper_manifest?(manifest) do
    protocol = manifest["paper_protocol"] || %{}

    protocol["reference_runtime"] == "alexzhang13_rlm" and
      protocol["reference_commit"] == "72d6940142ddfb84ee6be573dc999a37e633e671" and
      protocol["model_method_matrix"] == @paper_model_method_matrix and
      protocol["dataset_selection"] == %{
        "s_niah" => "published_paper_frozen_instances",
        "browsecomp_plus" => "published_paper_frozen_ids_and_document_lists",
        "oolong_pairs" => "published_paper_gold_and_scorer"
      } and
      protocol["compaction"] == "iterative_threshold_agent" and
      protocol["max_llm_calls_scope"] == "subcalls_only" and
      protocol["provider_call_accounting"] == "root_and_subcalls" and
      protocol["cache"] == false and
      protocol["reasoning_profiles"] == %{
        "gpt_5" => "medium",
        "qwen3_coder_480b_a35b" => "paper_qwen_sampling",
        "claude_opus_4_1" => "claude_code_v2.0.0_default"
      } and protocol["runtime_matrix"] == @paper_runtimes
  end

  defp dataset_protocol?(datasets) do
    Enum.all?(@expected, fn {family, expected} ->
      case datasets[family] do
        %{} = actual ->
          keys = actual["evaluated_keys"]

          actual["logical_instances"] == expected["logical"] and
            actual["evaluated_rows"] == expected["rows"] and
            (expected["split"] == nil or actual["split"] == expected["split"]) and
            (expected["docs"] == nil or actual["docs_per_instance"] == expected["docs"]) and
            (expected["grid"] == nil or actual["context_grid"] == expected["grid"]) and
            is_binary(actual["sha256"]) and Regex.match?(@sha256, actual["sha256"]) and
            is_binary(actual["sample_ids_sha256"]) and
            is_list(keys) and length(keys) == expected["rows"] and
            length(Enum.uniq(keys)) == length(keys)

        _ ->
          false
      end
    end)
  end

  defp metric_contracts?(manifest) do
    metrics =
      Map.new(manifest["datasets"] || %{}, fn {family, spec} -> {family, spec["metric"]} end)

    metrics == %{
      "s_niah" => "exact_match",
      "browsecomp_plus" => "official_llm_judge",
      "oolong" => "oolong_official",
      "oolong_pairs" => "set_f1",
      "longbench_v2_codeqa" => "multiple_choice_accuracy"
    }
  end

  defp dataset_authority?(_manifest, _datasets), do: false

  defp official_scorers?(artifact, rows) do
    scorers = artifact["official_scorers"] || %{}
    browse = scorers["browsecomp_plus"] || %{}
    oolong = scorers["oolong"] || %{}
    pairs = scorers["oolong_pairs"] || %{}

    browse["answer"] == "pinned_official_llm_judge" and
      browse["retrieval"] == "trec_eval_evidence_and_gold_qrels" and
      is_binary(browse["judge_model"]) and is_binary(browse["prompt_sha256"]) and
      Regex.match?(@sha256, browse["prompt_sha256"]) and
      oolong["contract"] == "numeric_0.75_abs_error_else_exact" and
      pairs["contract"] == "normalized_unordered_pair_set_f1" and
      pairs["authority"] == "paper_published_run_all.py" and
      is_binary(@published_pairs_scorer_sha256) and
      pairs["source_sha256"] == @published_pairs_scorer_sha256 and
      rows
      |> Enum.filter(&(&1["family"] == "browsecomp_plus"))
      |> then(&(&1 != [] and Enum.all?(&1, fn row -> valid_browse_scorer?(row, browse) end)))
  end

  defp valid_browse_scorer?(row, scorer) do
    evidence = row["scorer_evidence"] || %{}
    judge = evidence["judge"] || %{}
    retrieval = evidence["retrieval"] || %{}

    judge["model"] == scorer["judge_model"] and
      judge["prompt_sha256"] == scorer["prompt_sha256"] and
      is_binary(judge["input_sha256"]) and Regex.match?(@sha256, judge["input_sha256"]) and
      is_binary(judge["raw_verdict"]) and String.trim(judge["raw_verdict"]) != "" and
      judge["verdict"] in ~w(correct incorrect) and
      is_binary(retrieval["qrels_sha256"]) and Regex.match?(@sha256, retrieval["qrels_sha256"]) and
      is_binary(retrieval["run_sha256"]) and Regex.match?(@sha256, retrieval["run_sha256"]) and
      is_binary(retrieval["trec_eval_version"]) and
      Enum.all?(~w(evidence_recall gold_recall ndcg), &is_number(retrieval[&1]))
  end

  defp dataset_key_sets?(rows, datasets) do
    expected = expected_keys(datasets)

    expected != MapSet.new() and
      Enum.all?(rows_by_lane(rows), fn {_lane, lane_rows} ->
        actual = MapSet.new(lane_rows, &row_key/1)
        length(lane_rows) == MapSet.size(actual) and actual == expected
      end)
  end

  defp approach_coverage?(rows, datasets) do
    expected = expected_keys(datasets)

    Enum.all?(@paper_runtimes, fn runtime ->
      Enum.all?(@paper_model_method_matrix, fn {model_family, methods} ->
        Enum.all?(methods, fn approach ->
          lane =
            Enum.filter(
              rows,
              &(&1["runtime"] == runtime and &1["model_family"] == model_family and
                  &1["approach"] == approach)
            )

          length(lane) == MapSet.size(expected) and MapSet.new(lane, &row_key/1) == expected
        end)
      end)
    end)
  end

  defp runtime_coverage?(rows, datasets) do
    expected = expected_keys(datasets)

    Enum.all?(@paper_runtimes, fn runtime ->
      runtime_rows = Enum.filter(rows, &(&1["runtime"] == runtime))
      MapSet.new(runtime_rows, &row_key/1) == expected
    end)
  end

  defp call_semantics_equivalent?(rows) do
    rlm_rows = Enum.filter(rows, &String.starts_with?(&1["approach"] || "", "rlm_depth_"))

    rlm_rows != [] and
      Enum.all?(rlm_rows, fn row ->
        semantics = row["call_semantics"] || %{}

        with {depth, ""} <-
               row["approach"] |> String.replace_prefix("rlm_depth_", "") |> Integer.parse(),
             provider when is_integer(provider) <- semantics["provider_calls"],
             root when is_integer(root) <- semantics["root_calls"],
             sub when is_integer(sub) <- semantics["sub_calls"],
             configured when is_integer(configured) <- semantics["configured_max_depth"],
             observed when is_integer(observed) <- semantics["max_observed_depth"] do
          semantics["max_llm_calls_scope"] == "subcalls_only" and
            provider == root + sub and depth == configured and observed <= configured
        else
          _ -> false
        end
      end)
  end

  defp evidence_complete?(rows, datasets) do
    browse = datasets["browsecomp_plus"] || %{}

    browse["evidence_in_dataset"] == true and
      Enum.all?(rows, fn row ->
        is_list(row["trace_shape"]) and row["trace_shape"] != [] and
          is_list(row["trace"]) and Enum.all?(row["trace"], &valid_trace_event?/1) and
          valid_provenance?(row, datasets)
      end)
  end

  defp valid_row?(row) do
    exact =
      Map.keys(row) |> Enum.sort() ==
        Enum.sort(
          ~w(key example_id query_id context_size family model_family approach runtime status answer score latency_ms usage metric scorer_evidence trace_shape trace call_semantics provenance error)
        )

    usage = row["usage"] || %{}
    semantics = row["call_semantics"] || %{}

    exact and row["status"] == "ok" and is_number(row["score"]) and is_number(row["latency_ms"]) and
      is_integer(usage["requests"]) and usage["requests"] > 0 and
      is_integer(usage["input_tokens"]) and usage["input_tokens"] > 0 and
      is_integer(usage["output_tokens"]) and usage["output_tokens"] > 0 and
      is_number(usage["usd"]) and usage["usd"] >= 0 and
      valid_call_semantics?(semantics, usage) and valid_cost_usage?(usage)
  end

  defp valid_cost_row?(row), do: row["status"] == "ok" and valid_cost_usage?(row["usage"])

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

  defp valid_call_semantics?(semantics, usage) do
    Enum.all?(
      ~w(provider_calls root_calls sub_calls configured_max_depth max_observed_depth),
      fn key ->
        is_integer(semantics[key]) and semantics[key] >= 0
      end
    ) and semantics["provider_calls"] == usage["requests"] and
      semantics["provider_calls"] == semantics["root_calls"] + semantics["sub_calls"] and
      semantics["max_observed_depth"] <= semantics["configured_max_depth"] and
      is_binary(semantics["max_llm_calls_scope"])
  end

  defp valid_trace_event?(event) when is_map(event),
    do:
      is_integer(event["index"]) and event["index"] >= 0 and is_binary(event["action"]) and
        is_integer(event["bytes"]) and event["bytes"] >= 0 and is_binary(event["sha256"]) and
        Regex.match?(@sha256, event["sha256"])

  defp valid_trace_event?(_), do: false

  defp valid_provenance?(row, datasets) do
    provenance = row["provenance"] || %{}
    dataset = datasets[row["family"]] || %{}

    provenance["dataset_key"] == row["example_id"] and
      provenance["dataset_sha256"] == dataset["sha256"] and
      is_binary(provenance["manifest_sha256"]) and
      Regex.match?(@sha256, provenance["manifest_sha256"])
  end

  defp expected_keys(datasets) do
    Enum.reduce(datasets, MapSet.new(), fn {family, dataset}, acc ->
      Enum.reduce(dataset["evaluated_keys"] || [], acc, fn key, inner ->
        MapSet.put(inner, {family, key["example_id"], key["query_id"], key["context_size"]})
      end)
    end)
  end

  defp rows_by_lane(rows),
    do: Enum.group_by(rows, &{&1["runtime"], &1["model_family"], &1["approach"]})

  defp row_key(row),
    do: {row["family"], row["example_id"], row["query_id"], row["context_size"]}

  defp authority_complete?(manifest),
    do:
      get_in(manifest, ["authorities", "paper", "arxiv"]) == "2512.24601v3" and
        get_in(manifest, ["authorities", "rlm", "commit"]) ==
          "72d6940142ddfb84ee6be573dc999a37e633e671" and
        get_in(manifest, ["authorities", "dspy", "version"]) == "3.3.0b1"

  defp model_roles_complete?(manifest) do
    Enum.all?(~w(root submodel compaction), fn role ->
      model = get_in(manifest, ["models", role]) || %{}

      is_binary(model["logical"]) and is_binary(model["dsex"]) and is_binary(model["dspy"]) and
        model["reasoning"] == "medium" and is_integer(model["max_output_tokens"]) and
        model["max_output_tokens"] > 0
    end)
  end

  defp check(id, passing), do: %{"id" => id, "passing" => passing == true}
end

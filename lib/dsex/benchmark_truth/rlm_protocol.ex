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
  @approaches ~w(direct simple_retrieval compaction rlm)

  def evaluate(artifact) do
    rows = artifact["rows"] || []
    datasets = artifact["datasets"] || %{}
    manifest = artifact["manifest"] || %{}
    runtime_selection = get_in(artifact, ["execution", "runtime_selection"])

    checks = [
      check("tier", artifact["evidence_tier"] == "t3_paper_scale"),
      check("authorities", authority_complete?(manifest)),
      check("models", model_roles_complete?(manifest)),
      check("families", Map.keys(datasets) |> Enum.sort() == Map.keys(@expected) |> Enum.sort()),
      check("dataset_protocol", dataset_protocol?(datasets)),
      check("approaches", approach_coverage?(rows, runtime_selection, datasets)),
      check(
        "runtime_comparison",
        runtime_selection == "both" and runtime_rlm_coverage?(rows, datasets)
      ),
      check("row_outcomes", rows != [] and Enum.all?(rows, &valid_row?/1)),
      check("evidence", evidence_complete?(rows, datasets)),
      check("deviations", is_list(manifest["deviations"]))
    ]

    %{"paper_protocol_complete" => Enum.all?(checks, & &1["passing"]), "checks" => checks}
  end

  defp dataset_protocol?(datasets) do
    Enum.all?(@expected, fn {family, expected} ->
      case datasets[family] do
        %{} = actual ->
          actual["logical_instances"] == expected["logical"] and
            actual["evaluated_rows"] == expected["rows"] and
            (expected["split"] == nil or actual["split"] == expected["split"]) and
            (expected["docs"] == nil or actual["docs_per_instance"] == expected["docs"]) and
            (expected["grid"] == nil or actual["context_grid"] == expected["grid"]) and
            is_binary(actual["sha256"]) and byte_size(actual["sha256"]) == 64 and
            is_binary(actual["sample_ids_sha256"])

        _ ->
          false
      end
    end)
  end

  defp approach_coverage?(rows, runtime, datasets) do
    expected_rows = Enum.sum(Enum.map(datasets, fn {_k, v} -> v["evaluated_rows"] || 0 end))
    runtimes = if(runtime == "both", do: ~w(dsex dspy), else: [runtime])

    Enum.all?(runtimes, fn selected ->
      Enum.all?(@approaches, fn approach ->
        Enum.count(
          rows,
          &(&1["runtime"] == selected and &1["approach"] == approach and &1["status"] == "ok")
        ) == expected_rows
      end)
    end)
  end

  defp runtime_rlm_coverage?(rows, datasets) do
    expected_rows = Enum.sum(Enum.map(datasets, fn {_k, v} -> v["evaluated_rows"] || 0 end))

    Enum.all?(~w(dsex dspy), fn runtime ->
      Enum.count(
        rows,
        &(&1["runtime"] == runtime and &1["approach"] == "rlm" and &1["status"] == "ok")
      ) == expected_rows
    end)
  end

  defp evidence_complete?(rows, datasets) do
    browse = datasets["browsecomp_plus"] || %{}

    browse["evidence_in_dataset"] == true and
      Enum.all?(rows, &(is_list(&1["trace_shape"]) and &1["trace_shape"] != []))
  end

  defp valid_row?(row) do
    exact =
      Map.keys(row) |> Enum.sort() ==
        Enum.sort(
          ~w(key example_id family approach runtime status answer score latency_ms usage trace_shape trace error)
        )

    usage = row["usage"] || %{}

    exact and row["status"] == "ok" and is_number(row["score"]) and is_number(row["latency_ms"]) and
      Enum.all?(
        ~w(requests input_tokens output_tokens),
        &(is_integer(usage[&1]) and usage[&1] >= 0)
      ) and is_number(usage["usd"])
  end

  defp authority_complete?(manifest),
    do:
      get_in(manifest, ["authorities", "paper", "arxiv"]) == "2512.24601v3" and
        get_in(manifest, ["authorities", "rlm", "commit"]) ==
          "72d6940142ddfb84ee6be573dc999a37e633e671" and
        get_in(manifest, ["authorities", "dspy", "version"]) == "3.3.0b1"

  defp model_roles_complete?(manifest),
    do: Enum.all?(~w(root submodel compaction), &is_map(get_in(manifest, ["models", &1])))

  defp check(id, passing), do: %{"id" => id, "passing" => passing == true}
end

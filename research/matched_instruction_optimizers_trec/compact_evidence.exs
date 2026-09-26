Code.require_file("contract.exs", __DIR__)
Code.require_file("aggregate.exs", __DIR__)

defmodule MatchedInstructionOptimizersTREC.CompactEvidence do
  @moduledoc false
  @repo_root Path.expand("../..", __DIR__)

  alias MatchedInstructionOptimizersTREC.Aggregator

  def write!(
        manifest_path,
        imp_raw_path,
        upstream_raw_path,
        original_aggregate_path,
        outcome_path,
        output_dir
      ) do
    File.mkdir_p!(output_dir)
    outcome = outcome_path |> File.read!() |> Jason.decode!()
    verify_raw_source!(outcome, "imp", imp_raw_path)
    verify_raw_source!(outcome, "upstream", upstream_raw_path)
    verify_raw_source!(outcome, "aggregate", original_aggregate_path)

    imp_path = Path.join(output_dir, "imp-scored-rows.json")
    upstream_path = Path.join(output_dir, "upstream-scored-rows.json")
    aggregate_path = Path.join(output_dir, "aggregate-recomputed.json")
    receipt_path = Path.join(output_dir, "recomputation.json")

    imp = compact_result!(imp_raw_path, "imp")
    upstream = compact_result!(upstream_raw_path, "upstream")
    write_json!(imp_path, imp)
    write_json!(upstream_path, upstream)

    aggregate = Aggregator.aggregate!(manifest_path, imp_path, upstream_path)
    original_aggregate = original_aggregate_path |> File.read!() |> Jason.decode!()

    unless aggregate == original_aggregate do
      raise ArgumentError, "compact rows do not reproduce the original raw aggregate"
    end

    write_json!(aggregate_path, aggregate)

    receipt = %{
      "schema_version" => 1,
      "kind" => "matched_trec_public_row_recomputation",
      "claim_boundary" =>
        "compact scored-row inputs reproduce the committed aggregate; raw provider traces remain private local evidence",
      "source_outcome" => file_receipt!(outcome_path),
      "inputs" => %{
        "imp" => file_receipt!(imp_path),
        "upstream" => file_receipt!(upstream_path)
      },
      "aggregate" => file_receipt!(aggregate_path),
      "raw_sources" => %{
        "imp" => source_receipt!(imp_raw_path),
        "upstream" => source_receipt!(upstream_raw_path),
        "aggregate" => source_receipt!(original_aggregate_path)
      }
    }

    write_json!(receipt_path, receipt)
  end

  defp compact_result!(path, runtime) do
    raw = path |> File.read!() |> Jason.decode!()

    unless raw["schema_version"] == 3 and raw["runtime"] == runtime and
             raw["status"] == "complete" do
      raise ArgumentError, "#{runtime} raw result is not a complete schema-3 result"
    end

    %{
      "schema_version" => 3,
      "runtime" => runtime,
      "status" => "complete",
      "manifest_sha256" => raw["manifest_sha256"],
      "source_commits" => raw["source_commits"],
      "source_raw" => source_receipt!(path),
      "call_budgets" => raw["call_budgets"],
      "seeds" => Enum.map(raw["seeds"], &compact_seed!/1)
    }
  end

  defp verify_raw_source!(outcome, runtime, path) do
    claimed = get_in(outcome, ["raw_retained_artifacts", runtime])
    actual = source_receipt!(path)

    unless claimed["bytes"] == actual["bytes"] and claimed["sha256"] == actual["sha256"] do
      raise ArgumentError, "#{runtime} raw result does not match the committed outcome receipt"
    end
  end

  defp compact_seed!(seed) do
    %{
      "seed" => seed["seed"],
      "arms" => Enum.map(seed["arms"], &compact_arm!/1)
    }
  end

  defp compact_arm!(arm) do
    rows = %{
      "selection" => Enum.map(get_in(arm, ["rows", "selection"]), &compact_row!/1),
      "held_out" => Enum.map(get_in(arm, ["rows", "held_out"]), &compact_row!/1)
    }

    %{
      "arm" => arm["arm"],
      "seed" => arm["seed"],
      "artifact_sha256" => arm["artifact_sha256"],
      "artifact_payload_sha256" => arm["artifact_payload_sha256"] || arm["payload_sha256"],
      "selected_parameters_sha256" => sha256(Jason.encode!(arm["selected_parameters"])),
      "preheld_call_counts" => arm["preheld_call_counts"],
      "held_out_call_counts" => arm["held_out_call_counts"],
      "selection" => summarize(rows["selection"]),
      "held_out" => summarize(rows["held_out"]),
      "rows" => rows
    }
  end

  defp compact_row!(row) do
    %{
      "source_id" => row["source_id"],
      "expected" => row["expected"],
      "parsed_route" => row["parsed_route"],
      "correct" => row["correct"],
      "error" => compact_error(row["error"])
    }
  end

  defp compact_error(nil), do: nil
  defp compact_error(%{"__imp_type__" => "atom", "value" => "nil"}), do: nil
  defp compact_error(error) when is_map(error), do: Map.take(error, ~w(type message))
  defp compact_error(error), do: inspect(error)

  defp summarize(rows) do
    %{
      "accuracy" => Enum.count(rows, & &1["correct"]) / length(rows),
      "macro_f1" => macro_f1(rows),
      "parse_errors" => Enum.count(rows, &(not is_nil(&1["error"]))),
      "count" => length(rows)
    }
  end

  defp macro_f1(rows) do
    ~w(K11 K47)
    |> Enum.map(fn route ->
      tp = Enum.count(rows, &(&1["expected"] == route and &1["parsed_route"] == route))
      fp = Enum.count(rows, &(&1["expected"] != route and &1["parsed_route"] == route))
      fn_ = Enum.count(rows, &(&1["expected"] == route and &1["parsed_route"] != route))
      if 2 * tp + fp + fn_ == 0, do: 0.0, else: 2 * tp / (2 * tp + fp + fn_)
    end)
    |> then(&(Enum.sum(&1) / 2))
  end

  defp source_receipt!(path) do
    receipt = file_receipt!(path)
    Map.put(receipt, "availability", "local_uncommitted_raw_trace")
  end

  defp file_receipt!(path) do
    bytes = File.read!(path)

    %{
      "path" => Path.relative_to(Path.expand(path), @repo_root),
      "bytes" => byte_size(bytes),
      "sha256" => sha256(bytes)
    }
  end

  defp write_json!(path, value) do
    File.write!(path, Jason.encode!(value, pretty: true) <> "\n")
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

argv =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

case argv do
  [manifest, imp_raw, upstream_raw, original_aggregate, outcome, output_dir] ->
    MatchedInstructionOptimizersTREC.CompactEvidence.write!(
      manifest,
      imp_raw,
      upstream_raw,
      original_aggregate,
      outcome,
      output_dir
    )

  _ ->
    raise "usage: mix run compact_evidence.exs -- MANIFEST IMP_RAW UPSTREAM_RAW ORIGINAL_AGGREGATE OUTCOME OUTPUT_DIR"
end

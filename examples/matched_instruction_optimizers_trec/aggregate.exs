defmodule MatchedInstructionOptimizersTREC.Aggregator do
  @moduledoc false
  @arms ~w(baseline gepa mipro_v2)
  @routes ~w(K11 K47)

  def aggregate!(manifest_path, imp_path, upstream_path) do
    manifest = MatchedInstructionOptimizersTREC.Contract.load!(manifest_path)
    results = %{"imp" => load_result!(imp_path), "upstream" => load_result!(upstream_path)}
    validate_pair!(results, manifest)

    metrics =
      Map.new(results, fn {runtime, result} ->
        {runtime, recompute_runtime!(result, manifest)}
      end)

    %{
      "schema_version" => 2,
      "kind" => "matched_instruction_optimizer_diagnostic_aggregate",
      "manifest_sha256" => manifest["manifest_sha256"],
      "seed_count" => length(manifest["seeds"]),
      "metrics" => metrics,
      "within_runtime" =>
        Map.new(metrics, fn {runtime, by_seed} ->
          {runtime,
           Map.new(~w(gepa mipro_v2), fn arm ->
             {arm, paired_delta(by_seed, arm, "baseline")}
           end)}
        end),
      "imp_minus_upstream" =>
        Map.new(@arms, fn arm ->
          {arm, paired_runtime_delta(metrics["imp"], metrics["upstream"], arm)}
        end),
      "uncertainty" => %{
        "method" => "paired_seed_delta_with_exact_observed_range",
        "is_confidence_interval" => false,
        "warning" =>
          "This bounded diagnostic has one seed; its observed range is a point and supports no uncertainty inference."
      },
      "claim_boundary" =>
        "bounded local diagnostic only; not flagship parity, general effectiveness, or BEAM superiority"
    }
  end

  defp load_result!(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp validate_pair!(results, manifest) do
    for {runtime, result} <- results do
      unless result["schema_version"] == 2 and result["runtime"] == runtime and
               result["status"] == "complete" and
               result["manifest_sha256"] == manifest["manifest_sha256"] do
        raise ArgumentError, "#{runtime} result is not a complete result for this manifest"
      end
    end

    unless results["imp"]["source_commits"] == results["upstream"]["source_commits"],
      do: raise(ArgumentError, "runtime source identities differ")
  end

  defp recompute_runtime!(result, manifest) do
    seeds = result["seeds"]

    unless Enum.map(seeds, & &1["seed"]) == manifest["seeds"],
      do: raise(ArgumentError, "#{result["runtime"]} seed order drift")

    Map.new(seeds, fn seed_result ->
      arms = seed_result["arms"]

      unless Enum.map(arms, & &1["arm"]) == @arms,
        do: raise(ArgumentError, "#{result["runtime"]} arm order drift")

      {Integer.to_string(seed_result["seed"]),
       Map.new(arms, fn arm ->
         splits = arm["rows"]

         recomputed = %{
           "selection" =>
             recompute_rows!(
               splits["selection"],
               manifest["dataset"]["splits"]["selection_ids"]
             ),
           "held_out" =>
             recompute_rows!(
               splits["held_out"],
               manifest["dataset"]["splits"]["held_out_ids"]
             )
         }

         assert_summary!(arm["selection"], recomputed["selection"], "selection")
         assert_summary!(arm["held_out"], recomputed["held_out"], "held_out")
         {arm["arm"], recomputed}
       end)}
    end)
  end

  defp recompute_rows!(rows, expected_ids) when is_list(rows) do
    unless Enum.map(rows, & &1["source_id"]) == expected_ids,
      do: raise(ArgumentError, "result row identity/order drift")

    unless Enum.all?(rows, fn row ->
             row["expected"] in @routes and
               (is_nil(row["parsed_route"]) or row["parsed_route"] in @routes) and
               row["correct"] == (row["expected"] == row["parsed_route"])
           end),
           do: raise(ArgumentError, "result row score fields are inconsistent")

    %{
      "accuracy" => Enum.count(rows, & &1["correct"]) / length(rows),
      "macro_f1" => macro_f1(rows),
      "parse_errors" => Enum.count(rows, &(not is_nil(&1["error"]))),
      "count" => length(rows)
    }
  end

  defp recompute_rows!(_, _), do: raise(ArgumentError, "result rows must be a list")

  defp assert_summary!(claimed, recomputed, split) do
    unless claimed == recomputed,
      do: raise(ArgumentError, "#{split} summary does not match scored rows")
  end

  defp macro_f1(rows) do
    @routes
    |> Enum.map(fn route ->
      tp = Enum.count(rows, &(&1["expected"] == route and &1["parsed_route"] == route))
      fp = Enum.count(rows, &(&1["expected"] != route and &1["parsed_route"] == route))
      fn_ = Enum.count(rows, &(&1["expected"] == route and &1["parsed_route"] != route))
      if 2 * tp + fp + fn_ == 0, do: 0.0, else: 2 * tp / (2 * tp + fp + fn_)
    end)
    |> then(&(Enum.sum(&1) / length(@routes)))
  end

  defp paired_delta(by_seed, treatment, control) do
    paired_metric_delta(by_seed, fn arms, _seed -> {arms[treatment], arms[control]} end)
  end

  defp paired_runtime_delta(imp, upstream, arm) do
    unless Map.keys(imp) |> Enum.sort() == Map.keys(upstream) |> Enum.sort(),
      do: raise(ArgumentError, "runtime seed sets differ")

    paired_metric_delta(imp, fn _arms, seed -> {imp[seed][arm], upstream[seed][arm]} end)
  end

  defp paired_metric_delta(by_seed, pairer) do
    Map.new(~w(selection held_out), fn split ->
      {split,
       Map.new(~w(accuracy macro_f1), fn metric ->
         deltas =
           by_seed
           |> Enum.sort_by(&elem(&1, 0))
           |> Enum.map(fn {seed, arms} ->
             {left, right} = pairer.(arms, seed)
             left[split][metric] - right[split][metric]
           end)

         {metric,
          %{
            "paired_deltas" => deltas,
            "mean" => Enum.sum(deltas) / length(deltas),
            "exact_observed_range" => [Enum.min(deltas), Enum.max(deltas)]
          }}
       end)}
    end)
  end
end

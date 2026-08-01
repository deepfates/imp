defmodule MatchedInstructionOptimizersTREC.Aggregator do
  @moduledoc false
  @arms ~w(baseline gepa mipro_v2)
  @routes ~w(K11 K47)

  def aggregate!(manifest_path, imp_path, upstream_path) do
    manifest = MatchedInstructionOptimizersTREC.Contract.load!(manifest_path)
    gold_routes = gold_routes!(manifest)
    results = %{"imp" => load_result!(imp_path), "upstream" => load_result!(upstream_path)}
    validate_pair!(results, manifest)

    metrics =
      Map.new(results, fn {runtime, result} ->
        {runtime, recompute_runtime!(result, manifest, gold_routes)}
      end)

    %{
      "schema_version" => 3,
      "kind" => "matched_strong_instruction_optimizer_aggregate",
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
      "acceptance" => release_acceptance(results, manifest),
      "uncertainty" => %{
        "method" => "source_id_cluster_bootstrap_all_three_seeds",
        "resamples" => 10_000,
        "seed" => 2_026_072_605,
        "warning" => "Three optimizer seeds still provide limited model-sampling uncertainty."
      },
      "claim_boundary" =>
        "matched system outcome comparison; no general effectiveness or BEAM-superiority claim"
    }
  end

  defp load_result!(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp validate_pair!(results, manifest) do
    for {runtime, result} <- results do
      unless result["schema_version"] == 3 and result["runtime"] == runtime and
               result["status"] == "complete" and
               result["manifest_sha256"] == manifest["manifest_sha256"] do
        raise ArgumentError, "#{runtime} result is not a complete result for this manifest"
      end
    end

    unless results["imp"]["source_commits"] == results["upstream"]["source_commits"],
      do: raise(ArgumentError, "runtime source identities differ")
  end

  defp recompute_runtime!(result, manifest, gold_routes) do
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
               manifest["dataset"]["splits"]["selection_ids"],
               gold_routes
             ),
           "held_out" =>
             recompute_rows!(
               splits["held_out"],
               manifest["dataset"]["splits"]["held_out_ids"],
               gold_routes
             )
         }

         assert_summary!(
           arm["selection"],
           recomputed["selection"],
           "selection",
           splits["selection"]
         )

         assert_summary!(
           arm["held_out"],
           recomputed["held_out"],
           "held_out",
           splits["held_out"]
         )

         {arm["arm"], recomputed}
       end)}
    end)
  end

  defp recompute_rows!(rows, expected_ids, gold_routes) when is_list(rows) do
    unless Enum.map(rows, & &1["source_id"]) == expected_ids,
      do: raise(ArgumentError, "result row identity/order drift")

    unless Enum.all?(rows, fn row ->
             row["expected"] in @routes and
               row["expected"] == Map.fetch!(gold_routes, row["source_id"]) and
               (is_nil(row["parsed_route"]) or row["parsed_route"] in @routes) and
               row["correct"] == (row["expected"] == row["parsed_route"])
           end),
           do: raise(ArgumentError, "result row score fields are inconsistent")

    %{
      "accuracy" => Enum.count(rows, & &1["correct"]) / length(rows),
      "macro_f1" => macro_f1(rows),
      "parse_errors" => Enum.count(rows, &error_present?/1),
      "count" => length(rows)
    }
  end

  defp recompute_rows!(_, _, _), do: raise(ArgumentError, "result rows must be a list")

  defp gold_routes!(manifest) do
    ~w(selection held_out)
    |> Enum.flat_map(fn split ->
      manifest["dataset"]["#{split}_path"]
      |> File.stream!()
      |> Enum.map(fn line ->
        row = Jason.decode!(line)
        prefix = row["label"] |> String.split(":", parts: 2) |> hd()
        route = Map.fetch!(%{"DESC" => "K11", "ENTY" => "K47"}, prefix)
        {row["id"], route}
      end)
    end)
    |> Map.new()
  end

  defp assert_summary!(claimed, recomputed, split, rows) do
    claimed =
      if claimed["parse_errors"] ==
           recomputed["parse_errors"] + Enum.count(rows, &legacy_typed_nil_error?/1) do
        Map.put(claimed, "parse_errors", recomputed["parse_errors"])
      else
        claimed
      end

    unless claimed == recomputed,
      do: raise(ArgumentError, "#{split} summary does not match scored rows")
  end

  defp error_present?(%{"error" => error}), do: not is_nil(error) and not legacy_typed_nil?(error)

  defp legacy_typed_nil_error?(%{"error" => error}), do: legacy_typed_nil?(error)

  defp legacy_typed_nil?(%{"__imp_type__" => "atom", "value" => "nil"}), do: true
  defp legacy_typed_nil?(_), do: false

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

  defp release_acceptance(results, manifest) do
    improvements =
      Map.new(~w(gepa mipro_v2), fn arm ->
        deltas = clustered_deltas(results["imp"], arm, "baseline", nil)
        {arm, bootstrap_summary(deltas, arm)}
      end)

    adjusted = holm_adjust(Map.new(improvements, fn {arm, row} -> {arm, row["p_one_sided"]} end))

    improvements =
      Map.new(improvements, fn {arm, row} ->
        {arm, Map.put(row, "holm_adjusted_p", adjusted[arm])}
      end)

    winner =
      improvements
      |> Enum.filter(fn {_arm, row} -> row["mean"] > 0 and row["holm_adjusted_p"] < 0.05 end)
      |> Enum.max_by(fn {_arm, row} -> row["mean"] end, fn -> nil end)

    {winning_arm, noninferiority} =
      case winner do
        nil ->
          {nil, nil}

        {arm, _row} ->
          deltas = clustered_deltas(results["imp"], arm, nil, results["upstream"])
          {arm, bootstrap_summary(deltas, "#{arm}-imp-minus-upstream")}
      end

    margin = manifest["metrics"]["noninferiority_margin"]

    %{
      "improvements" => improvements,
      "winning_optimizer" => winning_arm,
      "noninferiority_margin" => margin,
      "winning_optimizer_imp_minus_upstream" => noninferiority,
      "headline_passed" =>
        not is_nil(winning_arm) and
          Enum.at(noninferiority["confidence_interval"], 0) > margin,
      "rule" =>
        "Holm-adjusted Imp improvement over baseline at alpha 0.05, then the same optimizer's Imp-minus-DSPy 95% lower bound must exceed -0.05"
    }
  end

  # Each source ID is one cluster containing the same row across all three optimizer seeds.
  defp clustered_deltas(left, arm, control, right) do
    left_by_seed = Map.new(left["seeds"], &{&1["seed"], &1})
    right_by_seed = right && Map.new(right["seeds"], &{&1["seed"], &1})

    left["seeds"]
    |> hd()
    |> then(&arm_rows(&1, arm))
    |> Enum.map(fn row ->
      id = row["source_id"]

      values =
        Enum.map(Map.keys(left_by_seed), fn seed ->
          left_value = row_correct(left_by_seed[seed], arm, id)

          right_value =
            if right_by_seed,
              do: row_correct(right_by_seed[seed], arm, id),
              else: row_correct(left_by_seed[seed], control, id)

          left_value - right_value
        end)

      {id, Enum.sum(values) / length(values)}
    end)
  end

  defp arm_rows(seed, arm) do
    seed["arms"] |> Enum.find(&(&1["arm"] == arm)) |> get_in(["rows", "held_out"])
  end

  defp row_correct(seed, arm, id) do
    seed
    |> arm_rows(arm)
    |> Enum.find(&(&1["source_id"] == id))
    |> Map.fetch!("correct")
    |> then(&if(&1, do: 1.0, else: 0.0))
  end

  defp bootstrap_summary(clusters, label) do
    values = Enum.map(clusters, &elem(&1, 1))
    mean = Enum.sum(values) / length(values)
    seed = :erlang.phash2({2_026_072_605, label}, 2_147_483_647)
    state = :rand.seed_s(:exsss, {seed + 1, seed + 2, seed + 3})

    {samples, _state} =
      Enum.map_reduce(1..10_000, state, fn _, state ->
        {picked, state} =
          Enum.map_reduce(values, state, fn _, state ->
            {index, state} = :rand.uniform_s(length(values), state)
            {Enum.at(values, index - 1), state}
          end)

        {Enum.sum(picked) / length(picked), state}
      end)

    sorted = Enum.sort(samples)

    %{
      "mean" => mean,
      "confidence_interval" => [Enum.at(sorted, 249), Enum.at(sorted, 9749)],
      "p_one_sided" => (Enum.count(samples, &(&1 <= 0)) + 1) / 10_001
    }
  end

  defp holm_adjust(values) do
    values
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.with_index()
    |> Enum.reduce({%{}, 0.0}, fn {{arm, p}, index}, {result, previous} ->
      adjusted = min(1.0, max(previous, p * (map_size(values) - index)))
      {Map.put(result, arm, adjusted), adjusted}
    end)
    |> elem(0)
  end
end

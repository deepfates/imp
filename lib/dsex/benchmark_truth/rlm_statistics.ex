defmodule DSEx.BenchmarkTruth.RLMStatistics do
  @moduledoc false

  def aggregate(rows, manifest) do
    approaches =
      rows
      |> Enum.group_by(&{&1["runtime"], &1["approach"]})
      |> Map.new(fn {key, values} -> {join(key), summarize(values)} end)

    comparisons = paired_comparisons(rows, manifest)

    %{
      "approaches" => approaches,
      "comparisons" => comparisons,
      "bootstrap" => %{
        "method" =>
          "family-scoped paired nonparametric bootstrap; OOLONG-Pairs clustered by logical query",
        "samples" => manifest["execution"]["bootstrap_samples"],
        "confidence" => manifest["execution"]["confidence"],
        "seed" => manifest["execution"]["seed"]
      }
    }
  end

  defp summarize(rows) do
    completed = Enum.filter(rows, &(&1["status"] == "ok"))

    %{
      "rows" => length(rows),
      "completed" => length(completed),
      "mean_score" => mean(Enum.map(completed, & &1["score"])),
      "mean_latency_ms" => mean(Enum.map(completed, & &1["latency_ms"])),
      "calls" => Enum.sum(Enum.map(completed, &get_in(&1, ["usage", "requests"]))),
      "input_tokens" => Enum.sum(Enum.map(completed, &get_in(&1, ["usage", "input_tokens"]))),
      "output_tokens" => Enum.sum(Enum.map(completed, &get_in(&1, ["usage", "output_tokens"]))),
      "usd" => Enum.sum(Enum.map(completed, &get_in(&1, ["usage", "usd"])))
    }
  end

  defp paired_comparisons(rows, manifest) do
    groups = Enum.group_by(rows, & &1["runtime"])

    Enum.flat_map(groups, fn {runtime, runtime_rows} ->
      by_approach = Enum.group_by(runtime_rows, & &1["approach"])

      for left <- Map.keys(by_approach),
          right <- Map.keys(by_approach),
          left < right,
          Map.has_key?(by_approach, left),
          Map.has_key?(by_approach, right) do
        paired_by_family(runtime, left, by_approach[left], right, by_approach[right], manifest)
      end
      |> List.flatten()
    end) ++ cross_runtime_rlm(groups, manifest)
  end

  defp cross_runtime_rlm(%{"dsex" => dsex, "dspy" => dspy}, manifest),
    do:
      paired_by_family(
        "dsex_vs_dspy",
        "dsex_rlm",
        Enum.filter(dsex, &(&1["approach"] == "rlm")),
        "dspy_rlm",
        Enum.filter(dspy, &(&1["approach"] == "rlm")),
        manifest
      )

  defp cross_runtime_rlm(_, _), do: []

  defp paired_by_family(runtime, left_name, left_rows, right_name, right_rows, manifest) do
    families =
      (Enum.map(left_rows, & &1["family"]) ++ Enum.map(right_rows, & &1["family"]))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(families, fn family ->
      paired(
        runtime,
        family,
        left_name,
        Enum.filter(left_rows, &(&1["family"] == family)),
        right_name,
        Enum.filter(right_rows, &(&1["family"] == family)),
        manifest
      )
    end)
  end

  defp paired(runtime, family, left_name, left_rows, right_name, right_rows, manifest) do
    left = Map.new(left_rows, &{pair_key(&1), &1})
    right = Map.new(right_rows, &{pair_key(&1), &1})
    keys = Map.keys(left) |> Enum.filter(&Map.has_key?(right, &1)) |> Enum.sort()

    row_diffs =
      Enum.map(keys, fn key ->
        {cluster_key(left[key]), left[key]["score"] - right[key]["score"]}
      end)

    diffs =
      row_diffs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort()
      |> Enum.map(fn {_cluster, values} -> mean(values) end)

    {low, high} = bootstrap_ci(diffs, manifest["execution"])

    %{
      "runtime" => runtime,
      "family" => family,
      "metric" => left_rows |> List.first(%{}) |> Map.get("metric"),
      "left" => left_name,
      "right" => right_name,
      "paired_rows" => length(row_diffs),
      "bootstrap_clusters" => length(diffs),
      "mean_score_difference" => mean(diffs),
      "confidence_interval" => %{"low" => low, "high" => high}
    }
  end

  defp bootstrap_ci([], _execution), do: {nil, nil}

  defp bootstrap_ci(values, execution) do
    samples = execution["bootstrap_samples"]
    confidence = execution["confidence"]

    state =
      :rand.seed_s(
        :exsss,
        {execution["seed"], 2 * execution["seed"] + 1, 3 * execution["seed"] + 7}
      )

    {means, _state} =
      Enum.map_reduce(1..samples, state, fn _, rng ->
        {draw, rng} =
          Enum.map_reduce(values, rng, fn _, acc ->
            {index, acc} = :rand.uniform_s(length(values), acc)
            {Enum.at(values, index - 1), acc}
          end)

        {mean(draw), rng}
      end)

    sorted = Enum.sort(means)
    alpha = (1.0 - confidence) / 2.0
    {percentile(sorted, alpha), percentile(sorted, 1.0 - alpha)}
  end

  defp percentile(values, p),
    do: Enum.at(values, min(length(values) - 1, max(0, floor(p * (length(values) - 1)))))

  defp pair_key(row), do: {row["family"], row["example_id"], row["context_size"]}
  defp cluster_key(%{"family" => "oolong_pairs"} = row), do: row["query_id"]
  defp cluster_key(row), do: row["example_id"]
  defp join({runtime, approach}), do: "#{runtime}:#{approach}"
  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end

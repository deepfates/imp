defmodule DSEx.IdentityReliability do
  @moduledoc """
  Computes descriptive inter-rater reliability for identity assessments.

  The report separates rank agreement, absolute score agreement, and
  consistency. It does not turn any statistic into an automatic acceptance
  threshold.
  """

  @epsilon 1.0e-12

  @spec compile!([map()], map()) :: map()
  def compile!(assessments, scenario_config)
      when is_list(assessments) and is_map(scenario_config) do
    corpus = corpus!(assessments)

    axes =
      Enum.map(corpus.axis_ids, fn axis_id ->
        matrix_report(
          axis_id,
          axis_id,
          matrix(corpus, &get_in(&1, ["scores", axis_id])),
          corpus.profile_ids
        )
      end)

    scenarios =
      scenario_config
      |> Map.get("scenarios", [])
      |> Enum.map(&scenario_report!(&1, corpus))

    %{
      "schema_version" => 1,
      "kind" => "identity_inter_rater_reliability",
      "interpretation" => "descriptive_not_acceptance_threshold",
      "candidate_count" => length(corpus.candidate_ids),
      "profile_count" => length(corpus.profile_ids),
      "profile_ids" => corpus.profile_ids,
      "assessment_count" => length(assessments),
      "axis_count" => length(corpus.axis_ids),
      "scenario_count" => length(scenarios),
      "definitions" => definitions(),
      "summary" => summary(axes, scenarios),
      "axes" => axes,
      "scenarios" => scenarios
    }
  end

  def compile!(assessments, scenario_config) do
    raise ArgumentError,
          "reliability inputs must be an assessment list and scenario map, got: " <>
            inspect({assessments, scenario_config})
  end

  defp corpus!([]), do: raise(ArgumentError, "reliability requires assessments")

  defp corpus!(assessments) do
    identities = Enum.map(assessments, &identity!/1)
    reject_duplicate_pairs!(identities)

    profile_ids = identities |> Enum.map(& &1.profile_id) |> Enum.uniq() |> Enum.sort()
    candidate_ids = identities |> Enum.map(& &1.candidate_id) |> Enum.uniq() |> Enum.sort()
    axis_sets = identities |> Enum.map(&MapSet.new(Map.keys(&1.record["scores"]))) |> Enum.uniq()

    if length(profile_ids) < 2 do
      raise ArgumentError, "reliability requires at least two assessor profiles"
    end

    if length(candidate_ids) < 2 do
      raise ArgumentError, "reliability requires at least two candidates"
    end

    if length(axis_sets) != 1 do
      raise ArgumentError, "assessment score axis sets are inconsistent"
    end

    [axis_set] = axis_sets
    axis_ids = axis_set |> MapSet.to_list() |> Enum.sort()

    if axis_ids == [] do
      raise ArgumentError, "assessments must contain at least one score axis"
    end

    by_pair = Map.new(identities, &{{&1.candidate_id, &1.profile_id}, &1.record})

    missing =
      for candidate_id <- candidate_ids,
          profile_id <- profile_ids,
          not Map.has_key?(by_pair, {candidate_id, profile_id}),
          do: "#{candidate_id}/#{profile_id}"

    if missing != [] do
      raise ArgumentError,
            "incomplete candidate/profile assessment matrix: #{summarize(missing)}"
    end

    %{
      profile_ids: profile_ids,
      candidate_ids: candidate_ids,
      axis_ids: axis_ids,
      by_pair: by_pair
    }
  end

  defp identity!(record) when is_map(record) do
    candidate_id = record["candidate_id"]
    profile_id = get_in(record, ["assessor", "profile_id"])
    scores = record["scores"]

    unless is_binary(candidate_id) and candidate_id != "" do
      raise ArgumentError, "assessment has invalid candidate_id"
    end

    unless is_binary(profile_id) and profile_id != "" do
      raise ArgumentError, "assessment #{record["id"] || "<missing>"} has invalid profile_id"
    end

    unless is_map(scores) and scores != %{} and
             Enum.all?(scores, fn {_axis, value} -> is_number(value) end) do
      raise ArgumentError, "assessment #{record["id"] || "<missing>"} has invalid scores"
    end

    %{candidate_id: candidate_id, profile_id: profile_id, record: record}
  end

  defp identity!(_record), do: raise(ArgumentError, "assessment records must be objects")

  defp reject_duplicate_pairs!(identities) do
    duplicate =
      identities
      |> Enum.frequencies_by(&{&1.candidate_id, &1.profile_id})
      |> Enum.find(fn {_pair, count} -> count > 1 end)

    case duplicate do
      nil ->
        :ok

      {{candidate_id, profile_id}, _} ->
        raise ArgumentError,
              "duplicate candidate/profile assessment: #{candidate_id}/#{profile_id}"
    end
  end

  defp scenario_report!(scenario, corpus) when is_map(scenario) do
    id = scenario["id"]
    label = scenario["label"]
    weights = scenario["weights"]

    unless is_binary(id) and id != "" and is_map(weights) and weights != %{} do
      raise ArgumentError, "invalid reliability scenario #{inspect(id)}"
    end

    unknown = Map.keys(weights) -- corpus.axis_ids
    invalid = Enum.reject(weights, fn {_axis, weight} -> is_number(weight) end)

    if unknown != [] or invalid != [] do
      raise ArgumentError,
            "scenario #{id} has invalid weights; unknown=#{summarize(unknown)}, " <>
              "non_numeric=#{summarize(Enum.map(invalid, &elem(&1, 0)))}"
    end

    rows =
      matrix(corpus, fn record ->
        Enum.reduce(weights, 0.0, fn {axis, weight}, total ->
          total + record["scores"][axis] * weight
        end)
      end)

    matrix_report(id, label || id, rows, corpus.profile_ids)
  end

  defp scenario_report!(scenario, _corpus) do
    raise ArgumentError, "scenario records must be objects, got: #{inspect(scenario)}"
  end

  defp matrix(corpus, value_fun) do
    Enum.map(corpus.candidate_ids, fn candidate_id ->
      Enum.map(corpus.profile_ids, fn profile_id ->
        corpus.by_pair |> Map.fetch!({candidate_id, profile_id}) |> value_fun.() |> Kernel./(1)
      end)
    end)
  end

  defp matrix_report(id, label, rows, profile_ids) do
    %{
      "id" => id,
      "label" => label,
      "candidate_count" => length(rows),
      "icc" => icc(rows),
      "pairwise" => pairwise(rows, profile_ids)
    }
  end

  defp pairwise(rows, profile_ids) do
    columns = columns(rows)

    for {left_profile, left_index} <- Enum.with_index(profile_ids),
        {right_profile, right_index} <- Enum.with_index(profile_ids),
        left_index < right_index do
      left = Enum.at(columns, left_index)
      right = Enum.at(columns, right_index)
      differences = Enum.zip_with(left, right, &(&1 - &2))

      %{
        "left_profile_id" => left_profile,
        "right_profile_id" => right_profile,
        "spearman_rank_correlation" => spearman(left, right),
        "mean_signed_difference" => differences |> mean() |> clean(),
        "mean_absolute_error" => differences |> Enum.map(&abs/1) |> mean() |> clean(),
        "root_mean_square_error" =>
          differences |> Enum.map(&(&1 * &1)) |> mean() |> :math.sqrt() |> clean(),
        "exact_agreement_rate" => agreement_rate(differences, 0.0),
        "within_half_point_rate" => agreement_rate(differences, 0.5)
      }
    end
  end

  defp icc(rows) do
    n = length(rows)
    k = rows |> hd() |> length()
    row_means = Enum.map(rows, &mean/1)
    column_means = rows |> columns() |> Enum.map(&mean/1)
    grand_mean = rows |> List.flatten() |> mean()

    ms_targets =
      k * Enum.sum(Enum.map(row_means, &square(&1 - grand_mean))) / (n - 1)

    ms_raters =
      n * Enum.sum(Enum.map(column_means, &square(&1 - grand_mean))) / (k - 1)

    residual_sum =
      rows
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {row, row_index}, total ->
        row
        |> Enum.with_index()
        |> Enum.reduce(total, fn {value, column_index}, inner ->
          residual =
            value - Enum.at(row_means, row_index) - Enum.at(column_means, column_index) +
              grand_mean

          inner + square(residual)
        end)
      end)

    ms_error = residual_sum / ((n - 1) * (k - 1))

    %{
      "absolute_agreement_single" =>
        ratio(
          ms_targets - ms_error,
          ms_targets + (k - 1) * ms_error + k * (ms_raters - ms_error) / n
        ),
      "absolute_agreement_mean" =>
        ratio(ms_targets - ms_error, ms_targets + (ms_raters - ms_error) / n),
      "consistency_single" => ratio(ms_targets - ms_error, ms_targets + (k - 1) * ms_error),
      "consistency_mean" => ratio(ms_targets - ms_error, ms_targets)
    }
  end

  defp spearman(left, right), do: pearson(midranks(left), midranks(right))

  defp midranks(values) do
    {ranks, _next_rank} =
      values
      |> Enum.with_index()
      |> Enum.sort_by(fn {value, index} -> {value, index} end)
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.reduce({%{}, 1}, fn tied, {acc, next_rank} ->
        last_rank = next_rank + length(tied) - 1
        rank = (next_rank + last_rank) / 2
        ranked = Enum.reduce(tied, acc, fn {_value, index}, map -> Map.put(map, index, rank) end)
        {ranked, last_rank + 1}
      end)

    Enum.map(0..(length(values) - 1), &Map.fetch!(ranks, &1))
  end

  defp pearson(left, right) do
    left_mean = mean(left)
    right_mean = mean(right)

    {numerator, left_sum, right_sum} =
      Enum.zip(left, right)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {left_value, right_value}, {cross, left_sq, right_sq} ->
        left_delta = left_value - left_mean
        right_delta = right_value - right_mean

        {
          cross + left_delta * right_delta,
          left_sq + square(left_delta),
          right_sq + square(right_delta)
        }
      end)

    ratio(numerator, :math.sqrt(left_sum * right_sum))
  end

  defp agreement_rate(differences, tolerance) do
    differences
    |> Enum.count(&(abs(&1) <= tolerance + @epsilon))
    |> Kernel./(length(differences))
  end

  defp summary(axes, scenarios) do
    %{
      "axes" => reliability_summary(axes),
      "scenarios" => reliability_summary(scenarios)
    }
  end

  defp reliability_summary(reports) do
    %{
      "absolute_agreement_single" => describe(reports, ["icc", "absolute_agreement_single"]),
      "absolute_agreement_mean" => describe(reports, ["icc", "absolute_agreement_mean"]),
      "consistency_single" => describe(reports, ["icc", "consistency_single"]),
      "consistency_mean" => describe(reports, ["icc", "consistency_mean"]),
      "pairwise_spearman" =>
        reports
        |> Enum.flat_map(& &1["pairwise"])
        |> describe_values(& &1["spearman_rank_correlation"])
    }
  end

  defp describe(reports, path) do
    describe_values(reports, &get_in(&1, path))
  end

  defp describe_values(values, mapper) do
    values = values |> Enum.map(mapper) |> Enum.filter(&is_number/1) |> Enum.sort()

    if values == [] do
      %{"count" => 0, "minimum" => nil, "median" => nil, "mean" => nil, "maximum" => nil}
    else
      %{
        "count" => length(values),
        "minimum" => hd(values),
        "median" => median(values),
        "mean" => mean(values),
        "maximum" => List.last(values)
      }
    end
  end

  defp definitions do
    %{
      "spearman_rank_correlation" =>
        "Pearson correlation of average tie ranks; measures ordering consistency.",
      "mean_signed_difference" =>
        "Left profile score minus right profile score; exposes systematic scale bias.",
      "icc_absolute_agreement" =>
        "Two-way ICC(A,1)/ICC(A,k); penalizes both ordering error and profile scale shifts.",
      "icc_consistency" =>
        "Two-way ICC(C,1)/ICC(C,k); ignores stable additive profile scale shifts.",
      "single" => "Reliability of one assessment profile.",
      "mean" => "Reliability of the equal-profile mean used by decision views."
    }
  end

  defp columns(rows) do
    for index <- 0..(length(hd(rows)) - 1), do: Enum.map(rows, &Enum.at(&1, index))
  end

  defp mean(values), do: Enum.sum(values) / length(values)
  defp square(value), do: value * value

  defp ratio(_numerator, denominator) when abs(denominator) < @epsilon, do: nil
  defp ratio(numerator, denominator), do: (numerator / denominator) |> clean()

  defp clean(value) when abs(value) < @epsilon, do: 0.0
  defp clean(value), do: value

  defp median(values) do
    middle = div(length(values), 2)

    if rem(length(values), 2) == 1 do
      Enum.at(values, middle)
    else
      (Enum.at(values, middle - 1) + Enum.at(values, middle)) / 2
    end
  end

  defp summarize(values, limit \\ 8)
  defp summarize([], _limit), do: "none"

  defp summarize(values, limit) do
    suffix = if length(values) > limit, do: " (+#{length(values) - limit} more)", else: ""
    Enum.join(Enum.take(values, limit), ", ") <> suffix
  end
end

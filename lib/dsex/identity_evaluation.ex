defmodule DSEx.IdentityEvaluation do
  @moduledoc false

  @spec load_jsonl!(Path.t(), keyword()) :: [map()]
  def load_jsonl!(path, opts \\ []) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.with_index(1)
      |> Enum.map(fn {line, line_number} ->
        case Jason.decode(line) do
          {:ok, value} when is_map(value) -> value
          {:ok, _value} -> raise "#{path}:#{line_number} must contain a JSON object"
          {:error, error} -> raise "#{path}:#{line_number}: #{Exception.message(error)}"
        end
      end)
    else
      if Keyword.get(opts, :optional, false), do: [], else: File.read!(path)
    end
  end

  @spec compile([map()], [map()], [map()], [map()], map(), map()) ::
          {:ok, map()} | {:error, [String.t()]}
  def compile(registry, assessments, flags, dissent, atlas, scenario_config) do
    entities = candidate_entities(registry)
    candidate_ids = entities |> Map.keys() |> MapSet.new()
    context = evaluation_context(atlas, scenario_config)

    active_assessments = active_records(assessments)
    active_flags = active_records(flags)
    active_dissent = active_records(dissent)

    errors =
      context.errors ++
        duplicate_id_errors(assessments, "assessment") ++
        duplicate_id_errors(flags, "flag") ++
        duplicate_id_errors(dissent, "dissent") ++
        validate_assessments(active_assessments, candidate_ids, context) ++
        validate_candidate_references(active_flags, candidate_ids, "flag") ++
        validate_candidate_references(active_dissent, candidate_ids, "dissent")

    if errors == [] do
      score_vectors = aggregate_scores(active_assessments)

      required_replicates =
        get_in(atlas, ["coverage_requirements", "required_assessment_replicates_for_ranked_views"]) ||
          1

      views =
        Enum.map(scenario_config["scenarios"], fn scenario ->
          scenario_view(
            scenario,
            scenario_config["tier_thresholds"],
            entities,
            score_vectors,
            active_flags,
            active_dissent,
            required_replicates
          )
        end)

      {:ok,
       %{
         "generated_at" =>
           DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
         "atlas_version" => atlas["atlas_version"],
         "scenario_schema_version" => scenario_config["schema_version"],
         "selection_made" => false,
         "summary" => %{
           "candidate_entities" => map_size(entities),
           "candidate_occurrences" => candidate_occurrence_count(registry),
           "assessment_events" => length(assessments),
           "active_assessments" => length(active_assessments),
           "flag_events" => length(flags),
           "active_flags" => length(active_flags),
           "dissent_events" => length(dissent),
           "active_dissent" => length(active_dissent),
           "required_assessment_replicates" => required_replicates
         },
         "scenarios" => views
       }}
    else
      {:error, Enum.sort(errors)}
    end
  end

  @spec candidate_entities([map()]) :: %{String.t() => map()}
  def candidate_entities(registry) do
    registry
    |> Enum.filter(&(&1["event_type"] == "candidate_observed"))
    |> Enum.reduce(%{}, fn event, acc ->
      candidate_id = event["candidate_id"]
      candidate = event["candidate"] || %{}

      Map.update(
        acc,
        candidate_id,
        %{
          "candidate_id" => candidate_id,
          "normalized" => event["normalized"],
          "display" => event["surface"],
          "surfaces" => [event["surface"]],
          "occurrence_ids" => [event["occurrence_id"]],
          "run_ids" => [event["run_id"]],
          "territories" => candidate["territories"] || [],
          "strategies" => candidate["strategies"] || [],
          "wildcard" => candidate["wildcard"] == true
        },
        fn entity ->
          entity
          |> Map.update!("surfaces", &append_unique(&1, event["surface"]))
          |> Map.update!("occurrence_ids", &(&1 ++ [event["occurrence_id"]]))
          |> Map.update!("run_ids", &append_unique(&1, event["run_id"]))
          |> Map.update!("territories", &union_ordered(&1, candidate["territories"] || []))
          |> Map.update!("strategies", &union_ordered(&1, candidate["strategies"] || []))
          |> Map.update!("wildcard", &(&1 or candidate["wildcard"] == true))
        end
      )
    end)
  end

  defp evaluation_context(atlas, scenario_config) do
    axis_ids = atlas |> Map.get("assessment_axes", []) |> ids()
    audience_ids = atlas |> Map.get("audiences", []) |> ids()
    architecture_ids = atlas |> Map.get("brand_architectures", []) |> ids()
    scenario_ids = scenario_config |> Map.get("scenarios", []) |> ids()

    scenario_errors =
      Enum.flat_map(scenario_config["scenarios"] || [], fn scenario ->
        weights = scenario["weights"]
        unknown = MapSet.difference(MapSet.new(Map.keys(weights || %{})), axis_ids)
        total = if is_map(weights), do: weights |> Map.values() |> Enum.sum(), else: 0

        []
        |> maybe_error(
          not is_map(weights) or weights == %{},
          "scenario #{scenario["id"]} has no weights"
        )
        |> maybe_error(
          MapSet.size(unknown) > 0,
          "scenario #{scenario["id"]} has unknown axes: #{unknown |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}"
        )
        |> maybe_error(
          abs(total - 1.0) > 1.0e-9,
          "scenario #{scenario["id"]} weights sum to #{total}, expected 1.0"
        )
      end)

    threshold_errors =
      case scenario_config["tier_thresholds"] do
        thresholds when is_list(thresholds) and thresholds != [] -> []
        _ -> ["tier_thresholds must be a non-empty array"]
      end

    %{
      axis_ids: axis_ids,
      audience_ids: audience_ids,
      architecture_ids: architecture_ids,
      scenario_ids: scenario_ids,
      errors: scenario_errors ++ threshold_errors
    }
  end

  defp ids(items), do: items |> Enum.map(& &1["id"]) |> MapSet.new()

  defp active_records(records) do
    superseded =
      records
      |> Enum.map(& &1["supersedes"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(records, &MapSet.member?(superseded, &1["id"]))
  end

  defp duplicate_id_errors(records, label) do
    records
    |> Enum.group_by(& &1["id"])
    |> Enum.flat_map(fn
      {nil, _} -> ["#{label} record is missing id"]
      {_id, [_record]} -> []
      {id, duplicates} -> ["duplicate #{label} id #{id}: #{length(duplicates)} records"]
    end)
  end

  defp validate_assessments(records, candidate_ids, context) do
    Enum.flat_map(records, fn record ->
      id = record["id"] || "<missing>"
      scores = record["scores"]
      score_ids = if is_map(scores), do: MapSet.new(Map.keys(scores)), else: MapSet.new()
      unknown_axes = MapSet.difference(score_ids, context.axis_ids)

      invalid_values =
        if is_map(scores) do
          Enum.filter(scores, fn {_axis, value} ->
            not is_number(value) or value < 0 or value > 5
          end)
        else
          []
        end

      context_record = record["context"] || %{}

      []
      |> maybe_error(
        not MapSet.member?(candidate_ids, record["candidate_id"]),
        "assessment #{id} references unknown candidate #{inspect(record["candidate_id"])}"
      )
      |> maybe_error(not is_map(scores) or scores == %{}, "assessment #{id} has no scores")
      |> maybe_error(
        MapSet.size(unknown_axes) > 0,
        "assessment #{id} has unknown axes: #{unknown_axes |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}"
      )
      |> maybe_error(invalid_values != [], "assessment #{id} has scores outside 0..5")
      |> maybe_error(
        not valid_confidence?(record["confidence"]),
        "assessment #{id} confidence must be in 0..1"
      )
      |> validate_optional_context_id(context_record, "audience_id", context.audience_ids, id)
      |> validate_optional_context_id(
        context_record,
        "architecture_id",
        context.architecture_ids,
        id
      )
      |> validate_optional_context_id(context_record, "scenario_id", context.scenario_ids, id)
    end)
  end

  defp validate_optional_context_id(errors, context, key, allowed, assessment_id) do
    case context[key] do
      nil ->
        errors

      value ->
        maybe_error(
          errors,
          not MapSet.member?(allowed, value),
          "assessment #{assessment_id} has unknown #{key} #{value}"
        )
    end
  end

  defp validate_candidate_references(records, candidate_ids, label) do
    Enum.flat_map(records, fn record ->
      if MapSet.member?(candidate_ids, record["candidate_id"]),
        do: [],
        else: [
          "#{label} #{record["id"] || "<missing>"} references unknown candidate #{inspect(record["candidate_id"])}"
        ]
    end)
  end

  defp valid_confidence?(value), do: is_number(value) and value >= 0 and value <= 1

  defp aggregate_scores(assessments) do
    assessments
    |> Enum.reduce(%{}, fn assessment, acc ->
      candidate_id = assessment["candidate_id"]
      confidence = assessment["confidence"]

      Enum.reduce(assessment["scores"], acc, fn {axis, score}, inner ->
        update_in(
          inner,
          [
            Access.key(candidate_id, %{}),
            Access.key(axis, %{weighted_sum: 0.0, confidence_sum: 0.0, raw_sum: 0.0, count: 0})
          ],
          fn aggregate ->
            %{
              weighted_sum: aggregate.weighted_sum + score * confidence,
              confidence_sum: aggregate.confidence_sum + confidence,
              raw_sum: aggregate.raw_sum + score,
              count: aggregate.count + 1
            }
          end
        )
      end)
    end)
    |> Map.new(fn {candidate_id, axes} ->
      values =
        Map.new(axes, fn {axis, aggregate} ->
          mean =
            if aggregate.confidence_sum > 0,
              do: aggregate.weighted_sum / aggregate.confidence_sum,
              else: aggregate.raw_sum / aggregate.count

          {axis, %{"mean" => mean, "replicates" => aggregate.count}}
        end)

      {candidate_id, values}
    end)
  end

  defp scenario_view(
         scenario,
         thresholds,
         entities,
         score_vectors,
         flags,
         dissent,
         required_replicates
       ) do
    active_axes =
      scenario["weights"]
      |> Enum.filter(fn {_axis, weight} -> weight > 0 end)
      |> Enum.map(&elem(&1, 0))

    {eligible, unranked} =
      Enum.reduce(entities, {[], []}, fn {candidate_id, entity}, {ranked, missing} ->
        axis_scores = Map.get(score_vectors, candidate_id, %{})

        missing_axes =
          Enum.filter(active_axes, fn axis ->
            (get_in(axis_scores, [axis, "replicates"]) || 0) < required_replicates
          end)

        if missing_axes == [] do
          score =
            Enum.reduce(scenario["weights"], 0.0, fn {axis, weight}, total ->
              total + get_in(axis_scores, [axis, "mean"]) * weight
            end)

          row =
            entity
            |> Map.put("axis_scores", axis_scores)
            |> Map.put("scenario_score", score)
            |> Map.put("tier", tier(score, thresholds))
            |> Map.put("flags", candidate_records(flags, candidate_id))
            |> Map.put("dissent", candidate_records(dissent, candidate_id))

          {[row | ranked], missing}
        else
          reason = %{
            "candidate_id" => candidate_id,
            "display" => entity["display"],
            "missing_or_under_replicated_axes" => Enum.sort(missing_axes)
          }

          {ranked, [reason | missing]}
        end
      end)

    frontier_ids = pareto_frontier_ids(eligible, active_axes)

    ranked =
      eligible
      |> Enum.map(&Map.put(&1, "pareto", MapSet.member?(frontier_ids, &1["candidate_id"])))
      |> Enum.sort_by(fn row -> {-row["scenario_score"], String.downcase(row["display"])} end)

    %{
      "id" => scenario["id"],
      "label" => scenario["label"],
      "weights" => scenario["weights"],
      "ranked_candidate_count" => length(ranked),
      "unranked_candidate_count" => length(unranked),
      "pareto_candidate_count" => MapSet.size(frontier_ids),
      "ranked" => ranked,
      "unranked" => Enum.sort_by(unranked, &String.downcase(&1["display"]))
    }
  end

  defp pareto_frontier_ids(rows, axes) do
    Enum.reduce(rows, MapSet.new(), fn row, frontier ->
      dominated =
        Enum.any?(rows, fn other ->
          other["candidate_id"] != row["candidate_id"] and dominates?(other, row, axes)
        end)

      if dominated, do: frontier, else: MapSet.put(frontier, row["candidate_id"])
    end)
  end

  defp dominates?(left, right, axes) do
    comparisons =
      Enum.map(axes, fn axis ->
        {get_in(left, ["axis_scores", axis, "mean"]),
         get_in(right, ["axis_scores", axis, "mean"])}
      end)

    Enum.all?(comparisons, fn {left_score, right_score} -> left_score >= right_score end) and
      Enum.any?(comparisons, fn {left_score, right_score} -> left_score > right_score end)
  end

  defp tier(score, thresholds) do
    thresholds
    |> Enum.sort_by(&(-&1["minimum"]))
    |> Enum.find(fn threshold -> score >= threshold["minimum"] end)
    |> Map.fetch!("tier")
  end

  defp candidate_records(records, candidate_id) do
    records
    |> Enum.filter(&(&1["candidate_id"] == candidate_id))
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp candidate_occurrence_count(registry),
    do: Enum.count(registry, &(&1["event_type"] == "candidate_observed"))

  defp append_unique(items, item), do: if(item in items, do: items, else: items ++ [item])
  defp union_ordered(left, right), do: Enum.reduce(right, left, &append_unique(&2, &1))

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors
end

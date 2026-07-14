defmodule Imp.IdentityReviewPools do
  @moduledoc false

  alias Imp.{IdentityCheckpoint, IdentityEvaluation}

  @default_limits [
    scenario_limit: 25,
    disagreement_limit: 100,
    flagged_rank_threshold: 100,
    resurrection_top_k: 25
  ]
  @wildcard_floor_ratio 0.20
  @limit_keys Keyword.keys(@default_limits)
  @file_defaults @default_limits ++
                   [
                     decision_views: "identity/reports/decision-views.json",
                     assessments: "identity/assessments.jsonl",
                     out: "identity/reports/review-pools.json"
                   ]

  @spec default_limits() :: keyword(pos_integer())
  def default_limits, do: @default_limits

  @spec compile(map(), [map()], keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def compile(decision_views, assessments, opts \\ [])

  def compile(decision_views, assessments, opts)
      when is_map(decision_views) and is_list(assessments) do
    limits = opts |> Keyword.validate!(@default_limits) |> validate_limits!()
    candidates = list(decision_views["candidates"])
    candidate_ids = candidates |> valid_ids() |> MapSet.new()

    errors =
      validate_decision_views(decision_views, candidate_ids) ++
        validate_assessments(assessments, candidate_ids) ++
        validate_wildcard_inventory(candidates, limits[:scenario_limit])

    if errors == [] do
      {:ok, project(decision_views, assessments, limits)}
    else
      {:error, errors |> Enum.uniq() |> Enum.sort()}
    end
  end

  def compile(_decision_views, _assessments, _opts),
    do: {:error, ["decision views must be a JSON object and assessments must be a list"]}

  @spec compile!(map(), [map()], keyword()) :: map()
  def compile!(decision_views, assessments, opts \\ []) do
    case compile(decision_views, assessments, opts) do
      {:ok, report} -> report
      {:error, errors} -> raise ArgumentError, Enum.join(errors, "\n")
    end
  end

  @spec run_files!(keyword()) :: map()
  def run_files!(opts \\ []) do
    config = opts |> Keyword.validate!(@file_defaults) |> validate_limits!()

    decision_views =
      config[:decision_views]
      |> File.read!()
      |> Jason.decode!()

    assessments = IdentityEvaluation.load_jsonl!(config[:assessments])
    report = compile!(decision_views, assessments, Keyword.take(config, @limit_keys))

    IdentityCheckpoint.write_atomic!(config[:out], Jason.encode!(report, pretty: true) <> "\n")
    report
  end

  defp validate_limits!(opts) do
    Enum.each(@limit_keys, fn key ->
      value = Keyword.fetch!(opts, key)

      unless is_integer(value) and value > 0 do
        raise ArgumentError, "#{key} must be a positive integer"
      end
    end)

    opts
  end

  defp validate_decision_views(decision_views, candidate_ids) do
    candidates = list(decision_views["candidates"])
    scenarios = list(decision_views["scenarios"])

    []
    |> maybe_error(
      decision_views["schema_version"] != 2,
      "decision views schema_version must be 2"
    )
    |> maybe_error(
      not is_list(decision_views["candidates"]),
      "decision views candidates must be a list"
    )
    |> maybe_error(candidates == [], "decision views candidates must not be empty")
    |> maybe_error(
      not is_list(decision_views["scenarios"]),
      "decision views scenarios must be a list"
    )
    |> maybe_error(scenarios == [], "decision views scenarios must not be empty")
    |> Kernel.++(duplicate_errors(valid_ids(candidates), "candidate"))
    |> Kernel.++(Enum.flat_map(candidates, &validate_candidate/1))
    |> Kernel.++(duplicate_errors(valid_ids(scenarios), "scenario"))
    |> Kernel.++(Enum.flat_map(scenarios, &validate_scenario(&1, candidate_ids)))
    |> Kernel.++(validate_summary_count(decision_views, MapSet.size(candidate_ids)))
  end

  defp validate_candidate(candidate) when is_map(candidate) do
    id = candidate["candidate_id"]
    axis_scores = candidate["axis_scores"]

    []
    |> maybe_error(not nonempty_string?(id), "candidate is missing candidate_id")
    |> maybe_error(
      not nonempty_string?(candidate["display"]),
      "candidate #{inspect(id)} is missing display"
    )
    |> maybe_error(
      not valid_axis_scores?(axis_scores),
      "candidate #{inspect(id)} has invalid axis_scores"
    )
    |> maybe_error(
      not string_list?(candidate["flags"]),
      "candidate #{inspect(id)} flags must be a list of IDs"
    )
    |> maybe_error(
      not string_list?(candidate["dissent"]),
      "candidate #{inspect(id)} dissent must be a list of IDs"
    )
    |> maybe_error(
      candidate["wildcard"] not in [true, false],
      "candidate #{inspect(id)} wildcard must be boolean"
    )
  end

  defp validate_candidate(_candidate), do: ["decision views candidate must be an object"]

  defp validate_scenario(scenario, candidate_ids) when is_map(scenario) do
    id = scenario["id"]
    ranked = list(scenario["ranked"])
    unranked = list(scenario["unranked"])
    ranked_ids = valid_ids(ranked)
    unranked_ids = valid_ids(unranked)
    referenced = MapSet.new(ranked_ids ++ unranked_ids)
    unknown = MapSet.difference(referenced, candidate_ids)
    missing = MapSet.difference(candidate_ids, referenced)
    overlap = MapSet.intersection(MapSet.new(ranked_ids), MapSet.new(unranked_ids))

    []
    |> maybe_error(not nonempty_string?(id), "scenario is missing id")
    |> maybe_error(
      not is_list(scenario["ranked"]),
      "scenario #{inspect(id)} ranked must be a list"
    )
    |> maybe_error(
      not is_nil(scenario["unranked"]) and not is_list(scenario["unranked"]),
      "scenario #{inspect(id)} unranked must be a list"
    )
    |> Kernel.++(duplicate_errors(ranked_ids, "scenario #{inspect(id)} ranked candidate"))
    |> Kernel.++(duplicate_errors(unranked_ids, "scenario #{inspect(id)} unranked candidate"))
    |> Kernel.++(Enum.flat_map(ranked, &validate_ranked_row(&1, id)))
    |> Kernel.++(Enum.flat_map(unranked, &validate_unranked_row(&1, id)))
    |> maybe_error(
      MapSet.size(unknown) > 0,
      "scenario #{inspect(id)} references unknown candidates: #{summarize_ids(unknown)}"
    )
    |> maybe_error(
      MapSet.size(overlap) > 0,
      "scenario #{inspect(id)} ranks and unranks the same candidates: #{summarize_ids(overlap)}"
    )
    |> maybe_error(
      MapSet.size(missing) > 0,
      "scenario #{inspect(id)} does not cover candidates: #{summarize_ids(missing)}"
    )
  end

  defp validate_scenario(_scenario, _candidate_ids),
    do: ["decision views scenario must be an object"]

  defp validate_ranked_row(row, scenario_id) when is_map(row) do
    id = row["candidate_id"]

    []
    |> maybe_error(
      not nonempty_string?(id),
      "scenario #{inspect(scenario_id)} ranked row is missing candidate_id"
    )
    |> maybe_error(
      not is_number(row["scenario_score"]),
      "scenario #{inspect(scenario_id)} candidate #{inspect(id)} has invalid scenario_score"
    )
    |> maybe_error(
      row["pareto"] not in [true, false],
      "scenario #{inspect(scenario_id)} candidate #{inspect(id)} has invalid pareto marker"
    )
  end

  defp validate_ranked_row(_row, scenario_id),
    do: ["scenario #{inspect(scenario_id)} ranked row must be an object"]

  defp validate_unranked_row(row, scenario_id) when is_map(row) do
    if nonempty_string?(row["candidate_id"]),
      do: [],
      else: ["scenario #{inspect(scenario_id)} unranked row is missing candidate_id"]
  end

  defp validate_unranked_row(_row, scenario_id),
    do: ["scenario #{inspect(scenario_id)} unranked row must be an object"]

  defp validate_summary_count(decision_views, candidate_count) do
    case get_in(decision_views, ["summary", "candidate_entities"]) do
      nil ->
        []

      ^candidate_count ->
        []

      count ->
        [
          "decision views summary candidate_entities is #{inspect(count)}, expected #{candidate_count}"
        ]
    end
  end

  defp validate_wildcard_inventory(candidates, limit) do
    target_count = min(limit, length(candidates))
    required = ceil(target_count * @wildcard_floor_ratio)
    available = Enum.count(candidates, &(&1["wildcard"] == true))

    if available >= required do
      []
    else
      [
        "scenario deliberation requires #{required} wildcard candidates for a " <>
          "#{target_count}-candidate pool, but only #{available} are available"
      ]
    end
  end

  defp validate_assessments(assessments, candidate_ids) do
    valid = Enum.filter(assessments, &is_map/1)
    assessment_candidate_ids = valid |> valid_ids() |> MapSet.new()
    missing = MapSet.difference(candidate_ids, assessment_candidate_ids)
    unknown = MapSet.difference(assessment_candidate_ids, candidate_ids)

    profiles =
      valid
      |> Enum.map(&profile_id/1)
      |> Enum.filter(&nonempty_string?/1)
      |> MapSet.new()

    []
    |> maybe_error(
      length(valid) != length(assessments),
      "assessments must contain only JSON objects"
    )
    |> maybe_error(assessments == [], "assessments must not be empty")
    |> Kernel.++(duplicate_errors(Enum.map(valid, & &1["id"]), "assessment"))
    |> Kernel.++(Enum.flat_map(valid, &validate_assessment(&1, candidate_ids)))
    |> maybe_error(
      MapSet.size(missing) > 0 or MapSet.size(unknown) > 0,
      "assessment candidate coverage mismatch: missing [#{summarize_ids(missing)}]; unknown [#{summarize_ids(unknown)}]"
    )
    |> maybe_error(
      MapSet.size(profiles) == 0,
      "assessments must declare at least one assessor profile_id"
    )
    |> Kernel.++(duplicate_candidate_profile_errors(valid))
    |> Kernel.++(stable_profile_errors(valid, candidate_ids, profiles))
    |> Kernel.++(stable_axis_errors(valid, candidate_ids))
  end

  defp validate_assessment(assessment, candidate_ids) do
    id = assessment["id"]
    candidate_id = assessment["candidate_id"]
    scores = assessment["scores"]

    []
    |> maybe_error(not nonempty_string?(id), "assessment is missing id")
    |> maybe_error(
      not nonempty_string?(candidate_id),
      "assessment #{inspect(id)} is missing candidate_id"
    )
    |> maybe_error(
      nonempty_string?(candidate_id) and not MapSet.member?(candidate_ids, candidate_id),
      "assessment #{inspect(id)} references unknown candidate #{inspect(candidate_id)}"
    )
    |> maybe_error(
      not nonempty_string?(profile_id(assessment)),
      "assessment #{inspect(id)} is missing assessor.profile_id"
    )
    |> maybe_error(not valid_scores?(scores), "assessment #{inspect(id)} has invalid scores")
  end

  defp duplicate_candidate_profile_errors(assessments) do
    assessments
    |> Enum.map(&{&1["candidate_id"], profile_id(&1)})
    |> Enum.filter(fn {candidate_id, profile} ->
      nonempty_string?(candidate_id) and nonempty_string?(profile)
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {{_candidate_id, _profile}, 1} ->
        []

      {{candidate_id, profile}, count} ->
        [
          "duplicate assessment candidate/profile pair #{candidate_id}/#{profile}: #{count} records"
        ]
    end)
  end

  defp stable_profile_errors(assessments, candidate_ids, profiles) do
    by_candidate =
      assessments
      |> Enum.group_by(& &1["candidate_id"], &profile_id/1)
      |> Map.new(fn {candidate_id, ids} -> {candidate_id, MapSet.new(ids)} end)

    mismatched =
      candidate_ids
      |> Enum.filter(&(Map.get(by_candidate, &1, MapSet.new()) != profiles))
      |> Enum.sort()

    if mismatched == [] do
      []
    else
      [
        "assessment profile set is not stable for #{length(mismatched)} candidates; " <>
          "expected [#{summarize_ids(profiles)}], examples [#{summarize_ids(mismatched)}]"
      ]
    end
  end

  defp stable_axis_errors(assessments, candidate_ids) do
    by_candidate = Enum.group_by(assessments, & &1["candidate_id"])

    mismatched =
      candidate_ids
      |> Enum.filter(fn candidate_id ->
        by_candidate
        |> Map.get(candidate_id, [])
        |> Enum.map(&score_axes/1)
        |> Enum.uniq()
        |> length() > 1
      end)
      |> Enum.sort()

    if mismatched == [],
      do: [],
      else: [
        "assessment score axes differ across profiles for candidates: #{summarize_ids(mismatched)}"
      ]
  end

  defp project(decision_views, assessments, limits) do
    candidates = decision_views["candidates"]
    candidate_index = Map.new(candidates, &{&1["candidate_id"], &1})
    profiles = assessments |> Enum.map(&profile_id/1) |> Enum.uniq() |> Enum.sort()
    scenarios = canonical_scenarios(decision_views["scenarios"], candidate_index)
    rank_index = rank_index(scenarios)
    leaders = scenario_leaders(scenarios, candidate_index, limits[:scenario_limit])
    deliberation = scenario_deliberation(scenarios, candidate_index, limits[:scenario_limit])
    leader_ids = leaders |> pool_ids() |> MapSet.new()
    wildcards = wildcard_pool(candidates, rank_index)
    pareto = pareto_pool(candidates, rank_index)

    disagreement_all = model_disagreement(candidates, assessments, profiles)
    disagreement = Enum.take(disagreement_all, limits[:disagreement_limit])

    frontier_disagreement =
      Enum.filter(disagreement_all, &MapSet.member?(leader_ids, &1["candidate_id"]))

    flagged =
      flagged_contenders(candidates, rank_index, limits[:flagged_rank_threshold])

    resurrection =
      resurrection_pool(
        candidates,
        rank_index,
        leader_ids,
        limits[:resurrection_top_k]
      )

    %{
      "schema_version" => 1,
      "source_decision_views_schema_version" => 2,
      "projection_kind" => "non_destructive_identity_review_pools",
      "selection_made" => false,
      "candidate_coverage" => %{
        "complete" => true,
        "total_candidates" => length(candidates),
        "assessed_candidates" =>
          assessments |> Enum.map(& &1["candidate_id"]) |> Enum.uniq() |> length(),
        "assessment_records" => length(assessments),
        "profile_count" => length(profiles),
        "profiles" => profiles
      },
      "selection_rules" => selection_rules(limits),
      "counts" => %{
        "scenario_leaders" => %{
          "candidate_count" => leaders |> pool_ids() |> Enum.uniq() |> length(),
          "membership_count" => Enum.sum(Enum.map(leaders, & &1["candidate_count"]))
        },
        "scenario_deliberation" => %{
          "candidate_count" => deliberation |> pool_ids() |> Enum.uniq() |> length(),
          "membership_count" => Enum.sum(Enum.map(deliberation, & &1["candidate_count"]))
        },
        "wildcard_pool" => %{"candidate_count" => length(wildcards)},
        "pareto_pool" => %{"candidate_count" => length(pareto)},
        "model_disagreement" => %{"candidate_count" => length(disagreement)},
        "frontier_disagreement" => %{"candidate_count" => length(frontier_disagreement)},
        "flagged_contenders" => %{"candidate_count" => length(flagged)},
        "resurrection_pool" => %{"candidate_count" => length(resurrection)}
      },
      "pools" => %{
        "scenario_leaders" => leaders,
        "scenario_deliberation" => deliberation,
        "wildcard_pool" => wildcards,
        "pareto_pool" => pareto,
        "model_disagreement" => disagreement,
        "frontier_disagreement" => frontier_disagreement,
        "flagged_contenders" => flagged,
        "resurrection_pool" => resurrection
      }
    }
  end

  defp canonical_scenarios(scenarios, candidate_index) do
    scenarios
    |> Enum.sort_by(& &1["id"])
    |> Enum.map(fn scenario ->
      ranked =
        scenario["ranked"]
        |> Enum.sort_by(fn row ->
          candidate = Map.fetch!(candidate_index, row["candidate_id"])

          {
            -row["scenario_score"],
            String.downcase(candidate["display"]),
            candidate["display"],
            row["candidate_id"]
          }
        end)
        |> Enum.with_index(1)
        |> Enum.map(fn {row, rank} -> Map.put(row, "rank", rank) end)

      %{
        "id" => scenario["id"],
        "label" => scenario["label"],
        "ranked" => ranked
      }
    end)
  end

  defp rank_index(scenarios) do
    scenarios
    |> Enum.reduce(%{}, fn scenario, acc ->
      Enum.reduce(scenario["ranked"], acc, fn row, inner ->
        membership = %{
          "scenario_id" => scenario["id"],
          "rank" => row["rank"],
          "pareto" => row["pareto"]
        }

        Map.update(inner, row["candidate_id"], [membership], &[membership | &1])
      end)
    end)
    |> Map.new(fn {candidate_id, memberships} ->
      {candidate_id, Enum.sort_by(memberships, & &1["scenario_id"])}
    end)
  end

  defp scenario_leaders(scenarios, candidate_index, limit) do
    Enum.map(scenarios, fn scenario ->
      candidates =
        scenario["ranked"]
        |> Enum.take(limit)
        |> Enum.map(fn row ->
          candidate_index
          |> Map.fetch!(row["candidate_id"])
          |> candidate_ref()
          |> Map.merge(Map.take(row, ~w(rank scenario_score tier pareto)))
        end)

      %{
        "scenario_id" => scenario["id"],
        "scenario_label" => scenario["label"],
        "candidate_count" => length(candidates),
        "candidates" => candidates
      }
    end)
  end

  defp scenario_deliberation(scenarios, candidate_index, limit) do
    Enum.map(scenarios, fn scenario ->
      ranked =
        Enum.map(scenario["ranked"], fn row ->
          candidate = Map.fetch!(candidate_index, row["candidate_id"])

          candidate
          |> candidate_ref()
          |> Map.merge(Map.take(row, ~w(rank scenario_score tier pareto)))
          |> Map.put("selection_basis", "score_rank")
        end)

      target_count = min(limit, length(ranked))
      leaders = Enum.take(ranked, target_count)
      required_wildcards = ceil(target_count * @wildcard_floor_ratio)
      present_wildcards = Enum.count(leaders, & &1["wildcard"])
      needed = max(required_wildcards - present_wildcards, 0)
      leader_ids = leaders |> Enum.map(& &1["candidate_id"]) |> MapSet.new()

      additions =
        ranked
        |> Enum.reject(&MapSet.member?(leader_ids, &1["candidate_id"]))
        |> Enum.filter(& &1["wildcard"])
        |> Enum.take(needed)
        |> Enum.map(&Map.put(&1, "selection_basis", "wildcard_floor"))

      drop_ids =
        leaders
        |> Enum.reverse()
        |> Enum.reject(& &1["wildcard"])
        |> Enum.take(length(additions))
        |> Enum.map(& &1["candidate_id"])
        |> MapSet.new()

      candidates =
        leaders
        |> Enum.reject(&MapSet.member?(drop_ids, &1["candidate_id"]))
        |> Kernel.++(additions)
        |> Enum.sort_by(& &1["rank"])

      actual_wildcards = Enum.count(candidates, & &1["wildcard"])

      %{
        "scenario_id" => scenario["id"],
        "scenario_label" => scenario["label"],
        "candidate_count" => length(candidates),
        "wildcard_count" => actual_wildcards,
        "required_wildcard_count" => required_wildcards,
        "wildcard_floor_met" => actual_wildcards >= required_wildcards,
        "candidates" => candidates
      }
    end)
  end

  defp wildcard_pool(candidates, rank_index) do
    candidates
    |> Enum.filter(&(&1["wildcard"] == true))
    |> Enum.map(fn candidate ->
      candidate
      |> candidate_ref()
      |> Map.put("best_scenario_rank", best_scenario_rank(rank_index, candidate["candidate_id"]))
    end)
    |> Enum.sort_by(&ranked_candidate_sort/1)
  end

  defp pareto_pool(candidates, rank_index) do
    candidates
    |> Enum.flat_map(fn candidate ->
      memberships =
        rank_index
        |> Map.get(candidate["candidate_id"], [])
        |> Enum.filter(& &1["pareto"])
        |> Enum.map(&Map.take(&1, ~w(scenario_id rank)))

      if memberships == [] do
        []
      else
        [
          candidate
          |> candidate_ref()
          |> Map.put("best_scenario_rank", memberships |> Enum.map(& &1["rank"]) |> Enum.min())
          |> Map.put("scenario_memberships", memberships)
        ]
      end
    end)
    |> Enum.sort_by(&ranked_candidate_sort/1)
  end

  defp model_disagreement(candidates, assessments, profiles) do
    records_by_candidate = Enum.group_by(assessments, & &1["candidate_id"])

    candidates
    |> Enum.map(fn candidate ->
      records = Map.fetch!(records_by_candidate, candidate["candidate_id"])
      by_profile = Map.new(records, &{profile_id(&1), &1["scores"]})
      axes = records |> hd() |> score_axes()

      ranges =
        Enum.map(axes, fn axis ->
          profile_scores = Map.new(profiles, &{&1, get_in(by_profile, [&1, axis])})
          values = Map.values(profile_scores)

          %{
            "axis" => axis,
            "range" => Enum.max(values) - Enum.min(values),
            "profile_scores" => profile_scores
          }
        end)

      decisive = Enum.min_by(ranges, &{-&1["range"], &1["axis"]})

      candidate
      |> candidate_ref()
      |> Map.put("max_axis_range", decisive["range"])
      |> Map.put("mean_axis_range", Enum.sum(Enum.map(ranges, & &1["range"])) / length(ranges))
      |> Map.put("decisive_axis", decisive["axis"])
      |> Map.put("profile_scores", decisive["profile_scores"])
    end)
    |> Enum.sort_by(fn row ->
      {
        -row["max_axis_range"],
        -row["mean_axis_range"],
        String.downcase(row["display"]),
        row["display"],
        row["candidate_id"]
      }
    end)
  end

  defp flagged_contenders(candidates, rank_index, threshold) do
    candidates
    |> Enum.flat_map(fn candidate ->
      best_rank = best_scenario_rank(rank_index, candidate["candidate_id"])

      if candidate["flags"] != [] and is_integer(best_rank) and best_rank <= threshold do
        [
          candidate
          |> candidate_ref()
          |> Map.put("best_scenario_rank", best_rank)
          |> Map.put("flags", Enum.sort(candidate["flags"]))
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(&ranked_candidate_sort/1)
  end

  defp resurrection_pool(candidates, rank_index, leader_ids, top_k) do
    qualifying = axis_qualifiers(candidates, top_k)

    qualifying
    |> Enum.reject(fn {candidate_id, _axes} -> MapSet.member?(leader_ids, candidate_id) end)
    |> Enum.map(fn {candidate_id, axes} ->
      candidate = Enum.find(candidates, &(&1["candidate_id"] == candidate_id))
      axes = Enum.sort_by(axes, &{&1["rank"], &1["axis"]})

      candidate
      |> candidate_ref()
      |> Map.put("best_axis_rank", axes |> Enum.map(& &1["rank"]) |> Enum.min())
      |> Map.put("best_scenario_rank", best_scenario_rank(rank_index, candidate_id))
      |> Map.put("qualifying_axes", axes)
    end)
    |> Enum.sort_by(fn row ->
      {
        row["best_axis_rank"],
        nullable_rank(row["best_scenario_rank"]),
        String.downcase(row["display"]),
        row["display"],
        row["candidate_id"]
      }
    end)
  end

  defp axis_qualifiers(candidates, top_k) do
    candidates
    |> Enum.flat_map(&Map.keys(&1["axis_scores"]))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn axis, acc ->
      candidates
      |> Enum.filter(&is_number(get_in(&1, ["axis_scores", axis, "mean"])))
      |> Enum.sort_by(fn candidate ->
        {
          -get_in(candidate, ["axis_scores", axis, "mean"]),
          String.downcase(candidate["display"]),
          candidate["display"],
          candidate["candidate_id"]
        }
      end)
      |> Enum.take(top_k)
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {candidate, rank}, inner ->
        qualifier = %{
          "axis" => axis,
          "rank" => rank,
          "mean" => get_in(candidate, ["axis_scores", axis, "mean"])
        }

        Map.update(inner, candidate["candidate_id"], [qualifier], &[qualifier | &1])
      end)
    end)
  end

  defp selection_rules(limits) do
    %{
      "scenario_leaders" => %{
        "limit_per_scenario" => limits[:scenario_limit],
        "rule" =>
          "Diagnostic top candidates in each scenario by score, then display and candidate ID; not a deliberative narrowing pool."
      },
      "scenario_deliberation" => %{
        "limit_per_scenario" => limits[:scenario_limit],
        "wildcard_floor_ratio" => @wildcard_floor_ratio,
        "rule" =>
          "Start with scenario leaders, then replace the lowest-ranked non-wildcards with the next ranked wildcards until the floor is met."
      },
      "wildcard_pool" => %{
        "rule" =>
          "Every candidate with wildcard=true, ordered by best scenario rank then display."
      },
      "pareto_pool" => %{
        "rule" => "Union of candidates marked Pareto in any scenario, retaining every membership."
      },
      "model_disagreement" => %{
        "limit" => limits[:disagreement_limit],
        "rule" =>
          "Largest per-axis profile-score range, then mean axis range, display, and candidate ID."
      },
      "frontier_disagreement" => %{
        "rule" => "Every unique scenario leader, ordered by the same model-disagreement rule."
      },
      "flagged_contenders" => %{
        "best_scenario_rank_threshold" => limits[:flagged_rank_threshold],
        "rule" =>
          "Candidates with one or more flags whose best scenario rank is within the threshold."
      },
      "resurrection_pool" => %{
        "top_k_per_axis" => limits[:resurrection_top_k],
        "rule" =>
          "Candidates outside every scenario leader pool that rank in the top K by at least one axis mean."
      }
    }
  end

  defp candidate_ref(candidate),
    do: Map.take(candidate, ~w(candidate_id display wildcard))

  defp pool_ids(leaders) do
    for scenario <- leaders, candidate <- scenario["candidates"], do: candidate["candidate_id"]
  end

  defp best_scenario_rank(rank_index, candidate_id) do
    case Map.get(rank_index, candidate_id, []) do
      [] -> nil
      memberships -> memberships |> Enum.map(& &1["rank"]) |> Enum.min()
    end
  end

  defp ranked_candidate_sort(row) do
    {
      nullable_rank(row["best_scenario_rank"]),
      String.downcase(row["display"]),
      row["display"],
      row["candidate_id"]
    }
  end

  defp nullable_rank(nil), do: 1_000_000_000
  defp nullable_rank(rank), do: rank

  defp profile_id(%{"assessor" => assessor}) when is_map(assessor),
    do: assessor["profile_id"]

  defp profile_id(_assessment), do: nil

  defp score_axes(%{"scores" => scores}) when is_map(scores),
    do: scores |> Map.keys() |> Enum.sort()

  defp score_axes(_assessment), do: []

  defp valid_axis_scores?(scores) when is_map(scores) and map_size(scores) > 0 do
    Enum.all?(scores, fn {axis, score} ->
      nonempty_string?(axis) and is_map(score) and is_number(score["mean"])
    end)
  end

  defp valid_axis_scores?(_scores), do: false

  defp valid_scores?(scores) when is_map(scores) and map_size(scores) > 0 do
    Enum.all?(scores, fn {axis, score} -> nonempty_string?(axis) and is_number(score) end)
  end

  defp valid_scores?(_scores), do: false
  defp string_list?(items), do: is_list(items) and Enum.all?(items, &nonempty_string?/1)
  defp nonempty_string?(value), do: is_binary(value) and value != ""
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp valid_ids(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&(&1["candidate_id"] || &1["id"]))
    |> Enum.filter(&nonempty_string?/1)
  end

  defp duplicate_errors(values, label) do
    values
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {_value, 1} -> []
      {value, count} -> ["duplicate #{label} #{value}: #{count} records"]
    end)
  end

  defp summarize_ids(ids) do
    values = ids |> Enum.to_list() |> Enum.sort()
    shown = values |> Enum.take(5) |> Enum.join(", ")
    if length(values) > 5, do: shown <> " (+#{length(values) - 5} more)", else: shown
  end

  defp maybe_error(errors, true, message), do: errors ++ [message]
  defp maybe_error(errors, false, _message), do: errors
end

defmodule Imp.IdentityProgress.Artifacts do
  @moduledoc false

  alias Imp.{IdentityCollision, IdentityInternationalScreen}

  @terminal_collision_statuses ~w(collision no-exact-record skipped)
  @collision_statuses @terminal_collision_statuses ++ ~w(rate-limited unverified)
  @code_form_keys ~w(hex_package otp_app module_root mix_task_prefix config_prefix telemetry_prefix)
  @prose_form_keys ~w(readme_headline paper_title conference_sentence error_sentence)
  @max_errors 20

  @spec pipeline_report(map(), [map()], MapSet.t(String.t()), map(), map()) :: map()
  def pipeline_report(paths, accepted_events, accepted_ids, atlas, workflow) do
    axis_ids = atlas |> Map.get("assessment_axes", []) |> Enum.map(& &1["id"]) |> MapSet.new()
    registry = inspect_jsonl(paths.registry)
    enrichments = paths.enrichments |> inspect_jsonl() |> validate_artifact(&enrichment_errors/1)

    assessments =
      paths.assessments
      |> inspect_jsonl()
      |> validate_artifact(&assessment_errors(&1, axis_ids))

    collision_checks =
      paths.collision_checks
      |> inspect_jsonl()
      |> validate_artifact(&collision_errors/1)

    flags = paths.flags |> inspect_jsonl() |> validate_artifact(&no_errors/1)
    dissent = paths.dissent |> inspect_jsonl() |> validate_artifact(&no_errors/1)
    active_enrichments = enrichments.active_records

    %{
      "registry" => registry_coverage(registry, accepted_events),
      "enrichments" => candidate_coverage(active_enrichments, accepted_ids, enrichments),
      "spoken_forms" =>
        form_coverage(active_enrichments, accepted_ids, enrichments, &spoken_form?/1),
      "code_forms" => code_coverage(active_enrichments, accepted_ids, enrichments),
      "architecture_forms" =>
        form_coverage(active_enrichments, accepted_ids, enrichments, &architecture_form?/1),
      "international_review" =>
        international_evidence_coverage(
          active_enrichments,
          accepted_ids,
          enrichments,
          accepted_events
        ),
      "assessments" =>
        assessment_coverage(
          assessments,
          accepted_ids,
          axis_ids,
          workflow["required_assessment_replicates"]
        ),
      "collision_checks" =>
        collision_coverage(
          collision_checks,
          accepted_ids,
          workflow["collision_sources"],
          active_enrichments
        ),
      "flags" => record_summary(flags, accepted_ids),
      "dissent" => record_summary(dissent, accepted_ids),
      "accepted_candidate_entities" => MapSet.size(accepted_ids)
    }
  end

  defp registry_coverage(artifact, expected_events) do
    expected_by_id = Map.new(expected_events, &{&1["event_id"], &1})
    expected_ids = expected_by_id |> Map.keys() |> MapSet.new()
    grouped = Enum.group_by(artifact.records, & &1["event_id"])

    completed =
      Enum.count(expected_by_id, fn {event_id, expected} ->
        Map.get(grouped, event_id) == [expected]
      end)

    actual_ids =
      artifact.records
      |> Enum.map(& &1["event_id"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    extra_events = actual_ids |> MapSet.difference(expected_ids) |> MapSet.size()

    duplicate_event_ids =
      Enum.count(grouped, fn {event_id, records} ->
        is_binary(event_id) and length(records) > 1
      end)

    missing_event_ids = MapSet.difference(expected_ids, actual_ids) |> MapSet.size()

    stale_events =
      Enum.count(expected_by_id, fn {event_id, expected} ->
        case Map.get(grouped, event_id, []) do
          [] -> false
          [^expected] -> false
          _records -> true
        end
      end)

    missing_id_records = Enum.count(artifact.records, &(not is_binary(&1["event_id"])))
    malformed_or_duplicate = duplicate_event_ids + missing_id_records
    out_of_sync? = extra_events > 0 or malformed_or_duplicate > 0 or stale_events > 0

    artifact
    |> coverage(completed, map_size(expected_by_id), %{
      "observed_records" => length(artifact.records),
      "extra_events" => extra_events,
      "missing_events" => missing_event_ids,
      "stale_events" => stale_events,
      "duplicate_event_ids" => duplicate_event_ids,
      "missing_event_id_records" => missing_id_records,
      "malformed_or_duplicate_events" => malformed_or_duplicate
    })
    |> mark_out_of_sync(out_of_sync?)
  end

  defp candidate_coverage(records, accepted_ids, artifact) do
    covered_ids = records |> Enum.map(& &1["candidate_id"]) |> MapSet.new()
    extra_candidates = MapSet.difference(covered_ids, accepted_ids) |> MapSet.size()

    artifact
    |> coverage(
      MapSet.intersection(covered_ids, accepted_ids) |> MapSet.size(),
      MapSet.size(accepted_ids),
      %{
        "observed_records" => length(artifact.records),
        "valid_records" => length(artifact.valid_records),
        "active_records" => length(records),
        "extra_candidate_entities" => extra_candidates
      }
    )
    |> mark_out_of_sync(extra_candidates > 0)
  end

  defp form_coverage(records, accepted_ids, artifact, predicate) do
    covered_ids =
      records |> Enum.filter(predicate) |> Enum.map(& &1["candidate_id"]) |> MapSet.new()

    coverage(
      artifact,
      MapSet.intersection(covered_ids, accepted_ids) |> MapSet.size(),
      MapSet.size(accepted_ids)
    )
  end

  defp code_coverage(records, accepted_ids, artifact) do
    usable_ids =
      records
      |> Enum.filter(&usable_code_form?/1)
      |> Enum.map(& &1["candidate_id"])
      |> MapSet.new()

    records
    |> form_coverage(accepted_ids, artifact, &code_form?/1)
    |> Map.put(
      "usable_candidates",
      MapSet.intersection(usable_ids, accepted_ids) |> MapSet.size()
    )
  end

  defp international_evidence_coverage(records, accepted_ids, artifact, accepted_events) do
    observations_by_candidate =
      accepted_events
      |> Enum.filter(&(&1["event_type"] == "candidate_observed"))
      |> Enum.group_by(& &1["candidate_id"])

    matching = Enum.filter(records, &MapSet.member?(accepted_ids, &1["candidate_id"]))

    current =
      Enum.filter(matching, fn record ->
        observations = Map.get(observations_by_candidate, record["candidate_id"], [])
        IdentityInternationalScreen.current?(record["international_screen"], observations)
      end)

    current_by_candidate = Enum.group_by(current, & &1["candidate_id"])
    matching_by_candidate = Enum.group_by(matching, & &1["candidate_id"])

    attention_candidates =
      Enum.count(current_by_candidate, fn {_candidate_id, candidate_records} ->
        screen_status?(candidate_records, "attention")
      end)

    unverified_candidates =
      Enum.count(current_by_candidate, fn {_candidate_id, candidate_records} ->
        screen_status?(candidate_records, "unverified")
      end)

    extra_candidates =
      records
      |> Enum.map(& &1["candidate_id"])
      |> MapSet.new()
      |> MapSet.difference(accepted_ids)
      |> MapSet.size()

    stale_candidates =
      matching_by_candidate
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(Map.keys(current_by_candidate)))
      |> MapSet.size()

    artifact
    |> coverage(map_size(current_by_candidate), MapSet.size(accepted_ids), %{
      "algorithmically_screened_candidates" => map_size(current_by_candidate),
      "attention_candidates" => attention_candidates,
      "unverified_candidates" => unverified_candidates,
      "human_validated_candidates" => 0,
      "stale_screen_candidates" => stale_candidates,
      "extra_candidate_entities" => extra_candidates
    })
    |> mark_started(matching != [])
    |> mark_out_of_sync(stale_candidates > 0 or extra_candidates > 0)
  end

  defp assessment_coverage(artifact, accepted_ids, axis_ids, required_replicates) do
    matching =
      Enum.filter(artifact.active_records, &MapSet.member?(accepted_ids, &1["candidate_id"]))

    grouped = Enum.group_by(matching, & &1["candidate_id"])

    complete_candidates =
      Enum.count(grouped, fn {_candidate_id, records} ->
        axes_have_replicates?(records, axis_ids, required_replicates)
      end)

    extra_candidates =
      artifact.active_records
      |> Enum.map(& &1["candidate_id"])
      |> MapSet.new()
      |> MapSet.difference(accepted_ids)
      |> MapSet.size()

    artifact
    |> coverage(complete_candidates, MapSet.size(accepted_ids), %{
      "required_replicates_per_candidate" => required_replicates,
      "matching_assessment_records" => length(matching),
      "target_assessment_records" => MapSet.size(accepted_ids) * required_replicates,
      "candidates_with_any_assessment" => map_size(grouped),
      "extra_candidate_entities" => extra_candidates
    })
    |> mark_started(matching != [])
    |> mark_out_of_sync(extra_candidates > 0)
  end

  defp axes_have_replicates?(records, axis_ids, required_replicates) do
    Enum.all?(axis_ids, fn axis_id ->
      records
      |> Enum.filter(&valid_axis_score?(&1, axis_id))
      |> Enum.map(&assessor_key/1)
      |> MapSet.new()
      |> MapSet.size()
      |> Kernel.>=(required_replicates)
    end)
  end

  defp collision_coverage(artifact, accepted_ids, sources, enrichments) do
    queries = Map.new(enrichments, &{&1["candidate_id"], code_form_value(&1, "hex_package")})

    current =
      artifact.active_records
      |> Enum.filter(fn record ->
        candidate_id = record["candidate_id"]

        MapSet.member?(accepted_ids, candidate_id) and Map.has_key?(queries, candidate_id) and
          record["source"] in sources and record["query"] == Map.fetch!(queries, candidate_id)
      end)
      |> Enum.group_by(&{&1["candidate_id"], &1["source"]})
      |> Enum.map(fn {_key, attempts} -> Enum.max_by(attempts, & &1["attempt"]) end)

    extra_candidates =
      artifact.active_records
      |> Enum.map(& &1["candidate_id"])
      |> MapSet.new()
      |> MapSet.difference(accepted_ids)
      |> MapSet.size()

    artifact
    |> coverage(
      Enum.count(current, &(&1["status"] in @terminal_collision_statuses)),
      MapSet.size(accepted_ids) * length(sources),
      %{
        "observed_current_checks" => length(current),
        "unresolved_checks" =>
          Enum.count(current, &(&1["status"] not in @terminal_collision_statuses)),
        "sources" => sources,
        "extra_candidate_entities" => extra_candidates
      }
    )
    |> mark_started(current != [])
    |> mark_out_of_sync(extra_candidates > 0)
  end

  defp record_summary(artifact, accepted_ids) do
    %{
      "artifact_state" => artifact.state,
      "records" => length(artifact.records),
      "valid_records" => length(artifact.valid_records),
      "active_records" => length(artifact.active_records),
      "accepted_candidate_records" =>
        Enum.count(
          artifact.active_records,
          &MapSet.member?(accepted_ids, &1["candidate_id"])
        ),
      "parse_error_count" => length(artifact.errors),
      "parse_errors" => artifact.errors
    }
  end

  defp validate_artifact(artifact, validator) do
    indexed = Enum.with_index(artifact.records, 1)

    shape_errors =
      Map.new(indexed, fn {record, line} ->
        {line, candidate_event_errors(record) ++ validator.(record)}
      end)

    duplicate_ids =
      artifact.records
      |> Enum.map(& &1["id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> MapSet.new(&elem(&1, 0))

    base_valid =
      Enum.flat_map(indexed, fn {record, line} ->
        if Map.fetch!(shape_errors, line) == [] and
             not MapSet.member?(duplicate_ids, record["id"]) do
          [record]
        else
          []
        end
      end)

    {supersession_errors, invalid_superseders} = supersession_errors(base_valid)

    valid_records =
      Enum.reject(base_valid, &MapSet.member?(invalid_superseders, &1["id"]))

    superseded_ids =
      valid_records |> Enum.map(& &1["supersedes"]) |> Enum.filter(&is_binary/1) |> MapSet.new()

    active_records = Enum.reject(valid_records, &MapSet.member?(superseded_ids, &1["id"]))

    semantic_errors =
      shape_errors
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {line, errors} ->
        Enum.map(errors, &"#{artifact.path}:#{line}: #{&1}")
      end)
      |> Kernel.++(
        Enum.map(duplicate_ids, &"#{artifact.path}: duplicate record id #{inspect(&1)}")
      )
      |> Kernel.++(Enum.map(supersession_errors, &"#{artifact.path}: #{&1}"))

    errors = Enum.take(artifact.errors ++ semantic_errors, @max_errors)

    %{
      artifact
      | state: artifact_state(artifact.state, errors),
        errors: errors
    }
    |> Map.put(:valid_records, valid_records)
    |> Map.put(:active_records, active_records)
  end

  defp supersession_errors(records) do
    by_id = Map.new(records, &{&1["id"], &1})

    Enum.reduce(records, {[], MapSet.new()}, &check_supersession(&1, &2, by_id))
  end

  defp check_supersession(%{"supersedes" => nil}, result, _by_id), do: result

  defp check_supersession(record, {errors, invalid}, by_id) do
    problems = supersession_problems(record, record["supersedes"], by_id)

    case problems do
      [] ->
        {errors, invalid}

      problems ->
        messages = Enum.map(problems, &"record #{record["id"]} #{&1}")
        {errors ++ messages, MapSet.put(invalid, record["id"])}
    end
  end

  defp supersession_problems(record, target_id, by_id) do
    target = Map.get(by_id, target_id)

    []
    |> maybe_error(not is_binary(target_id), "has a non-string supersedes reference")
    |> maybe_error(
      is_binary(target_id) and is_nil(target),
      "supersedes missing record #{target_id}"
    )
    |> maybe_error(
      is_map(target) and target["candidate_id"] != record["candidate_id"],
      "supersedes a record for another candidate"
    )
    |> maybe_error(
      supersession_cycle?(record["id"], target_id, by_id),
      "forms a supersession cycle"
    )
  end

  defp supersession_cycle?(origin, target_id, by_id) when is_binary(target_id) do
    follow_supersession(origin, target_id, by_id, MapSet.new())
  end

  defp supersession_cycle?(_origin, _target_id, _by_id), do: false

  defp follow_supersession(origin, current, by_id, seen) do
    cond do
      current == origin ->
        true

      MapSet.member?(seen, current) ->
        false

      true ->
        case Map.get(by_id, current) do
          %{"supersedes" => next} when is_binary(next) ->
            follow_supersession(origin, next, by_id, MapSet.put(seen, current))

          _record ->
            false
        end
    end
  end

  defp candidate_event_errors(record) do
    []
    |> maybe_error(not nonempty?(record["id"]), "id must be a non-empty string")
    |> maybe_error(
      not candidate_id?(record["candidate_id"]),
      "candidate_id must have the canonical cand-<hex> form"
    )
    |> maybe_error(
      not is_nil(record["supersedes"]) and not is_binary(record["supersedes"]),
      "supersedes must be a string or null"
    )
  end

  defp enrichment_errors(record) do
    spoken = record["spoken_forms"]
    code = record["code_forms"]
    prose = record["prose_forms"]

    []
    |> maybe_error(not iso8601?(record["enriched_at"]), "enriched_at must be ISO 8601")
    |> maybe_error(not assessor?(record["assessor"]), "assessor must identify kind and name")
    |> maybe_error(not spoken_forms_shape?(spoken), "spoken_forms is incomplete")
    |> maybe_error(not code_forms_shape?(code), "code_forms is incomplete")
    |> maybe_error(not prose_forms_shape?(prose), "prose_forms is incomplete")
    |> maybe_error(
      not architecture_forms_shape?(record["architecture_forms"]),
      "architecture_forms must be a non-empty array"
    )
    |> maybe_error(
      not international_notes_shape?(record["international_notes"]),
      "international_notes must be valid review records"
    )
    |> maybe_error(
      not international_screen_shape?(record["international_screen"]),
      "international_screen must be a complete deterministic evidence record"
    )
    |> maybe_error(
      not string_list?(record["future_scope_notes"]),
      "future_scope_notes must be strings"
    )
  end

  defp assessment_errors(record, axis_ids) do
    scores = record["scores"]

    unknown_axes =
      if is_map(scores),
        do: scores |> Map.keys() |> MapSet.new() |> MapSet.difference(axis_ids),
        else: MapSet.new()

    invalid_scores =
      is_map(scores) and
        Enum.any?(scores, fn {_axis, score} ->
          not is_number(score) or score < 0 or score > 5
        end)

    []
    |> maybe_error(not iso8601?(record["assessed_at"]), "assessed_at must be ISO 8601")
    |> maybe_error(not assessor?(record["assessor"]), "assessor must identify kind and name")
    |> maybe_error(not is_map(record["context"]), "context must be an object")
    |> maybe_error(not is_map(scores) or scores == %{}, "scores must be a non-empty object")
    |> maybe_error(MapSet.size(unknown_axes) > 0, "scores contain unknown assessment axes")
    |> maybe_error(invalid_scores, "scores must be numeric values in 0..5")
    |> maybe_error(not confidence?(record["confidence"]), "confidence must be numeric in 0..1")
    |> maybe_error(not nonempty?(record["reasoning"]), "reasoning must be non-empty")
  end

  defp collision_errors(record) do
    []
    |> maybe_error(not nonempty?(record["check_key"]), "check_key must be non-empty")
    |> maybe_error(
      not is_integer(record["attempt"]) or record["attempt"] < 1,
      "attempt must be a positive integer"
    )
    |> maybe_error(not iso8601?(record["checked_at"]), "checked_at must be ISO 8601")
    |> maybe_error(
      record["source"] not in IdentityCollision.source_ids(),
      "source is unsupported"
    )
    |> maybe_error(
      not is_nil(record["query"]) and not is_binary(record["query"]),
      "query must be a string or null"
    )
    |> maybe_error(record["status"] not in @collision_statuses, "status is unsupported")
  end

  defp spoken_form?(record), do: spoken_forms_shape?(record["spoken_forms"])

  defp spoken_forms_shape?(%{
         "pronunciation" => pronunciation,
         "recommendation" => recommendation,
         "support_call" => support_call
       }),
       do:
         (is_nil(pronunciation) or is_binary(pronunciation)) and nonempty?(recommendation) and
           nonempty?(support_call)

  defp spoken_forms_shape?(_spoken), do: false

  defp code_form?(record), do: code_forms_shape?(record["code_forms"])

  defp code_forms_shape?(code_forms) when is_map(code_forms) do
    Enum.all?(@code_form_keys, fn key ->
      Map.has_key?(code_forms, key) and (is_nil(code_forms[key]) or is_binary(code_forms[key]))
    end)
  end

  defp code_forms_shape?(_code_forms), do: false

  defp usable_code_form?(record),
    do: Enum.any?(@code_form_keys, &nonempty?(code_form_value(record, &1)))

  defp code_form_value(%{"code_forms" => code_forms}, key) when is_map(code_forms),
    do: Map.get(code_forms, key)

  defp code_form_value(_record, _key), do: nil

  defp prose_forms_shape?(prose) when is_map(prose),
    do: Enum.all?(@prose_form_keys, &nonempty?(prose[&1]))

  defp prose_forms_shape?(_prose), do: false

  defp architecture_forms_shape?(forms) when is_list(forms) and forms != [] do
    Enum.all?(forms, fn
      %{"architecture_id" => id, "form" => form, "notes" => notes} ->
        nonempty?(id) and nonempty?(form) and is_binary(notes)

      _form ->
        false
    end)
  end

  defp architecture_forms_shape?(_forms), do: false

  defp international_notes_shape?(notes) when is_list(notes) do
    Enum.all?(notes, fn
      %{
        "language_or_region" => region,
        "observation" => observation,
        "confidence" => confidence,
        "evidence_refs" => refs
      } ->
        nonempty?(region) and nonempty?(observation) and confidence?(confidence) and
          string_list?(refs)

      _note ->
        false
    end)
  end

  defp international_notes_shape?(_notes), do: false

  defp international_screen_shape?(%{
         "schema_version" => 1,
         "method" => "beam-deterministic-v1",
         "basis" => "algorithmic-screen",
         "input_sha256" => input_sha256,
         "evidence_refs" => evidence_refs,
         "checks" => checks,
         "limitations" => limitations
       }) do
    check_ids = IdentityInternationalScreen.check_ids()

    is_binary(input_sha256) and String.match?(input_sha256, ~r/^[a-f0-9]{64}$/) and
      unique_string_list?(evidence_refs) and nonempty_string_list?(limitations) and
      is_list(checks) and length(checks) == length(check_ids) and
      checks |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort(check_ids) and
      Enum.all?(checks, &international_check_shape?/1)
  end

  defp international_screen_shape?(_screen), do: false

  defp international_check_shape?(%{
         "id" => id,
         "status" => status,
         "signals" => signals
       }) do
    id in IdentityInternationalScreen.check_ids() and
      status in IdentityInternationalScreen.statuses() and nonempty_string_list?(signals) and
      length(signals) == length(Enum.uniq(signals))
  end

  defp international_check_shape?(_check), do: false

  defp architecture_form?(record),
    do: is_list(record["architecture_forms"]) and record["architecture_forms"] != []

  defp screen_status?(records, status) do
    Enum.any?(records, fn record ->
      Enum.any?(record["international_screen"]["checks"], &(&1["status"] == status))
    end)
  end

  defp valid_axis_score?(record, axis_id) do
    case record["scores"] do
      %{^axis_id => score} -> is_number(score) and score >= 0 and score <= 5
      _scores -> false
    end
  end

  defp assessor_key(record) do
    assessor = record["assessor"]
    {assessor["kind"], assessor["name"]}
  end

  defp assessor?(%{"kind" => kind, "name" => name}),
    do: nonempty?(kind) and nonempty?(name)

  defp assessor?(_assessor), do: false

  defp candidate_id?(value),
    do: is_binary(value) and String.match?(value, ~r/^cand-[a-f0-9]{16}$/)

  defp confidence?(value), do: is_number(value) and value >= 0 and value <= 1

  defp iso8601?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp iso8601?(_value), do: false
  defp no_errors(_record), do: []
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp unique_string_list?(value),
    do: string_list?(value) and length(value) == length(Enum.uniq(value))

  defp nonempty_string_list?(value),
    do: is_list(value) and value != [] and Enum.all?(value, &nonempty?/1)

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp inspect_jsonl(path) do
    if File.exists?(path) do
      {records, errors} =
        path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.with_index(1)
        |> Enum.reduce({[], []}, &decode_jsonl_line(path, &1, &2))

      %{
        path: path,
        state: if(errors == [], do: "present", else: "partial"),
        records: Enum.reverse(records),
        errors: Enum.reverse(errors)
      }
    else
      %{path: path, state: "missing", records: [], errors: []}
    end
  end

  defp decode_jsonl_line(_path, {"", _line_number}, acc), do: acc

  defp decode_jsonl_line(path, {line, line_number}, {records, errors}) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) ->
        {[record | records], errors}

      {:ok, _other} ->
        {records, add_error(errors, "#{path}:#{line_number} is not an object")}

      {:error, error} ->
        {records, add_error(errors, "#{path}:#{line_number}: #{Exception.message(error)}")}
    end
  end

  defp add_error(errors, message) when length(errors) < @max_errors, do: [message | errors]
  defp add_error(errors, _message), do: errors

  defp artifact_state("missing", _errors), do: "missing"
  defp artifact_state(_state, []), do: "present"
  defp artifact_state(_state, _errors), do: "partial"

  defp coverage(artifact, completed, target, extra \\ %{}) do
    state =
      cond do
        artifact.errors != [] -> "needs_attention"
        artifact.state == "missing" -> "missing"
        target == 0 -> "not_applicable"
        completed >= target -> "complete"
        completed == 0 -> "not_started"
        true -> "in_progress"
      end

    Map.merge(
      %{
        "state" => state,
        "completed" => completed,
        "target" => target,
        "fraction" => fraction(completed, target),
        "parse_error_count" => length(artifact.errors),
        "parse_errors" => artifact.errors
      },
      extra
    )
  end

  defp mark_out_of_sync(%{"state" => state} = coverage, true)
       when state not in ["missing", "needs_attention", "not_applicable"],
       do: Map.put(coverage, "state", "out_of_sync")

  defp mark_out_of_sync(coverage, _condition), do: coverage

  defp mark_started(%{"state" => "not_started"} = coverage, true),
    do: Map.put(coverage, "state", "in_progress")

  defp mark_started(coverage, _condition), do: coverage

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors
  defp fraction(_numerator, 0), do: 0.0
  defp fraction(numerator, denominator), do: numerator / denominator
end

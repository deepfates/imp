defmodule Imp.IdentityAssessmentConsolidation do
  @moduledoc """
  Validates and deterministically consolidates identity assessment shards.

  Assessment and run-ledger inputs are always explicit. The consolidator does
  not discover shards on its own, which keeps active or partial provider output
  out of a canonical build unless the caller deliberately includes it.
  """

  alias Imp.IdentityCheckpoint

  @run_started "identity_assessment_run_started"
  @run_completed "identity_assessment_run_completed"
  @batch_failed "identity_assessment_batch_failed"
  @provenance_keys ~w(source_ledger source_run_id source_run_occurrence)

  @default_schema "identity/schema/assessment.schema.json"
  @default_out "identity/assessments.jsonl"
  @default_runs_out "identity/assessment-runs.jsonl"
  @default_report "identity/reports/assessment-audit.json"

  @doc """
  Consolidates explicitly supplied assessment and run-ledger JSONL files.

  Required options are `:assessments`, `:run_ledgers`, `:profile_ids`, and
  `:candidate_ids`. Paths in `:registry_paths` are optional audit inputs; when
  present, their candidate set must equal `:candidate_ids`.
  """
  @spec consolidate_files!(keyword()) :: map()
  def consolidate_files!(opts) when is_list(opts) do
    config = config!(opts)
    ensure_distinct_paths!(config)

    schema_source = load_json_source!(config.schema, config.cwd)
    schema = build_schema!(schema_source)

    assessment_sources = load_jsonl_sources!(config.assessments, config.cwd)
    registry_sources = load_jsonl_sources!(config.registry_paths, config.cwd)
    verify_registry_candidates!(registry_sources, config.candidate_ids)

    assessments =
      assessment_sources
      |> located_records()
      |> validate_assessments!(schema, config)
      |> Enum.sort_by(fn row ->
        {row.record["candidate_id"], get_in(row.record, ["assessor", "profile_id"]),
         row.record["id"]}
      end)
      |> Enum.map(& &1.record)

    profile_metadata = profile_metadata!(assessments, config.profile_ids)
    ledger_sources = load_jsonl_sources!(config.run_ledgers, config.cwd)
    ledger = consolidate_ledgers!(ledger_sources)
    assessment_reference_count = verify_ledger_assessment_refs!(ledger.events, assessments)

    assessment_body = render_jsonl(assessments)
    ledger_body = render_jsonl(ledger.events)

    audit =
      audit_report(
        config,
        schema_source,
        assessment_sources,
        registry_sources,
        ledger_sources,
        assessment_body,
        ledger_body,
        assessments,
        profile_metadata,
        ledger,
        assessment_reference_count
      )

    IdentityCheckpoint.write_atomic!(config.out, assessment_body)
    IdentityCheckpoint.write_atomic!(config.runs_out, ledger_body)
    IdentityCheckpoint.write_atomic!(config.report, Jason.encode!(audit, pretty: true) <> "\n")

    audit
  end

  def consolidate_files!(opts) do
    raise ArgumentError, "consolidation options must be a keyword list, got: #{inspect(opts)}"
  end

  @doc "Alias for `consolidate_files!/1`."
  @spec consolidate!(keyword()) :: map()
  def consolidate!(opts), do: consolidate_files!(opts)

  @doc """
  Loads the distinct candidate IDs represented by candidate observations in
  one or more registry JSONL files.
  """
  @spec candidate_ids_from_registries!([Path.t()], keyword()) :: [String.t()]
  def candidate_ids_from_registries!(paths, opts \\ []) do
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()

    paths
    |> normalize_paths!(:registry_paths, cwd, required?: true)
    |> load_jsonl_sources!(cwd)
    |> registry_candidate_ids!()
  end

  defp config!(opts) do
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()

    %{
      cwd: cwd,
      assessments:
        opts
        |> path_option([:assessments, :assessment_paths])
        |> normalize_paths!(:assessments, cwd, required?: true),
      run_ledgers:
        opts
        |> path_option([:run_ledgers, :run_ledger_paths])
        |> normalize_paths!(:run_ledgers, cwd, required?: true),
      registry_paths:
        opts
        |> path_option([:registry_paths, :registries])
        |> normalize_paths!(:registry_paths, cwd),
      profile_ids: expected_ids!(Keyword.get(opts, :profile_ids), :profile_ids),
      candidate_ids: expected_ids!(Keyword.get(opts, :candidate_ids), :candidate_ids),
      schema: output_path(Keyword.get(opts, :schema, @default_schema)),
      out: output_path(Keyword.get(opts, :out, @default_out)),
      runs_out: output_path(Keyword.get(opts, :runs_out, @default_runs_out)),
      report: output_path(Keyword.get(opts, :report, @default_report))
    }
  end

  defp path_option(opts, keys) do
    Enum.flat_map(keys, fn key ->
      opts
      |> Keyword.get_values(key)
      |> Enum.flat_map(&List.wrap/1)
    end)
  end

  defp normalize_paths!(paths, label, cwd, opts \\ []) do
    normalized =
      paths
      |> Enum.map(&to_string/1)
      |> Enum.map(&Path.expand/1)

    if Keyword.get(opts, :required?, false) and normalized == [] do
      raise ArgumentError, "#{label} must contain at least one explicit path"
    end

    duplicates = duplicate_values(normalized)

    if duplicates != [] do
      raise ArgumentError,
            "#{label} contains duplicate paths: " <>
              Enum.map_join(duplicates, ", ", &relative_path(&1, cwd))
    end

    Enum.sort_by(normalized, &relative_path(&1, cwd))
  end

  defp expected_ids!(values, label) do
    ids = values |> List.wrap() |> Enum.map(&to_string/1)

    if ids == [] or Enum.any?(ids, &(String.trim(&1) == "")) do
      raise ArgumentError, "#{label} must be a non-empty list of non-empty strings"
    end

    duplicates = duplicate_values(ids)

    if duplicates != [] do
      raise ArgumentError, "#{label} contains duplicates: #{Enum.join(duplicates, ", ")}"
    end

    Enum.sort(ids)
  end

  defp output_path(path), do: path |> to_string() |> Path.expand()

  defp ensure_distinct_paths!(config) do
    inputs =
      config.assessments ++ config.run_ledgers ++ config.registry_paths ++ [config.schema]

    outputs = [config.out, config.runs_out, config.report]

    if length(Enum.uniq(outputs)) != length(outputs) do
      raise ArgumentError, "assessment, run-ledger, and audit output paths must be distinct"
    end

    overlap = inputs |> Enum.filter(&(&1 in outputs)) |> Enum.uniq()

    if overlap != [] do
      raise ArgumentError,
            "consolidation outputs overlap inputs: " <>
              Enum.map_join(overlap, ", ", &relative_path(&1, config.cwd))
    end
  end

  defp load_json_source!(path, cwd) do
    body = File.read!(path)

    data =
      case Jason.decode(body) do
        {:ok, decoded} ->
          decoded

        {:error, error} ->
          raise ArgumentError,
                "#{relative_path(path, cwd)}: invalid JSON schema: #{Exception.message(error)}"
      end

    %{
      path: relative_path(path, cwd),
      absolute_path: path,
      body: body,
      sha256: sha256(body),
      data: data
    }
  end

  defp build_schema!(source) do
    JSV.build!(source.data, formats: true)
  rescue
    error ->
      reraise ArgumentError,
              [message: "#{source.path}: invalid JSON schema: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp load_jsonl_sources!(paths, cwd) do
    Enum.map(paths, fn path ->
      body = File.read!(path)

      %{
        path: relative_path(path, cwd),
        absolute_path: path,
        body: body,
        sha256: sha256(body),
        records: parse_jsonl!(body, relative_path(path, cwd))
      }
    end)
  end

  defp parse_jsonl!(body, path) do
    lines = String.split(body, "\n", trim: false)
    final_line = length(lines)

    lines
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_number}, records ->
      cond do
        line == "" and line_number == final_line ->
          records

        String.trim(line) == "" ->
          raise ArgumentError, "#{path}:#{line_number}: blank JSONL record"

        true ->
          record = decode_jsonl_record!(line, path, line_number)
          [%{record: record, path: path, line: line_number} | records]
      end
    end)
    |> Enum.reverse()
  end

  defp decode_jsonl_record!(line, path, line_number) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) ->
        record

      {:ok, _other} ->
        raise ArgumentError, "#{path}:#{line_number}: JSONL record must be an object"

      {:error, error} ->
        raise ArgumentError,
              "#{path}:#{line_number}: invalid JSON: #{Exception.message(error)}"
    end
  end

  defp located_records(sources), do: Enum.flat_map(sources, & &1.records)

  defp validate_assessments!(rows, schema, config) do
    Enum.each(rows, &validate_schema!(&1, schema))
    identities = Enum.map(rows, &assessment_identity!/1)

    reject_unknown_values!(identities, :candidate_id, config.candidate_ids)
    reject_unknown_values!(identities, :profile_id, config.profile_ids)
    reject_duplicate_assessment_ids!(identities)
    reject_duplicate_pairs!(identities)
    require_complete_matrix!(identities, config.candidate_ids, config.profile_ids)
    require_consistent_evidence!(identities)
    require_consistent_profiles!(identities, config.profile_ids)

    rows
  end

  defp validate_schema!(row, schema) do
    case JSV.validate(row.record, schema, cast: false) do
      {:ok, _record} ->
        :ok

      {:error, error} ->
        details = error |> JSV.normalize_error(keys: :strings, sort: :asc) |> Jason.encode!()

        raise ArgumentError,
              "#{location(row)}: assessment schema validation failed: #{details}"
    end
  end

  defp assessment_identity!(row) do
    assessor = row.record["assessor"]

    unless is_map(assessor) do
      raise ArgumentError, "#{location(row)}: assessment assessor must be an object"
    end

    %{
      row: row,
      assessment_id: required_string!(row.record["id"], row, "assessment id"),
      candidate_id: required_string!(row.record["candidate_id"], row, "candidate_id"),
      profile_id: required_string!(assessor["profile_id"], row, "assessor.profile_id"),
      model: required_string!(assessor["model"], row, "assessor.model"),
      profile_digest:
        required_string!(assessor["profile_digest"], row, "assessor.profile_digest"),
      evidence_digest:
        required_string!(assessor["evidence_digest"], row, "assessor.evidence_digest")
    }
  end

  defp required_string!(value, _row, _label) when is_binary(value) and value != "", do: value

  defp required_string!(_value, row, label) do
    raise ArgumentError, "#{location(row)}: #{label} must be a non-empty string"
  end

  defp reject_unknown_values!(identities, key, expected) do
    expected = MapSet.new(expected)

    unknown =
      identities
      |> Enum.map(&Map.fetch!(&1, key))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(expected, &1))
      |> Enum.sort()

    if unknown != [] do
      raise ArgumentError, "unexpected #{key}s: #{summarize(unknown)}"
    end
  end

  defp reject_duplicate_assessment_ids!(identities) do
    case duplicate_groups(identities, & &1.assessment_id) do
      [] ->
        :ok

      [{id, rows} | _] ->
        raise ArgumentError,
              "duplicate assessment id #{inspect(id)} at #{locations(rows)}"
    end
  end

  defp reject_duplicate_pairs!(identities) do
    case duplicate_groups(identities, &{&1.candidate_id, &1.profile_id}) do
      [] ->
        :ok

      [{{candidate_id, profile_id}, rows} | _] ->
        raise ArgumentError,
              "duplicate candidate/profile pair #{candidate_id}/#{profile_id} at #{locations(rows)}"
    end
  end

  defp require_complete_matrix!(identities, candidate_ids, profile_ids) do
    actual = MapSet.new(identities, &{&1.candidate_id, &1.profile_id})

    expected =
      for candidate_id <- candidate_ids, profile_id <- profile_ids, into: MapSet.new() do
        {candidate_id, profile_id}
      end

    missing =
      expected
      |> MapSet.difference(actual)
      |> Enum.sort()
      |> Enum.map(fn {candidate_id, profile_id} -> "#{candidate_id}/#{profile_id}" end)

    if missing != [] do
      raise ArgumentError, "missing candidate/profile pairs: #{summarize(missing)}"
    end
  end

  defp require_consistent_evidence!(identities) do
    conflicts =
      identities
      |> Enum.group_by(& &1.candidate_id)
      |> Enum.flat_map(fn {candidate_id, rows} ->
        digests = rows |> Enum.map(& &1.evidence_digest) |> Enum.uniq() |> Enum.sort()
        if length(digests) == 1, do: [], else: [{candidate_id, digests}]
      end)
      |> Enum.sort()

    if conflicts != [] do
      {candidate_id, digests} = hd(conflicts)

      raise ArgumentError,
            "conflicting evidence_digest values for #{candidate_id}: #{Enum.join(digests, ", ")}"
    end
  end

  defp require_consistent_profiles!(identities, profile_ids) do
    by_profile = Enum.group_by(identities, & &1.profile_id)

    Enum.each(profile_ids, fn profile_id ->
      rows = Map.fetch!(by_profile, profile_id)
      models = rows |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.sort()
      digests = rows |> Enum.map(& &1.profile_digest) |> Enum.uniq() |> Enum.sort()

      if length(models) != 1 do
        raise ArgumentError,
              "profile #{profile_id} has multiple models: #{Enum.join(models, ", ")}"
      end

      if length(digests) != 1 do
        raise ArgumentError,
              "profile #{profile_id} has multiple profile_digest values: #{Enum.join(digests, ", ")}"
      end
    end)
  end

  defp profile_metadata!(assessments, profile_ids) do
    by_profile = Enum.group_by(assessments, &get_in(&1, ["assessor", "profile_id"]))

    Enum.map(profile_ids, fn profile_id ->
      records = Map.fetch!(by_profile, profile_id)
      assessor = records |> hd() |> Map.fetch!("assessor")

      %{
        "profile_id" => profile_id,
        "model" => assessor["model"],
        "profile_digest" => assessor["profile_digest"],
        "assessment_count" => length(records)
      }
    end)
  end

  defp verify_registry_candidates!([], _expected), do: :ok

  defp verify_registry_candidates!(sources, expected) do
    actual = registry_candidate_ids!(sources)

    if actual != expected do
      missing = expected -- actual
      unexpected = actual -- expected

      raise ArgumentError,
            "registry candidate set does not match expected candidate IDs; " <>
              "missing=#{summarize(missing)}, unexpected=#{summarize(unexpected)}"
    end
  end

  defp registry_candidate_ids!(sources) do
    sources
    |> located_records()
    |> Enum.flat_map(fn row ->
      if row.record["event_type"] == "candidate_observed" do
        [required_string!(row.record["candidate_id"], row, "candidate_id")]
      else
        []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> raise ArgumentError, "registry inputs contain no candidate observations"
      ids -> ids
    end
  end

  defp consolidate_ledgers!(sources) do
    result =
      Enum.reduce(sources, %{events: [], runs: [], completed_runs: 0}, fn source, outer ->
        source_result = consolidate_ledger_source!(source)

        %{
          events: outer.events ++ source_result.events,
          runs: outer.runs ++ source_result.runs,
          completed_runs: outer.completed_runs + source_result.completed_runs
        }
      end)

    canonical_ids = Enum.map(result.runs, & &1.canonical_run_id)

    if length(canonical_ids) != length(Enum.uniq(canonical_ids)) do
      raise ArgumentError, "canonical run ID hash collision"
    end

    source_id_frequencies = Enum.frequencies_by(result.runs, & &1.source_run_id)
    colliding = Enum.filter(source_id_frequencies, fn {_run_id, count} -> count > 1 end)
    failed_events = Enum.count(result.events, &(&1["event_type"] == @batch_failed))

    %{
      events: result.events,
      runs: result.runs,
      event_count: length(result.events),
      failure_event_count: failed_events,
      events_by_type: result.events |> Enum.frequencies_by(& &1["event_type"]) |> sort_map(),
      run_count: length(result.runs),
      completed_run_count: result.completed_runs,
      incomplete_run_count: length(result.runs) - result.completed_runs,
      source_run_id_collision_count: length(colliding),
      source_run_id_collision_run_count: Enum.sum(Enum.map(colliding, &elem(&1, 1))),
      source_run_id_collision_extra_occurrences:
        Enum.sum(Enum.map(colliding, fn {_run_id, count} -> count - 1 end)),
      run_id_remap_count: Enum.count(result.runs, &(&1.canonical_run_id != &1.source_run_id))
    }
  end

  defp verify_ledger_assessment_refs!(events, assessments) do
    references =
      events
      |> Enum.filter(&(&1["event_type"] == "identity_assessment_batch_completed"))
      |> Enum.flat_map(fn event ->
        case event["assessment_ids"] do
          ids when is_list(ids) and ids != [] ->
            if Enum.all?(ids, &is_binary/1) do
              ids
            else
              raise ArgumentError,
                    "completed assessment batch in #{event["source_ledger"]} has invalid assessment_ids"
            end

          _ ->
            raise ArgumentError,
                  "completed assessment batch in #{event["source_ledger"]} has invalid assessment_ids"
        end
      end)

    duplicates = duplicate_values(references)

    if duplicates != [] do
      raise ArgumentError,
            "assessment IDs referenced by multiple completed batches: #{summarize(duplicates)}"
    end

    expected = assessments |> Enum.map(& &1["id"]) |> MapSet.new()
    actual = MapSet.new(references)
    missing = expected |> MapSet.difference(actual) |> Enum.sort()
    unknown = actual |> MapSet.difference(expected) |> Enum.sort()

    if missing != [] or unknown != [] do
      raise ArgumentError,
            "assessment/run-ledger provenance mismatch; " <>
              "missing=#{summarize(missing)}, unknown=#{summarize(unknown)}"
    end

    length(references)
  end

  defp consolidate_ledger_source!(source) do
    initial = %{
      active: %{},
      occurrence_counts: %{},
      events: [],
      runs: [],
      completed_runs: 0
    }

    state = Enum.reduce(source.records, initial, &consolidate_ledger_event!(&1, &2, source.path))

    %{
      events: Enum.reverse(state.events),
      runs: Enum.reverse(state.runs),
      completed_runs: state.completed_runs
    }
  end

  defp consolidate_ledger_event!(row, state, source_ledger) do
    event = row.record
    event_type = required_string!(event["event_type"], row, "event_type")
    source_run_id = required_string!(event["run_id"], row, "run_id")

    present_provenance = Enum.filter(@provenance_keys, &Map.has_key?(event, &1))

    if present_provenance != [] do
      raise ArgumentError,
            "#{location(row)}: source ledger event already contains consolidation provenance: " <>
              Enum.join(present_provenance, ", ")
    end

    case event_type do
      @run_started -> start_run!(row, state, source_ledger, source_run_id)
      @run_completed -> complete_run!(row, state, source_ledger, source_run_id)
      _event_type -> append_run_event!(row, state, source_ledger, source_run_id)
    end
  end

  defp start_run!(row, state, source_ledger, source_run_id) do
    if Map.has_key?(state.active, source_run_id) do
      active = Map.fetch!(state.active, source_run_id)

      raise ArgumentError,
            "#{location(row)}: run #{source_run_id} starts before occurrence " <>
              "#{active.occurrence} is completed"
    end

    occurrence = Map.get(state.occurrence_counts, source_run_id, 0) + 1
    canonical_run_id = canonical_run_id(source_ledger, source_run_id, occurrence)

    run = %{
      source_ledger: source_ledger,
      source_run_id: source_run_id,
      occurrence: occurrence,
      canonical_run_id: canonical_run_id
    }

    %{
      state
      | active: Map.put(state.active, source_run_id, run),
        occurrence_counts: Map.put(state.occurrence_counts, source_run_id, occurrence),
        events: [canonical_event(row.record, run) | state.events],
        runs: [run | state.runs]
    }
  end

  defp complete_run!(row, state, _source_ledger, source_run_id) do
    run = active_run!(state, row, source_run_id)

    %{
      state
      | active: Map.delete(state.active, source_run_id),
        events: [canonical_event(row.record, run) | state.events],
        completed_runs: state.completed_runs + 1
    }
  end

  defp append_run_event!(row, state, _source_ledger, source_run_id) do
    run = active_run!(state, row, source_run_id)
    %{state | events: [canonical_event(row.record, run) | state.events]}
  end

  defp active_run!(state, row, source_run_id) do
    case Map.fetch(state.active, source_run_id) do
      {:ok, run} ->
        run

      :error ->
        raise ArgumentError,
              "#{location(row)}: orphaned ledger event for run #{source_run_id}; " <>
                "no active run-start event"
    end
  end

  defp canonical_event(event, run) do
    event
    |> Map.put("run_id", run.canonical_run_id)
    |> Map.put("source_ledger", run.source_ledger)
    |> Map.put("source_run_id", run.source_run_id)
    |> Map.put("source_run_occurrence", run.occurrence)
  end

  defp canonical_run_id(source_ledger, source_run_id, occurrence) do
    digest = Jason.encode!([source_ledger, source_run_id, occurrence]) |> sha256()
    "identity-assessment-run-" <> digest
  end

  defp audit_report(
         config,
         schema_source,
         assessment_sources,
         registry_sources,
         ledger_sources,
         assessment_body,
         ledger_body,
         assessments,
         profile_metadata,
         ledger,
         assessment_reference_count
       ) do
    %{
      "schema_version" => 1,
      "kind" => "identity_assessment_consolidation_audit",
      "inputs" => %{
        "assessment_sources" => source_reports(assessment_sources, "record_count"),
        "run_ledger_sources" => source_reports(ledger_sources, "event_count"),
        "registry_sources" => source_reports(registry_sources, "record_count"),
        "schema" => %{"path" => schema_source.path, "sha256" => schema_source.sha256},
        "expected_candidate_count" => length(config.candidate_ids),
        "expected_profile_ids" => config.profile_ids,
        "expected_pair_count" => length(config.candidate_ids) * length(config.profile_ids)
      },
      "outputs" => %{
        "assessments" => %{
          "path" => relative_path(config.out, config.cwd),
          "sha256" => sha256(assessment_body),
          "record_count" => length(assessments)
        },
        "run_ledger" => %{
          "path" => relative_path(config.runs_out, config.cwd),
          "sha256" => sha256(ledger_body),
          "event_count" => ledger.event_count,
          "failure_event_count" => ledger.failure_event_count
        }
      },
      "profiles" => profile_metadata,
      "validation" => %{
        "schema_errors" => 0,
        "duplicate_assessment_ids" => 0,
        "duplicate_candidate_profile_pairs" => 0,
        "missing_candidate_profile_pairs" => 0,
        "unexpected_candidate_ids" => 0,
        "unexpected_profile_ids" => 0,
        "evidence_digest_conflicts" => 0,
        "profile_model_conflicts" => 0,
        "profile_digest_conflicts" => 0,
        "ledger_sequence_errors" => 0,
        "assessment_ledger_reference_errors" => 0
      },
      "ledger" => %{
        "event_count" => ledger.event_count,
        "assessment_reference_count" => assessment_reference_count,
        "failure_event_count" => ledger.failure_event_count,
        "events_by_type" => ledger.events_by_type,
        "run_count" => ledger.run_count,
        "completed_run_count" => ledger.completed_run_count,
        "incomplete_run_count" => ledger.incomplete_run_count,
        "source_run_id_collision_count" => ledger.source_run_id_collision_count,
        "source_run_id_collision_run_count" => ledger.source_run_id_collision_run_count,
        "source_run_id_collision_extra_occurrences" =>
          ledger.source_run_id_collision_extra_occurrences,
        "run_id_remap_count" => ledger.run_id_remap_count
      }
    }
  end

  defp source_reports(sources, count_key) do
    Enum.map(sources, fn source ->
      %{
        "path" => source.path,
        "sha256" => source.sha256,
        count_key => length(source.records)
      }
    end)
  end

  defp render_jsonl([]), do: ""

  defp render_jsonl(records) do
    Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
  end

  defp duplicate_groups(values, mapper) do
    values
    |> Enum.group_by(mapper)
    |> Enum.filter(fn {_value, rows} -> length(rows) > 1 end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp locations(rows), do: Enum.map_join(rows, ", ", &location(&1.row))
  defp location(row), do: "#{row.path}:#{row.line}"

  defp summarize(values, limit \\ 12)
  defp summarize([], _limit), do: "none"

  defp summarize(values, limit) do
    shown = Enum.take(values, limit)
    suffix = if length(values) > limit, do: " (+#{length(values) - limit} more)", else: ""
    Enum.join(shown, ", ") <> suffix
  end

  defp sort_map(map), do: map |> Enum.sort_by(&elem(&1, 0)) |> Map.new()

  defp relative_path(path, cwd) do
    path
    |> Path.expand()
    |> Path.relative_to(cwd)
  end

  defp sha256(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end
end

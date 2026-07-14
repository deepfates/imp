defmodule Imp.IdentityProgress do
  @moduledoc false

  alias Imp.{IdentityCheckpoint, IdentityCollision}
  alias Imp.IdentityProgress.Artifacts
  alias Imp.IdentityProgress.Git

  @defaults %{
    atlas: "identity/atlas.json",
    workflow: "identity/workflow.json",
    inbox: "identity/inbox/*.json",
    registry: "identity/registry.jsonl",
    enrichments: "identity/enrichments.jsonl",
    assessments: "identity/assessments.jsonl",
    collision_checks: "identity/research/package-collision-checks.jsonl",
    flags: "identity/flags.jsonl",
    dissent: "identity/dissent.jsonl"
  }
  @max_errors 20

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()
    paths = resolve_paths(root, opts)
    atlas = IdentityCheckpoint.load_atlas!(paths.atlas)
    workflow = load_workflow!(paths.workflow, root)
    expected = expected_portfolios(workflow, root)

    acceptance = acceptance_snapshot(paths.inbox, root, opts)

    inspections =
      inspect_portfolios(
        atlas,
        expected,
        Path.wildcard(paths.inbox) |> Enum.map(&Path.expand/1),
        acceptance,
        root
      )
      |> invalidate_duplicate_runs()

    accepted = Enum.filter(inspections, &(&1.state == "accepted"))
    pending = Enum.filter(inspections, &(&1.state == "valid_pending"))
    unplanned = Enum.filter(inspections, &(&1.state == "unplanned"))
    observable = accepted ++ pending
    accepted_ids = candidate_ids(accepted)
    accepted_compile = compile_group(atlas, accepted, root)
    observable_compile = compile_group(atlas, observable, root)
    target_raw = workflow_target(workflow)
    accepted_stats = corpus_stats(accepted)

    pending_stats =
      pending
      |> corpus_stats()
      |> Map.put(
        "net_new_distinct_candidates",
        pending |> candidate_ids() |> MapSet.difference(accepted_ids) |> MapSet.size()
      )

    observable_stats = corpus_stats(observable)

    %{
      "schema_version" => 1,
      "generated_at" => generated_at(opts),
      "checkpoint_id" => workflow["checkpoint_id"],
      "selection_made" => workflow["selection_made"],
      "acceptance_rule" =>
        "A portfolio is accepted only when it is declared in the workflow, has its exact planned count, is schema-valid, Git-tracked, and unchanged from HEAD.",
      "frontier" => %{
        "target_raw_occurrences" => target_raw,
        "accepted" => accepted_stats,
        "valid_pending" => pending_stats,
        "observable_valid" => observable_stats,
        "remaining_to_accept" => max(target_raw - accepted_stats["raw_occurrences"], 0),
        "remaining_to_generate" => max(target_raw - observable_stats["raw_occurrences"], 0),
        "accepted_fraction" => fraction(accepted_stats["raw_occurrences"], target_raw),
        "observable_valid_fraction" => fraction(observable_stats["raw_occurrences"], target_raw)
      },
      "portfolio_states" => state_counts(inspections),
      "waves" => wave_reports(workflow, inspections),
      "pipeline" =>
        pipeline_report(paths, accepted_compile.events, accepted_ids, atlas, workflow),
      "integrity" => %{
        "workflow_alignment_valid" => unplanned == [],
        "workflow_alignment_errors" => workflow_alignment_errors(unplanned),
        "accepted_corpus_valid" => accepted_compile.errors == [],
        "accepted_errors" => accepted_compile.errors,
        "observable_frontier_valid" => observable_compile.errors == [],
        "observable_frontier_errors" => observable_compile.errors
      },
      "portfolios" => Enum.map(inspections, &public_inspection/1)
    }
  end

  @spec git_accepted_paths!(String.t(), keyword()) :: [String.t()]
  def git_accepted_paths!(inbox_glob, opts \\ []) do
    inbox_glob
    |> git_accepted_revisions!(opts)
    |> Enum.flat_map(&accepted_path/1)
  end

  @spec git_accepted_revisions!(String.t(), keyword()) :: %{String.t() => String.t()}
  def git_accepted_revisions!(inbox_glob, opts \\ []) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()
    Git.accepted_revisions!(inbox_glob, root)
  end

  @spec render_text(map()) :: String.t()
  def render_text(report) do
    frontier = report["frontier"]
    pipeline = report["pipeline"]

    lines = [
      "Identity census progress",
      "Acceptance: workflow-declared, exact planned count, schema-valid, Git-tracked, unchanged from HEAD",
      "",
      "Frontier",
      stats_line("accepted", frontier["accepted"]),
      stats_line(
        "valid pending",
        frontier["valid_pending"],
        frontier["valid_pending"]["net_new_distinct_candidates"]
      ),
      stats_line("observable valid", frontier["observable_valid"]),
      "target: #{frontier["target_raw_occurrences"]} raw | " <>
        "#{frontier["remaining_to_accept"]} remain to accept | " <>
        "#{frontier["remaining_to_generate"]} remain to generate",
      "",
      "Waves"
    ]

    wave_lines =
      Enum.map(report["waves"], fn wave ->
        "#{wave["id"]}: #{wave["state"]} | " <>
          "accepted #{wave["accepted_raw_occurrences"]}/#{wave["target_raw_occurrences"]} | " <>
          "pending #{wave["valid_pending_raw_occurrences"]} | " <>
          "ungenerated #{wave["remaining_to_generate"]}"
      end)

    pipeline_lines = [
      "",
      "Pipeline",
      coverage_line("registry events", pipeline["registry"]),
      coverage_line("enriched candidates", pipeline["enrichments"]),
      coverage_line("spoken forms", pipeline["spoken_forms"]),
      coverage_line("code forms", pipeline["code_forms"]),
      coverage_line("architecture forms", pipeline["architecture_forms"]),
      international_evidence_line(pipeline["international_review"]),
      coverage_line("fully assessed candidates", pipeline["assessments"]),
      coverage_line("collision checks", pipeline["collision_checks"])
    ]

    attention =
      report["portfolios"]
      |> Enum.reject(&(&1["state"] in ["accepted", "valid_pending"]))
      |> Enum.map(fn portfolio ->
        detail =
          case portfolio["errors"] do
            [first | _rest] -> "; #{first}"
            _errors -> ""
          end

        "#{portfolio["path"]}: #{portfolio["state"]} " <>
          "(target #{portfolio["target_candidate_count"] || "unplanned"}#{detail})"
      end)

    attention_lines = if attention == [], do: [], else: ["", "Attention" | attention]

    integrity_errors =
      (report["integrity"] || %{})
      |> Map.take([
        "workflow_alignment_errors",
        "accepted_errors",
        "observable_frontier_errors"
      ])
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    integrity_lines =
      if integrity_errors == [], do: [], else: ["", "Integrity" | integrity_errors]

    (lines ++ wave_lines ++ pipeline_lines ++ attention_lines ++ integrity_lines)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp resolve_paths(root, opts) do
    Map.new(@defaults, fn {key, default} ->
      {key, Path.expand(Keyword.get(opts, key, default), root)}
    end)
  end

  defp load_workflow!(path, root) do
    workflow = path |> File.read!() |> Jason.decode!()
    errors = workflow_errors(workflow, root)

    if errors == [] do
      workflow
    else
      raise ArgumentError,
            "invalid identity workflow #{path}:\n" <> Enum.map_join(errors, "\n", &"- #{&1}")
    end
  end

  defp workflow_errors(workflow, root) when is_map(workflow) do
    waves = workflow["waves"]
    replicates = workflow["required_assessment_replicates"]
    sources = workflow["collision_sources"]

    errors =
      []
      |> maybe_error(workflow["schema_version"] != 1, "schema_version must be 1")
      |> maybe_error(not is_binary(workflow["checkpoint_id"]), "checkpoint_id must be a string")
      |> maybe_error(not is_boolean(workflow["selection_made"]), "selection_made must be boolean")
      |> maybe_error(
        not is_integer(replicates) or replicates < 1,
        "required_assessment_replicates must be positive"
      )
      |> maybe_error(not is_list(sources) or sources == [], "collision_sources must be non-empty")
      |> maybe_error(
        is_list(sources) and
          (Enum.any?(sources, &(not is_binary(&1))) or
             length(Enum.uniq(sources)) != length(sources)),
        "collision_sources must contain unique strings"
      )
      |> maybe_error(
        is_list(sources) and
          Enum.any?(sources, &(&1 not in IdentityCollision.source_ids())),
        "collision_sources contain unsupported source ids"
      )
      |> maybe_error(not is_list(waves) or waves == [], "waves must be a non-empty array")

    if is_list(waves), do: errors ++ wave_errors(waves, root), else: errors
  end

  defp workflow_errors(_workflow, _root), do: ["workflow must be a JSON object"]

  defp wave_errors(waves, root) do
    wave_ids = waves |> Enum.filter(&is_map/1) |> Enum.map(& &1["id"])

    portfolio_paths =
      waves
      |> Enum.flat_map(&wave_portfolios/1)
      |> Enum.filter(&is_map/1)
      |> Enum.map(& &1["path"])

    duplicate_wave_ids = wave_ids |> Enum.filter(&is_binary/1) |> duplicate_values()

    duplicate_paths =
      portfolio_paths
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand(&1, root))
      |> duplicate_values()

    []
    |> maybe_error(
      Enum.any?(waves, &(not valid_wave?(&1))),
      "every wave must have an id, label, and portfolios"
    )
    |> maybe_error(
      duplicate_wave_ids != [],
      "wave ids must be unique: #{Enum.join(duplicate_wave_ids, ", ")}"
    )
    |> maybe_error(
      duplicate_paths != [],
      "portfolio paths must be unique: #{Enum.join(duplicate_paths, ", ")}"
    )
    |> maybe_error(
      Enum.any?(waves, fn wave ->
        Enum.any?(wave_portfolios(wave), &(not valid_planned_portfolio?(&1)))
      end),
      "every planned portfolio needs a path, positive target, and valid missing_state"
    )
  end

  defp wave_portfolios(wave) when is_map(wave) do
    case wave["portfolios"] do
      portfolios when is_list(portfolios) -> portfolios
      _other -> []
    end
  end

  defp wave_portfolios(_wave), do: []

  defp valid_wave?(wave),
    do:
      is_map(wave) and is_binary(wave["id"]) and is_binary(wave["label"]) and
        is_list(wave["portfolios"]) and wave["portfolios"] != []

  defp valid_planned_portfolio?(portfolio) do
    is_map(portfolio) and nonempty?(portfolio["path"]) and
      is_integer(portfolio["target_candidate_count"]) and
      portfolio["target_candidate_count"] > 0 and
      Map.get(portfolio, "missing_state", "planned") in ["planned", "assigned"]
  end

  defp expected_portfolios(workflow, root) do
    Enum.flat_map(workflow["waves"], fn wave ->
      Enum.map(wave["portfolios"], fn portfolio ->
        %{
          path: Path.expand(portfolio["path"], root),
          wave: wave["id"],
          target: portfolio["target_candidate_count"],
          missing_state: Map.get(portfolio, "missing_state", "planned")
        }
      end)
    end)
  end

  defp inspect_portfolios(atlas, expected, discovered_paths, acceptance, root) do
    expected_by_path = Map.new(expected, &{&1.path, &1})

    (Enum.map(expected, & &1.path) ++ discovered_paths)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path ->
      plan = Map.get(expected_by_path, path, %{wave: nil, target: nil, missing_state: "planned"})
      inspect_portfolio(atlas, path, plan, acceptance, root)
    end)
  end

  defp invalidate_duplicate_runs(inspections) do
    duplicate_run_ids =
      inspections
      |> Enum.filter(& &1.entry)
      |> Enum.group_by(& &1.run_id)
      |> Enum.flat_map(fn
        {run_id, members} when is_binary(run_id) and length(members) > 1 -> [run_id]
        _group -> []
      end)
      |> MapSet.new()

    Enum.map(inspections, &invalidate_duplicate_run(&1, duplicate_run_ids))
  end

  defp invalidate_duplicate_run(inspection, duplicate_run_ids) do
    if MapSet.member?(duplicate_run_ids, inspection.run_id) do
      state = if inspection.accepted_source?, do: "accepted_invalid", else: "needs_attention"

      %{
        inspection
        | state: state,
          entry: nil,
          errors: inspection.errors ++ ["duplicate run id #{inspect(inspection.run_id)}"]
      }
    else
      inspection
    end
  end

  defp inspect_portfolio(atlas, path, plan, acceptance, root) do
    accepted_digest = Map.get(acceptance.accepted_revisions, path)
    accepted_source? = not is_nil(accepted_digest)
    head_tracked? = MapSet.member?(acceptance.tracked_paths, path)
    base = inspection_base(path, plan, root, accepted_source?, head_tracked?)

    case File.read(path) do
      {:error, :enoent} ->
        missing_inspection(base, plan, head_tracked?)

      {:error, reason} ->
        %{base | state: invalid_state(accepted_source?, "in_progress"), errors: [inspect(reason)]}

      {:ok, body} ->
        inspect_portfolio_body(atlas, base, body, accepted_digest)
    end
  end

  defp inspect_portfolio_body(atlas, base, body, accepted_digest) do
    digest = sha256(body)
    accepted_source? = accepted_digest == :trusted or accepted_digest == digest
    base = %{base | accepted_source?: accepted_source?}

    case Jason.decode(body) do
      {:ok, data} when is_map(data) ->
        entry = %{path: base.path, sha256: digest, data: data}
        candidate_count = data |> Map.get("candidates", []) |> list_length()
        run_id = nested_value(data, "run", "id")
        wave = base.wave || "unplanned"
        claimed_wave = challenge_wave(data)

        case safe_compile(atlas, [entry]) do
          {:ok, _compiled} ->
            complete_valid_inspection(
              base,
              entry,
              digest,
              run_id,
              candidate_count,
              wave,
              claimed_wave,
              accepted_source?
            )

          {:error, errors} ->
            %{
              base
              | state: invalid_state(accepted_source?, "needs_attention"),
                sha256: digest,
                run_id: run_id,
                candidate_count: candidate_count,
                wave: wave,
                claimed_wave: claimed_wave,
                errors: Enum.take(errors, @max_errors)
            }
        end

      {:ok, _other} ->
        %{
          base
          | state: invalid_state(accepted_source?, "needs_attention"),
            sha256: digest,
            errors: ["portfolio must be a JSON object"]
        }

      {:error, error} ->
        %{
          base
          | state: invalid_state(accepted_source?, "in_progress"),
            sha256: digest,
            errors: [Exception.message(error)]
        }
    end
  end

  defp inspection_base(path, plan, root, accepted_source?, head_tracked?) do
    %{
      path: path,
      display_path: Path.relative_to(path, root),
      wave: plan.wave,
      target: plan.target,
      state: plan.missing_state,
      accepted_source?: accepted_source?,
      head_tracked?: head_tracked?,
      sha256: nil,
      run_id: nil,
      candidate_count: 0,
      claimed_wave: nil,
      errors: [],
      entry: nil
    }
  end

  defp missing_inspection(base, _plan, true) do
    %{
      base
      | state: "deleted",
        errors: ["portfolio is tracked in the pinned HEAD revision but missing from the worktree"]
    }
  end

  defp missing_inspection(base, plan, false), do: %{base | state: plan.missing_state}

  defp invalid_state(true, _pending_state), do: "accepted_invalid"
  defp invalid_state(false, pending_state), do: pending_state

  defp complete_valid_inspection(
         base,
         entry,
         digest,
         run_id,
         candidate_count,
         wave,
         claimed_wave,
         accepted_source?
       ) do
    count_matches? = is_nil(base.target) or candidate_count == base.target
    planned? = not is_nil(base.wave)

    %{
      base
      | state: admission_state(planned?, count_matches?, accepted_source?),
        entry: if(planned? and count_matches?, do: entry, else: nil),
        sha256: digest,
        run_id: run_id,
        candidate_count: candidate_count,
        wave: wave,
        claimed_wave: claimed_wave,
        errors: admission_errors(planned?, count_matches?, candidate_count, base.target)
    }
  end

  defp admission_state(false, _count_matches?, _accepted_source?), do: "unplanned"
  defp admission_state(true, false, true), do: "accepted_invalid"
  defp admission_state(true, false, false), do: "needs_attention"
  defp admission_state(true, true, true), do: "accepted"
  defp admission_state(true, true, false), do: "valid_pending"

  defp admission_errors(false, _count_matches?, _candidate_count, _target),
    do: ["portfolio is not declared in identity/workflow.json"]

  defp admission_errors(true, true, _candidate_count, _target), do: []

  defp admission_errors(true, false, candidate_count, target),
    do: ["candidate count #{candidate_count} does not match planned target #{target}"]

  defp challenge_wave(data) do
    data
    |> nested_value("run", "notes")
    |> List.wrap()
    |> Enum.find_value(fn
      "challenge_wave:" <> wave -> String.trim(wave)
      _note -> nil
    end)
  end

  defp corpus_stats(inspections) do
    candidates = candidate_rows(inspections)
    raw = length(candidates)
    distinct = candidates |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.size()
    wildcards = Enum.count(candidates, & &1.wildcard)

    %{
      "runs" => Enum.count(inspections, & &1.entry),
      "raw_occurrences" => raw,
      "distinct_normalized_candidates" => distinct,
      "duplicate_occurrences" => raw - distinct,
      "wildcard_occurrences" => wildcards,
      "wildcard_fraction" => fraction(wildcards, raw)
    }
  end

  defp candidate_rows(inspections) do
    Enum.flat_map(inspections, fn
      %{entry: %{data: %{"candidates" => candidates}}} ->
        Enum.map(candidates, fn candidate ->
          %{
            id: IdentityCheckpoint.candidate_id(candidate["surface"]),
            wildcard: candidate["wildcard"] == true
          }
        end)

      _inspection ->
        []
    end)
  end

  defp candidate_ids(inspections),
    do: inspections |> candidate_rows() |> Enum.map(& &1.id) |> MapSet.new()

  defp compile_group(_atlas, [], _root), do: %{events: [], errors: []}

  defp compile_group(atlas, inspections, root) do
    entries =
      Enum.map(inspections, fn inspection ->
        Map.update!(inspection.entry, :path, &Path.relative_to(&1, root))
      end)

    case safe_compile(atlas, entries) do
      {:ok, %{events: events}} -> %{events: events, errors: []}
      {:error, errors} -> %{events: [], errors: Enum.take(errors, @max_errors)}
    end
  end

  defp wave_reports(workflow, inspections) do
    Enum.map(workflow["waves"], fn wave ->
      members = Enum.filter(inspections, &(&1.wave == wave["id"]))
      accepted = Enum.filter(members, &(&1.state == "accepted"))
      pending = Enum.filter(members, &(&1.state == "valid_pending"))
      target = wave["portfolios"] |> Enum.map(& &1["target_candidate_count"]) |> Enum.sum()
      accepted_raw = raw_count(accepted)
      pending_raw = raw_count(pending)

      %{
        "id" => wave["id"],
        "label" => wave["label"],
        "state" => wave_state(members),
        "portfolio_states" => state_counts(members),
        "target_raw_occurrences" => target,
        "accepted_raw_occurrences" => accepted_raw,
        "valid_pending_raw_occurrences" => pending_raw,
        "remaining_to_accept" => max(target - accepted_raw, 0),
        "remaining_to_generate" => max(target - accepted_raw - pending_raw, 0)
      }
    end)
  end

  defp wave_state(members) do
    states = Enum.map(members, & &1.state)

    cond do
      states == [] ->
        "needs_attention"

      Enum.any?(states, &(&1 in ["accepted_invalid", "needs_attention", "deleted"])) ->
        "needs_attention"

      Enum.all?(states, &(&1 == "accepted")) ->
        "accepted"

      Enum.all?(states, &(&1 in ["accepted", "valid_pending"])) ->
        "valid_pending"

      Enum.any?(states, &(&1 in ["assigned", "in_progress", "valid_pending"])) ->
        "in_progress"

      true ->
        "planned"
    end
  end

  defp pipeline_report(paths, accepted_events, accepted_ids, atlas, workflow) do
    Artifacts.pipeline_report(paths, accepted_events, accepted_ids, atlas, workflow)
  end

  defp public_inspection(inspection) do
    %{
      "path" => inspection.display_path,
      "wave" => inspection.wave,
      "state" => inspection.state,
      "accepted_source" => inspection.accepted_source?,
      "tracked_in_head" => inspection.head_tracked?,
      "target_candidate_count" => inspection.target,
      "candidate_count" => inspection.candidate_count,
      "run_id" => inspection.run_id,
      "claimed_wave" => inspection.claimed_wave,
      "sha256" => inspection.sha256,
      "error_count" => length(inspection.errors),
      "errors" => inspection.errors
    }
  end

  defp state_counts(inspections), do: inspections |> Enum.map(& &1.state) |> Enum.frequencies()
  defp raw_count(inspections), do: inspections |> candidate_rows() |> length()

  defp workflow_alignment_errors(inspections) do
    Enum.map(inspections, fn inspection ->
      claimed = if inspection.claimed_wave, do: " (claims #{inspection.claimed_wave})", else: ""
      "#{inspection.display_path} is not declared#{claimed}"
    end)
  end

  defp workflow_target(workflow) do
    workflow["waves"]
    |> Enum.flat_map(& &1["portfolios"])
    |> Enum.map(& &1["target_candidate_count"])
    |> Enum.sum()
  end

  defp acceptance_snapshot(inbox_glob, root, opts) do
    if Keyword.has_key?(opts, :accepted_paths) do
      accepted =
        opts
        |> Keyword.fetch!(:accepted_paths)
        |> Enum.map(&{Path.expand(&1, root), :trusted})
        |> Map.new()

      %{
        revision: "test-override",
        tracked_paths: accepted |> Map.keys() |> MapSet.new(),
        accepted_revisions: accepted
      }
    else
      Git.snapshot!(inbox_glob, root)
    end
  end

  defp accepted_path({path, expected_digest}) do
    case File.read(path) do
      {:ok, body} -> if(sha256(body) == expected_digest, do: [path], else: [])
      _other -> []
    end
  end

  defp generated_at(opts) do
    Keyword.get_lazy(opts, :generated_at, fn ->
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end)
  end

  defp fraction(_numerator, 0), do: 0.0
  defp fraction(numerator, denominator), do: numerator / denominator
  defp list_length(value) when is_list(value), do: length(value)
  defp list_length(_value), do: 0
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp nested_value(map, outer, inner) do
    case Map.get(map, outer) do
      nested when is_map(nested) -> Map.get(nested, inner)
      _other -> nil
    end
  end

  defp safe_compile(atlas, portfolios) do
    IdentityCheckpoint.compile(atlas, portfolios)
  rescue
    error -> {:error, ["portfolio validation crashed safely: #{Exception.message(error)}"]}
  catch
    kind, reason -> {:error, ["portfolio validation crashed safely: #{inspect({kind, reason})}"]}
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp stats_line(label, stats, net_new \\ nil) do
    suffix = if is_integer(net_new), do: " | #{net_new} net-new distinct", else: ""

    "#{label}: #{stats["raw_occurrences"]} raw | " <>
      "#{stats["distinct_normalized_candidates"]} distinct | " <>
      "#{stats["duplicate_occurrences"]} duplicate occurrences | " <>
      "#{stats["wildcard_occurrences"]} wildcards#{suffix}"
  end

  defp coverage_line(label, coverage) do
    "#{label}: #{coverage["completed"]}/#{coverage["target"]} (#{coverage["state"]})"
  end

  defp international_evidence_line(coverage) do
    "international evidence: #{coverage["completed"]}/#{coverage["target"]} screened " <>
      "(#{coverage["state"]}) | attention #{coverage["attention_candidates"] || 0} | " <>
      "unverified #{coverage["unverified_candidates"] || 0} | " <>
      "human-validated #{coverage["human_validated_candidates"] || 0}"
  end
end

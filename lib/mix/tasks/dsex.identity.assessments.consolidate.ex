defmodule Mix.Tasks.Dsex.Identity.Assessments.Consolidate do
  @moduledoc """
  Validate and consolidate explicit identity assessment shards.

      mix dsex.identity.assessments.consolidate \
        --assessment identity/research/assessments.flash.jsonl \
        --assessment 'identity/research/assessments.terra*.jsonl' \
        --run-ledger identity/research/assessment-runs.flash.jsonl \
        --run-ledger 'identity/research/assessment-runs.terra*.jsonl' \
        --profile flash --profile terra

  Assessment, run-ledger, and profile options are required and repeatable.
  Globs are expanded only when explicitly supplied. Registry, schema, and
  output paths have repository-local defaults.
  """

  use Mix.Task

  alias DSEx.IdentityAssessmentConsolidation

  @shortdoc "Consolidate validated identity assessment shards"

  @switches [
    assessment: :keep,
    run_ledger: :keep,
    profile: :keep,
    registry: :keep,
    schema: :string,
    out: :string,
    runs_out: :string,
    report: :string
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    if argv != [], do: Mix.raise("unexpected arguments: #{Enum.join(argv, " ")}")

    assessment_paths = required_explicit_paths!(opts, :assessment)
    run_ledger_paths = required_explicit_paths!(opts, :run_ledger)
    profile_ids = required_values!(opts, :profile)

    registry_paths =
      case Keyword.get_values(opts, :registry) do
        [] -> ["identity/registry.jsonl"]
        paths -> expand_paths!(paths)
      end

    candidate_ids =
      IdentityAssessmentConsolidation.candidate_ids_from_registries!(registry_paths)

    Mix.Task.run("app.start")

    audit =
      IdentityAssessmentConsolidation.consolidate_files!(
        assessments: assessment_paths,
        run_ledgers: run_ledger_paths,
        registry_paths: registry_paths,
        profile_ids: profile_ids,
        candidate_ids: candidate_ids,
        schema: Keyword.get(opts, :schema, "identity/schema/assessment.schema.json"),
        out: Keyword.get(opts, :out, "identity/assessments.jsonl"),
        runs_out: Keyword.get(opts, :runs_out, "identity/assessment-runs.jsonl"),
        report: Keyword.get(opts, :report, "identity/reports/assessment-audit.json")
      )

    print_summary(audit)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp required_explicit_paths!(opts, key) do
    case Keyword.get_values(opts, key) do
      [] -> Mix.raise("provide at least one --#{option_name(key)} path")
      paths -> expand_paths!(paths)
    end
  end

  defp required_values!(opts, key) do
    values =
      opts
      |> Keyword.get_values(key)
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      values == [] ->
        Mix.raise("provide at least one --#{option_name(key)} value")

      length(values) != length(Enum.uniq(values)) ->
        Mix.raise("duplicate --#{option_name(key)} values are not allowed")

      true ->
        Enum.sort(values)
    end
  end

  defp expand_paths!(specs) do
    specs
    |> Enum.flat_map(fn spec ->
      if wildcard?(spec) do
        case Path.wildcard(spec) |> Enum.sort() do
          [] -> Mix.raise("path glob matched no files: #{spec}")
          matches -> matches
        end
      else
        [spec]
      end
    end)
    |> reject_duplicate_paths!()
  end

  defp reject_duplicate_paths!(paths) do
    expanded = Enum.map(paths, &Path.expand/1)

    if length(expanded) != length(Enum.uniq(expanded)) do
      Mix.raise("explicit paths and globs resolve to duplicate files")
    end

    paths
  end

  defp wildcard?(path), do: String.contains?(path, ["*", "?", "[", "{"])
  defp option_name(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp print_summary(audit) do
    assessments = get_in(audit, ["outputs", "assessments"])
    ledger = audit["ledger"]

    Mix.shell().info(
      "identity assessments: #{assessments["record_count"]} canonical records across " <>
        "#{length(audit["profiles"])} profiles"
    )

    Mix.shell().info(
      "assessment runs: #{ledger["run_count"]} runs, #{ledger["event_count"]} events, " <>
        "#{ledger["failure_event_count"]} failures, #{ledger["incomplete_run_count"]} incomplete"
    )

    Mix.shell().info(
      "run IDs: #{ledger["run_id_remap_count"]} remapped, " <>
        "#{ledger["source_run_id_collision_count"]} source collisions"
    )
  end
end

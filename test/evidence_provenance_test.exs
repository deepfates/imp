defmodule EvidenceProvenanceTest do
  use ExUnit.Case, async: false

  # Per-PR provenance gates for the admitted evidence store (dee-zobd wave 2).
  # Venv-free: everything here reads committed files and the local git store.
  # Requires full history plus a fetched origin/main ref (CI: fetch-depth: 0).
  @moduletag :evidence_infrastructure

  @admitted_glob "benchmarks/evidence/admitted/*/*.json"
  @citing_ledgers [
    "benchmarks/reproductions.json",
    "benchmarks/claims.json",
    "benchmarks/authorities.json"
  ]

  # The one admitted artifact captured without a git_sha (multimodal live
  # campaign, pre-provenance-discipline). Annotated per dee-sc3q: the exemption
  # asserts the artifact still lacks the field, so the moment it is re-captured
  # with provenance this entry MUST be deleted.
  @missing_git_sha_exemptions %{
    "benchmarks/evidence/admitted/multimodal_live/02d3c35797723e6ce4a7c544a3f602579771430276d6838beb14bcfe091e391e.json" =>
      "historical multimodal live campaign captured before git provenance was required (dee-sc3q); re-capture must record git_sha"
  }

  # Admitted artifacts whose recorded provenance checkpoints live under
  # gitignored/uncommitted paths (dee-sc3q). Grandfathered with reasons; the
  # gate bites for every new admission. Each entry is re-verified below so it
  # dies when the artifact is retired or the paths become committed.
  @uncommitted_provenance_grandfathers %{
    "benchmarks/evidence/admitted/multimodal_live/02d3c35797723e6ce4a7c544a3f602579771430276d6838beb14bcfe091e391e.json" =>
      "checkpoint under benchmarks/results/multimodal-checkpoints/ is gitignored; a re-capture must commit its checkpoint or record a committed content address",
    "benchmarks/evidence/admitted/optimize_anything/080f41578d725c8841d7484f6953cba419626b36f08043408c1027622ede4653.json" =>
      "historical dsex-era replication; run directory benchmarks/results/optimize-anything-runs/ was never committed (dee-1t1w)",
    "benchmarks/evidence/admitted/optimize_anything/58ff84ac7a0d95bec2238a367ea998347a036565f8284fd71be39a6bd7d4f631.json" =>
      "checkpoints under benchmarks/checkpoints/ are gitignored by design; the artifact itself carries the checkpoint content hashes"
  }

  # Reproduction commands recorded in immutable artifacts that no longer
  # resolve to a mix task or alias (dee-1t1w). Content-addressed artifacts
  # cannot be edited, so the annotation lives here: each entry names the live
  # superseding recipe. The gate re-verifies the artifact still records the
  # dead command, so a re-capture retires the entry.
  @dead_command_grandfathers %{
    {"benchmarks/evidence/admitted/optimize_anything/080f41578d725c8841d7484f6953cba419626b36f08043408c1027622ede4653.json",
     "dsex.benchmark.optimize_anything"} =>
      "historical — recipe superseded by `mix imp.benchmark.optimize_anything --live` (see the 58ff84ac… artifact admitted for the same protocol)"
  }

  test "every admitted artifact's git_sha is an ancestor of origin/main" do
    files = admitted_files()

    {_, origin_status} =
      System.cmd("git", ["rev-parse", "--verify", "origin/main"], stderr_to_stdout: true)

    assert origin_status == 0,
           "origin/main is not resolvable in this checkout; this gate needs a fetched " <>
             "origin/main ref and full history (CI: actions/checkout fetch-depth: 0)"

    for file <- files do
      artifact = decode!(file)

      case Map.fetch(artifact, "git_sha") do
        {:ok, sha} when is_binary(sha) ->
          assert sha =~ ~r/\A[0-9a-f]{40}\z/,
                 "#{file}: git_sha #{inspect(sha)} is not a full 40-hex commit"

          {out, status} =
            System.cmd("git", ["merge-base", "--is-ancestor", sha, "origin/main"],
              stderr_to_stdout: true
            )

          assert status == 0,
                 "#{file} binds commit #{sha} which is NOT reachable from origin/main " <>
                   "(#{String.trim(out)}). It was captured from an unpushed or " <>
                   "squashed-away commit, so the evidence is unverifiable from a fresh " <>
                   "clone (dee-di7u). Re-capture the artifact at a commit on origin/main."

        _ ->
          reason = Map.get(@missing_git_sha_exemptions, file)

          assert reason != nil,
                 "#{file} records no git_sha and has no annotated exemption; " <>
                   "evidence must bind the commit it was captured from (dee-sc3q)"
      end
    end

    # Exemptions must describe reality; delete the entry once the artifact
    # is re-captured with provenance.
    for {file, _reason} <- @missing_git_sha_exemptions do
      assert file in files, "stale exemption: #{file} is no longer admitted"
      refute Map.has_key?(decode!(file), "git_sha"), "stale exemption: #{file} now has git_sha"
    end
  end

  test "every admitted artifact is cited by a ledger (no orphans)" do
    files = admitted_files()
    ledgers = Map.new(@citing_ledgers, &{&1, File.read!(&1)})

    for file <- files do
      cited = Enum.any?(ledgers, fn {_path, body} -> String.contains?(body, file) end)

      assert cited,
             "#{file} is admitted but cited by none of #{inspect(@citing_ledgers)}; " <>
               "orphaned evidence is either superseded (archive it under " <>
               "benchmarks/evidence/archive/) or a missing claim binding (dee-sc3q)"
    end
  end

  test "recorded provenance checkpoint paths are committed" do
    for file <- admitted_files() do
      artifact = decode!(file)

      uncommitted =
        artifact
        |> checkpoint_paths()
        |> Enum.uniq()
        |> Enum.reject(&committed?/1)

      grandfathered = Map.get(@uncommitted_provenance_grandfathers, file)

      cond do
        uncommitted == [] ->
          refute grandfathered,
                 "stale grandfather entry: #{file} no longer cites uncommitted " <>
                   "provenance paths; delete it from @uncommitted_provenance_grandfathers"

        grandfathered != nil ->
          :ok

        true ->
          flunk(
            "#{file} cites provenance checkpoints that are not committed: " <>
              "#{inspect(uncommitted)}. Committed claims need committed receipts " <>
              "(dee-sc3q); commit the checkpoint or record a committed content address."
          )
      end
    end
  end

  test "every recorded reproduction command resolves to a mix task or alias" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases) |> Keyword.keys()
    alias_names = MapSet.new(aliases, &Atom.to_string/1)

    sources =
      Enum.map(admitted_files(), &{&1, decode!(&1)}) ++
        [{"benchmarks/authorities.json", decode!("benchmarks/authorities.json")}]

    found_dead =
      for {file, data} <- sources,
          {task, command} <- Enum.uniq(mix_commands(data)),
          Mix.Task.get(task) == nil and not MapSet.member?(alias_names, task) do
        annotation = Map.get(@dead_command_grandfathers, {file, task})

        assert annotation != nil,
               "#{file} records the command #{inspect(command)} but `mix #{task}` " <>
                 "resolves to no task or alias — a reader following the recipe hits a " <>
                 "dead end (dee-1t1w). Fix the recording or annotate it in " <>
                 "@dead_command_grandfathers with the live superseding command."

        {file, task}
      end

    # Grandfather entries must still match a recorded dead command; a
    # re-capture that retires the dead recipe must also retire the entry.
    for {key, _annotation} <- @dead_command_grandfathers do
      assert key in found_dead,
             "stale dead-command grandfather #{inspect(key)}: the artifact no longer " <>
               "records that command; delete the entry"
    end
  end

  defp admitted_files do
    files = Path.wildcard(@admitted_glob)

    assert files != [],
           "no admitted artifacts found under #{@admitted_glob}; this gate must " <>
             "never pass vacuously — run it from the repository root"

    files
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()

  defp committed?(path) do
    {_, status} = System.cmd("git", ["ls-files", "--error-unmatch", path], stderr_to_stdout: true)
    status == 0
  end

  # Repo-relative paths an artifact records as provenance receipts: checkpoint
  # files it claims a reader can open. tmp/ paths are ephemeral by contract and
  # judged by the owning protocol validator instead.
  defp checkpoint_paths(node), do: collect_checkpoints(node, [])

  defp collect_checkpoints(%{} = map, acc) do
    Enum.reduce(map, acc, fn
      {key, value}, inner when is_binary(value) ->
        if key in ["checkpoint", "budget_checkpoint"] or
             (key == "path" and String.starts_with?(value, "benchmarks/")) do
          if String.starts_with?(value, "benchmarks/"), do: [value | inner], else: inner
        else
          inner
        end

      {_key, value}, inner ->
        collect_checkpoints(value, inner)
    end)
  end

  defp collect_checkpoints(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_checkpoints/2)

  defp collect_checkpoints(_other, acc), do: acc

  defp mix_commands(node), do: collect_commands(node, [])

  defp collect_commands(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {_k, v}, inner -> collect_commands(v, inner) end)

  defp collect_commands(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_commands/2)

  defp collect_commands(value, acc) when is_binary(value) do
    case Regex.run(~r/(?:^|\s)mix\s+([a-z][a-z0-9._]*)/, value) do
      [_, task] -> [{task, value} | acc]
      nil -> acc
    end
  end

  defp collect_commands(_other, acc), do: acc
end

defmodule DSEx.EvidenceAuthorities do
  @moduledoc false

  @dimensions ~w(upstream_repository primary_authority upstream_tests dataset_protocol local_differential)
  @summary_start "<!-- evidence-authority-summary:start -->"
  @summary_end "<!-- evidence-authority-summary:end -->"
  @sha_reference ~r/^.+#sha256=[0-9a-f]{64}$/
  @sha_digest ~r/^sha256:[0-9a-f]{64}$/
  @sha256 ~r/^[0-9a-f]{64}$/
  @pinned_repository_statuses ~w(release_and_commit_pinned commit_pinned)

  def load!(path \\ "benchmarks/authorities.json") do
    ledger = path |> File.read!() |> Jason.decode!()
    validate!(ledger)
    validate_source_manifests!(ledger, path)
  end

  def validate!(%{"schema_version" => 1, "families" => families} = ledger)
      when is_list(families) and families != [] do
    Enum.each(families, &validate_family!/1)
    ledger
  end

  def validate!(_ledger), do: raise(ArgumentError, "invalid evidence authority ledger")

  def render_family_summary(%{"families" => families}) do
    header = [
      "| Family | Kind | Repository | Paper/spec | Upstream tests | Dataset/protocol | Local differential |",
      "| --- | --- | --- | --- | --- | --- | --- |"
    ]

    rows =
      Enum.map(families, fn family ->
        values = [
          family["name"],
          family["kind"],
          repository_label(family["upstream_repository"]),
          family["primary_authority"]["status"],
          family["upstream_tests"]["status"],
          family["dataset_protocol"]["status"],
          family["local_differential"]["status"]
        ]

        "| " <> Enum.map_join(values, " | ", &escape_cell/1) <> " |"
      end)

    Enum.join(header ++ rows, "\n")
  end

  def replace_summary!(body, table) when is_binary(body) and is_binary(table) do
    pattern =
      ~r/#{Regex.escape(@summary_start)}.*?#{Regex.escape(@summary_end)}/s

    replacement = Enum.join([@summary_start, table, @summary_end], "\n")

    if Regex.match?(pattern, body) do
      Regex.replace(pattern, body, replacement)
    else
      raise ArgumentError, "evidence authority summary markers are missing"
    end
  end

  defp validate_family!(family) do
    id = family["id"]

    unless is_binary(id) and String.starts_with?(id, "family.") do
      raise ArgumentError, "invalid evidence authority family id"
    end

    Enum.each(@dimensions, fn dimension ->
      unless is_map(family[dimension]) do
        raise ArgumentError, "#{id} is missing #{dimension}"
      end
    end)

    validate_repository!(id, family["upstream_repository"])
    validate_primary_authority!(id, family["primary_authority"])
    validate_upstream_tests!(id, family["upstream_tests"])
    validate_dataset_protocol!(id, family["dataset_protocol"])
  end

  defp validate_repository!(id, %{"status" => status} = repository)
       when status in @pinned_repository_statuses do
    unless nonempty?(repository["repository"]) and nonempty?(repository["version"]) and
             nonempty?(repository["git_ref"]) and digest?(repository["commit"], 40) and
             valid_manifest_reference?(repository["source_manifest"]) do
      raise ArgumentError, "#{id} has an invalid pinned repository"
    end
  end

  defp validate_repository!(_id, _repository), do: :ok

  defp validate_primary_authority!(
         id,
         %{"status" => "pinned", "locator" => locator, "revision" => revision, "title" => title}
       ) do
    unless nonempty?(locator) and nonempty?(revision) and nonempty?(title) and
             (not String.contains?(locator, "arxiv.org/abs/") or
                String.ends_with?(locator, revision)) do
      raise ArgumentError, "#{id} has an invalid pinned primary authority"
    end
  end

  defp validate_primary_authority!(_id, _authority), do: :ok

  defp validate_upstream_tests!(id, %{"status" => "present", "references" => references}) do
    unless is_list(references) and references != [] and
             Enum.all?(references, &(is_binary(&1) and Regex.match?(@sha_reference, &1))) do
      raise ArgumentError, "#{id} present upstream tests must have path-bound SHA-256 references"
    end
  end

  defp validate_upstream_tests!(id, %{"status" => "partial", "references" => references}) do
    unless is_list(references) and references != [] do
      raise ArgumentError, "#{id} partial upstream test audit must explain its evidence and gaps"
    end
  end

  defp validate_upstream_tests!(_id, _tests), do: :ok

  defp validate_dataset_protocol!(
         id,
         %{"status" => "pinned", "references" => references, "immutable_digests" => digests}
       ) do
    unless is_list(references) and references != [] and Enum.all?(references, &nonempty?/1) and
             is_list(digests) and digests != [] and
             Enum.all?(digests, &(is_binary(&1) and Regex.match?(@sha_digest, &1))) do
      raise ArgumentError, "#{id} has an invalid pinned dataset protocol"
    end
  end

  defp validate_dataset_protocol!(_id, _protocol), do: :ok

  defp repository_label(%{"status" => status, "version" => version, "commit" => commit})
       when status in @pinned_repository_statuses do
    "#{version} @ #{String.slice(commit, 0, 12)}"
  end

  defp repository_label(%{"status" => "not_applicable"}), do: "n/a"
  defp repository_label(%{"status" => status}), do: status

  defp escape_cell(value), do: value |> to_string() |> String.replace("|", "\\|")
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp digest?(value, length) do
    is_binary(value) and byte_size(value) == length and String.match?(value, ~r/^[0-9a-f]+$/)
  end

  defp valid_manifest_reference?(%{
         "path" => "benchmarks/authority_sources/" <> name,
         "sha256" => sha256,
         "file_count" => file_count
       }) do
    name != "" and not String.contains?(name, ["/", ".."]) and
      is_binary(sha256) and Regex.match?(@sha256, sha256) and
      is_integer(file_count) and file_count > 0
  end

  defp valid_manifest_reference?(_reference), do: false

  defp validate_source_manifests!(ledger, ledger_path) do
    project_root = ledger_path |> Path.expand() |> Path.dirname() |> Path.dirname()

    ledger["families"]
    |> Enum.filter(&(&1["upstream_repository"]["status"] in @pinned_repository_statuses))
    |> Enum.group_by(fn family ->
      repository = family["upstream_repository"]
      {repository["repository"], repository["commit"], repository["source_manifest"]}
    end)
    |> Enum.each(fn {{repository, commit, reference}, families} ->
      validate_source_manifest_reference!(
        project_root,
        repository,
        commit,
        reference,
        families
      )
    end)

    ax = get_in(ledger, ["pinned_sources", "ax_typescript"])

    unless is_map(ax) and ax["role"] == "independent_implementation_comparator" and
             valid_manifest_reference?(ax["source_manifest"]) do
      raise ArgumentError, "invalid Ax independent comparator authority"
    end

    validate_source_manifest_reference!(
      project_root,
      ax["repository"],
      ax["commit"],
      ax["source_manifest"],
      [%{"upstream_repository" => ax}]
    )

    ledger
  end

  defp validate_source_manifest_reference!(project_root, repository, commit, reference, families) do
    manifest_path = Path.join(project_root, reference["path"])
    bytes = File.read!(manifest_path)
    actual_sha256 = sha256(bytes)

    unless actual_sha256 == reference["sha256"] do
      raise ArgumentError,
            "authority source manifest digest mismatch for #{reference["path"]}: " <>
              "expected #{reference["sha256"]}, got #{actual_sha256}"
    end

    manifest = Jason.decode!(bytes)
    validate_source_manifest!(manifest, repository, commit, reference, families)
  end

  defp validate_source_manifest!(manifest, repository, commit, reference, families) do
    files = manifest["files"]

    unless manifest["schema_version"] == 1 and manifest["repository"] == repository and
             manifest["commit"] == commit and is_list(files) and
             length(files) == reference["file_count"] and files != [] do
      raise ArgumentError, "invalid authority source manifest #{reference["path"]}"
    end

    file_paths = Enum.map(files, & &1["path"])

    unless file_paths == Enum.sort(Enum.uniq(file_paths)) and
             Enum.all?(files, &valid_source_file?/1) do
      raise ArgumentError, "invalid authority source files in #{reference["path"]}"
    end

    declared_paths =
      families
      |> Enum.flat_map(& &1["upstream_repository"]["source_paths"])
      |> Enum.uniq()
      |> Enum.sort()

    unless manifest["source_paths"] == declared_paths and
             Enum.all?(declared_paths, &source_path_covered?(&1, file_paths)) do
      raise ArgumentError, "authority source manifest coverage mismatch for #{reference["path"]}"
    end
  end

  defp valid_source_file?(%{"path" => path, "sha256" => sha256}) do
    nonempty?(path) and not String.starts_with?(path, "/") and
      not String.contains?(path, "..") and is_binary(sha256) and Regex.match?(@sha256, sha256)
  end

  defp valid_source_file?(_file), do: false

  defp source_path_covered?(source_path, file_paths) do
    Enum.any?(file_paths, fn file_path ->
      file_path == source_path or String.starts_with?(file_path, source_path <> "/")
    end)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

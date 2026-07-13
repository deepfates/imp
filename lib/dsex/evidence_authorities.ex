defmodule DSEx.EvidenceAuthorities do
  @moduledoc false

  @dimensions ~w(upstream_repository primary_authority upstream_tests dataset_protocol local_differential)
  @summary_start "<!-- evidence-authority-summary:start -->"
  @summary_end "<!-- evidence-authority-summary:end -->"
  @sha_reference ~r/^.+#sha256=[0-9a-f]{64}$/
  @sha_digest ~r/^sha256:[0-9a-f]{64}$/

  def load!(path \\ "benchmarks/authorities.json") do
    ledger = path |> File.read!() |> Jason.decode!()
    validate!(ledger)
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
       when status in ["release_and_commit_pinned", "commit_pinned"] do
    unless nonempty?(repository["repository"]) and nonempty?(repository["version"]) and
             nonempty?(repository["git_ref"]) and digest?(repository["commit"], 40) do
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
       when status in ["release_and_commit_pinned", "commit_pinned"] do
    "#{version} @ #{String.slice(commit, 0, 12)}"
  end

  defp repository_label(%{"status" => "not_applicable"}), do: "n/a"
  defp repository_label(%{"status" => status}), do: status

  defp escape_cell(value), do: value |> to_string() |> String.replace("|", "\\|")
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp digest?(value, length) do
    is_binary(value) and byte_size(value) == length and String.match?(value, ~r/^[0-9a-f]+$/)
  end
end

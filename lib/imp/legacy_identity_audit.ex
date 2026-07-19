defmodule Imp.LegacyIdentityAudit do
  @moduledoc false

  @legacy_token ~r/(?i)(?<![a-z])dsex(?![a-z])/

  @live_package_prefixes [
    "lib/",
    "examples/",
    "livebooks/",
    "docs/",
    "README.md",
    "CHANGELOG.md",
    "mix.exs"
  ]

  @historical_prefixes %{
    "benchmarks/data/" => "frozen benchmark inputs and provenance",
    "benchmarks/evidence/admitted/" => "immutable admitted benchmark evidence",
    "benchmarks/evidence/archive/" =>
      "immutable superseded benchmark evidence (archived admissions)",
    "benchmarks/results/" => "pre-cutover benchmark results retained as historical evidence",
    "benchmarks/upstream/" => "pinned upstream evidence"
  }

  @allowlisted_files %{
    "benchmarks/authorities.json" => "benchmark authority provenance",
    "benchmarks/config/failure-recovery-live.json" => "historical live campaign configuration",
    "identity/DECISION.md" => "historical naming decision record",
    "lib/imp/benchmark_truth/local_mlx_campaign.ex" => "benchmark provenance adapter",
    "lib/imp/benchmark_truth/provider_training_campaign.ex" => "benchmark provenance adapter",
    "lib/imp/legacy_identity_audit.ex" => "the audit's own token matcher and policy",
    "scripts/legacy_identity_audit.exs" => "the audit's release-gate entrypoint",
    "test/evidence_provenance_test.exs" =>
      "dead-command lint (dee-1t1w): grandfather annotations name the retired dsex command being linted"
  }

  @type finding :: %{
          path: String.t(),
          line: non_neg_integer(),
          source: :path | :content,
          text: String.t(),
          policy: atom(),
          rationale: String.t() | nil
        }

  @doc "Returns the live/package path prefixes and historical allowlist."
  def policy do
    %{
      live_package_prefixes: @live_package_prefixes,
      historical_prefixes: @historical_prefixes,
      allowlisted_files: @allowlisted_files
    }
  end

  @doc "Audits tracked repository files under `root` without writing artifacts."
  def audit(root \\ File.cwd!()) do
    with {:ok, paths} <- tracked_paths(root),
         {:ok, entries} <- read_entries(paths, root) do
      findings = scan(entries)

      {:ok,
       %{
         findings: findings,
         violations: Enum.reject(findings, &allowlisted?/1),
         tracked_paths: length(entries)
       }}
    end
  end

  @doc "Runs the audit and returns `:ok` or `{:error, report}`."
  def run(root \\ File.cwd!()) do
    with {:ok, report} <- audit(root) do
      if report.violations == [], do: :ok, else: {:error, report}
    end
  end

  @doc "Scans `{path, content}` entries; useful for focused policy tests."
  def scan(entries) do
    Enum.flat_map(entries, fn %{path: path, content: content} ->
      path = normalize_path(path)
      policy = path_policy(path)

      path_findings =
        if Regex.match?(@legacy_token, path) do
          [
            %{
              path: path,
              line: 0,
              source: :path,
              text: path,
              policy: policy.kind,
              rationale: policy.rationale
            }
          ]
        else
          []
        end

      content_findings =
        if String.valid?(content) do
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, number} ->
            if Regex.match?(@legacy_token, line) do
              [
                %{
                  path: path,
                  line: number,
                  source: :content,
                  text: line,
                  policy: policy.kind,
                  rationale: policy.rationale
                }
              ]
            else
              []
            end
          end)
        else
          []
        end

      path_findings ++ content_findings
    end)
  end

  @doc false
  def allowlisted?(%{path: path}),
    do: path_policy(path).kind in [:historical, :compatibility, :audit]

  defp tracked_paths(root) do
    case System.cmd("git", ["ls-files", "-z"], cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.split(output, <<0>>, trim: true)}
      {output, status} -> {:error, {:git_ls_files_failed, status, output}}
    end
  end

  defp read_entries(paths, root) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, entries} ->
      case File.read(Path.join(root, path)) do
        {:ok, content} -> {:cont, {:ok, [%{path: path, content: content} | entries]}}
        {:error, :enoent} -> {:cont, {:ok, entries}}
        {:error, reason} -> {:halt, {:error, {:read_failed, path, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp path_policy(path) do
    cond do
      Map.has_key?(@allowlisted_files, path) ->
        %{kind: allowlist_kind(path), rationale: Map.fetch!(@allowlisted_files, path)}

      match?({:ok, _}, historical_prefix(path)) ->
        {:ok, rationale} = historical_prefix(path)
        %{kind: :historical, rationale: rationale}

      Enum.any?(@live_package_prefixes, &path_matches?(&1, path)) ->
        %{kind: :live_package, rationale: nil}

      true ->
        %{kind: :outside_product_surface, rationale: nil}
    end
  end

  defp allowlist_kind(path) do
    cond do
      path == "scripts/legacy_identity_audit.exs" -> :audit
      String.starts_with?(path, "lib/") -> :compatibility
      String.starts_with?(path, "test/") -> :compatibility
      true -> :historical
    end
  end

  defp historical_prefix(path) do
    Enum.find_value(@historical_prefixes, fn {prefix, rationale} ->
      if String.starts_with?(path, prefix), do: {:ok, rationale}
    end)
  end

  defp path_matches?(prefix, path), do: path == prefix or String.starts_with?(path, prefix)

  defp normalize_path(path), do: String.replace(path, "\\", "/")
end

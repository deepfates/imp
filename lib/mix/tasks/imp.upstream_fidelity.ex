defmodule Mix.Tasks.Imp.UpstreamFidelity do
  @moduledoc """
  Emit and optionally gate the Imp audited upstream-conformance ledger.

      mix imp.upstream_fidelity
      mix imp.upstream_fidelity --out tmp/upstream-fidelity.json --require-conformant
  """

  use Mix.Task

  @shortdoc "Audit Imp conformance dispositions against pinned upstream surfaces"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          out: :string,
          require_conformant: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    report = Imp.UpstreamFidelity.report()
    format = Keyword.get(opts, :format, "json")
    body = render(report, format)

    case Keyword.get(opts, :out) do
      nil ->
        Mix.shell().info(body)

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, body <> "\n")
        Mix.shell().info("upstream fidelity: #{path}")
    end

    if Keyword.get(opts, :require_conformant, false) and not report.summary.passing do
      Mix.raise(
        "upstream conformance gaps: " <>
          Enum.join(report.blocking_ids, ", ")
      )
    end
  end

  defp render(report, "json"), do: Jason.encode!(report, pretty: true)

  defp render(report, "markdown") do
    rows =
      report.surfaces
      |> Enum.map(fn surface ->
        upstream = Enum.join(surface.upstream, ", ")
        gate = gate_label(surface)

        "| #{surface.id} | #{surface.category} | #{surface.status} | #{gate} | #{upstream} |"
      end)
      |> Enum.join("\n")

    details =
      report.surfaces
      |> Enum.map(&render_surface/1)
      |> Enum.join("\n\n")

    """
    # Imp Audited Upstream Conformance Ledger

    This generated report audits asserted upstream-conformance statements. It
    is not the product release verdict or work queue; the source repository's
    maintainer release procedure owns the ordinary consumer finish line and
    unfinished work lives in pull requests.

    Each status below is a maintainer-authored disposition. The generator checks
    that named evidence exists and that claim and reproduction registries are
    internally valid; it does not infer
    semantic conformance merely because the named test files pass.

    Baseline: DSPy #{report.baseline.version} (`#{report.baseline.git_sha}`)
    Total: #{report.summary.total}
    Conformant: #{report.summary.conformant}
    Elixir-native equivalents: #{report.summary.elixir_native_equivalent}
    Tracking: #{report.summary.tracking}
    Gaps: #{report.summary.gaps}
    Claim-specific non-blocking gaps: #{report.summary.non_blocking_gaps}
    Invalid evidence: #{report.summary.invalid_evidence}
    Invalid aggregate rows: #{report.summary.invalid_rows}
    Missing manifest surfaces: #{report.summary.manifest_missing}
    Duplicate manifest owners: #{report.summary.manifest_duplicates}
    Asserted conformance blockers: #{report.summary.conformance_blockers}
    Asserted conformance passing: #{report.summary.passing}

    | ID | Category | Maintainer disposition | Product gate | Upstream surfaces |
    | --- | --- | --- | --- | --- |
    #{rows}

    ## Audited Contracts

    #{details}
    """
    |> String.trim()
  end

  defp render(_report, other),
    do: Mix.raise("--format must be json or markdown, got: #{inspect(other)}")

  defp gate_label(%{status: status, release_blocking: true})
       when status in [:gap, :invalid_evidence],
       do: "release blocker"

  defp gate_label(%{status: status}) when status in [:gap, :invalid_evidence],
    do: "claim-specific gap"

  defp gate_label(%{status: :tracking}), do: "tracked"
  defp gate_label(_surface), do: "satisfied"

  # The report ships inside the Hex package at docs/CONFORMANCE.md, so doc
  # evidence references must render package-aware: packaged files keep
  # relative references that resolve from docs/, while repository-only files
  # become absolute GitHub links labeled as such. This keeps the checked-in
  # report byte-reproducible by the generator (no hand-curated link edits).
  defp render_doc_reference(path) do
    packaged = packaged_file_set()

    cond do
      MapSet.member?(packaged, path) and String.contains?(path, "/") ->
        "- docs: `#{path}`"

      MapSet.member?(packaged, path) ->
        "- docs: `../#{path}`"

      true ->
        "- docs: [#{path}](https://github.com/deepfates/imp/blob/main/#{path}) (repository only, not shipped in the package)"
    end
  end

  defp packaged_file_set do
    Mix.Project.config()
    |> Keyword.fetch!(:package)
    |> Keyword.fetch!(:files)
    |> MapSet.new()
  end

  defp render_surface(surface) do
    invariants = Enum.map_join(surface.invariants, "\n", &"- #{&1}")
    tests = Enum.map_join(surface.evidence.tests, "\n", &"- test: `#{&1}`")
    docs = Enum.map_join(surface.evidence.docs, "\n", &render_doc_reference/1)

    artifacts =
      Enum.map_join(Map.get(surface.evidence, :artifacts, []), "\n", &"- artifact: `#{&1}`")

    missing =
      case Map.get(surface.evidence, :missing, []) do
        [] -> "- none"
        items -> Enum.map_join(items, "\n", &"- #{&1}")
      end

    capabilities =
      surface.capabilities
      |> Enum.filter(&(&1.claims != [] or &1.receipts != []))
      |> Enum.map_join("\n", fn capability ->
        claims =
          case capability.claims do
            [] ->
              "no indexed claim"

            items ->
              Enum.map_join(items, ", ", fn claim ->
                label = if claim.claim_state == "asserted", do: claim.gate_policy, else: "target"
                "#{claim.id} (#{label})"
              end)
          end

        receipts =
          case capability.receipts do
            [] ->
              "no cited registry receipt"

            items ->
              Enum.map_join(items, ", ", fn receipt ->
                "#{receipt.feature_id}=#{if receipt.valid, do: "valid", else: "INVALID"}"
              end)
          end

        "- `#{capability.surface}`: #{capability.status}; claims: #{claims}; receipts: #{receipts}"
      end)

    capability_section =
      if capabilities == "",
        do: "",
        else: "\nIndexed capability evidence:\n\n#{capabilities}\n"

    rationale =
      case Map.get(surface, :rationale) do
        nil -> ""
        value -> "\nElixir-native rationale: #{value}\n"
      end

    """
    ### `#{surface.id}`

    Maintainer disposition: `#{surface.status}`

    Upstream source: `#{surface.source}`

    Imp modules: #{Enum.map_join(surface.imp, ", ", &"`#{inspect(&1)}`")}#{rationale}
    Semantic invariants:

    #{invariants}

    Executable evidence:

    #{tests}
    #{docs}
    #{artifacts}
    #{capability_section}

    Missing evidence or behavior:

    #{missing}
    """
    |> String.trim()
  end
end

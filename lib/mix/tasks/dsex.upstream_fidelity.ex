defmodule Mix.Tasks.Dsex.UpstreamFidelity do
  @moduledoc """
  Emit and optionally gate the DSEx executable upstream-conformance ledger.

      mix dsex.upstream_fidelity
      mix dsex.upstream_fidelity --out tmp/upstream-fidelity.json --require-conformant
  """

  use Mix.Task

  @shortdoc "Audit executable DSEx conformance against pinned upstream surfaces"

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

    report = DSEx.UpstreamFidelity.report()
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
        ticket = Map.get(surface, :ticket, "")
        upstream = Enum.join(surface.upstream, ", ")
        "| #{surface.id} | #{surface.category} | #{surface.status} | #{upstream} | #{ticket} |"
      end)
      |> Enum.join("\n")

    details =
      report.surfaces
      |> Enum.map(&render_surface/1)
      |> Enum.join("\n\n")

    """
    # DSEx Executable Upstream Conformance

    Baseline: DSPy #{report.baseline.version} (`#{report.baseline.git_sha}`)
    Total: #{report.summary.total}
    Conformant: #{report.summary.conformant}
    Elixir-native equivalents: #{report.summary.elixir_native_equivalent}
    Tracking: #{report.summary.tracking}
    Gaps: #{report.summary.gaps}
    Invalid evidence: #{report.summary.invalid_evidence}
    Missing manifest surfaces: #{report.summary.manifest_missing}
    Duplicate manifest owners: #{report.summary.manifest_duplicates}
    Release blockers: #{report.summary.release_blockers}
    Passing: #{report.summary.passing}

    | ID | Category | Status | Upstream surfaces | Ticket |
    | --- | --- | --- | --- | --- |
    #{rows}

    ## Executable Contracts

    #{details}
    """
    |> String.trim()
  end

  defp render(_report, other),
    do: Mix.raise("--format must be json or markdown, got: #{inspect(other)}")

  defp render_surface(surface) do
    invariants = Enum.map_join(surface.invariants, "\n", &"- #{&1}")
    tests = Enum.map_join(surface.evidence.tests, "\n", &"- test: `#{&1}`")
    docs = Enum.map_join(surface.evidence.docs, "\n", &"- docs: `#{&1}`")

    missing =
      case Map.get(surface.evidence, :missing, []) do
        [] -> "- none"
        items -> Enum.map_join(items, "\n", &"- #{&1}")
      end

    rationale =
      case Map.get(surface, :rationale) do
        nil -> ""
        value -> "\nElixir-native rationale: #{value}\n"
      end

    """
    ### `#{surface.id}`

    Status: `#{surface.status}`

    Upstream source: `#{surface.source}`

    DSEx modules: #{Enum.map_join(surface.dsex, ", ", &"`#{inspect(&1)}`")}#{rationale}
    Semantic invariants:

    #{invariants}

    Executable evidence:

    #{tests}
    #{docs}

    Missing evidence or behavior:

    #{missing}
    """
    |> String.trim()
  end
end

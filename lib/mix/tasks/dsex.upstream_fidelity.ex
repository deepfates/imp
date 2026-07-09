defmodule Mix.Tasks.Dsex.UpstreamFidelity do
  @moduledoc """
  Emit and optionally gate the DSEx upstream-fidelity surface map.

      mix dsex.upstream_fidelity
      mix dsex.upstream_fidelity --out tmp/upstream-fidelity.json --require-mapped
  """

  use Mix.Task

  @shortdoc "Audit DSEx coverage against current upstream DSPy/GEPA surfaces"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          out: :string,
          require_mapped: :boolean
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

    if Keyword.get(opts, :require_mapped, false) and not report.summary.passing do
      unmapped =
        report.surfaces
        |> Enum.filter(&(&1.status == :unmapped))
        |> Enum.map_join(", ", &"#{&1.category}/#{&1.name}")

      Mix.raise("unmapped upstream surfaces: #{unmapped}")
    end
  end

  defp render(report, "json"), do: Jason.encode!(report, pretty: true)

  defp render(report, "markdown") do
    rows =
      report.surfaces
      |> Enum.map(fn surface ->
        "| #{surface.category} | #{surface.name} | #{surface.status} | #{Enum.join(surface.matches, ", ")} |"
      end)
      |> Enum.join("\n")

    """
    # DSEx Upstream Fidelity

    Total: #{report.summary.total}
    Mapped: #{report.summary.mapped}
    Unmapped: #{report.summary.unmapped}
    Passing: #{report.summary.passing}

    | Category | Surface | Status | Matches |
    | --- | --- | --- | --- |
    #{rows}
    """
    |> String.trim()
  end

  defp render(_report, other),
    do: Mix.raise("--format must be json or markdown, got: #{inspect(other)}")
end

defmodule Mix.Tasks.Imp.Benchmark.Catalog do
  @moduledoc """
  Emit the source-grounded Imp benchmark catalog.

      mix imp.benchmark.catalog
      mix imp.benchmark.catalog --format json --out tmp/benchmark-catalog.json
  """

  use Mix.Task

  @shortdoc "Emit the Imp benchmark coverage catalog"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          out: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    format = Keyword.get(opts, :format, "markdown")
    body = render(format)

    case Keyword.get(opts, :out) do
      nil ->
        Mix.shell().info(body)

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, body <> "\n")
        Mix.shell().info("benchmark catalog: #{path}")
    end
  end

  defp render("json") do
    Imp.BenchmarkCatalog.catalog()
    |> Jason.encode!(pretty: true)
  end

  defp render("markdown") do
    rows =
      Imp.BenchmarkCatalog.families()
      |> Enum.map(fn family ->
        "| #{family.family} | #{family.status} | #{commands(family)} | #{family.next_step} |"
      end)
      |> Enum.join("\n")

    """
    # Imp Benchmark Catalog

    | Family | Status | Commands | Next step |
    | --- | --- | --- | --- |
    #{rows}
    """
    |> String.trim()
  end

  defp render(other), do: Mix.raise("--format must be markdown or json, got: #{inspect(other)}")

  defp commands(%{commands: []}), do: "none"
  defp commands(%{commands: commands}), do: Enum.join(commands, "<br>")
end

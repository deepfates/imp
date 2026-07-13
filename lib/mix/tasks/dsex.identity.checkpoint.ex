defmodule Mix.Tasks.Dsex.Identity.Checkpoint do
  @moduledoc """
  Validate identity generation portfolios and build the lossless registry.

      mix dsex.identity.checkpoint
      mix dsex.identity.checkpoint --build
      mix dsex.identity.checkpoint --build --require-generation-floor
  """

  use Mix.Task

  @shortdoc "Audit or build the Step 8 identity candidate corpus"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          atlas: :string,
          inbox: :string,
          registry: :string,
          report: :string,
          build: :boolean,
          require_generation_floor: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    atlas_path = Keyword.get(opts, :atlas, "identity/atlas.json")
    inbox_glob = Keyword.get(opts, :inbox, "identity/inbox/*.json")
    registry_path = Keyword.get(opts, :registry, "identity/registry.jsonl")
    report_path = Keyword.get(opts, :report, "identity/reports/generation-coverage.json")

    atlas = DSEx.IdentityCheckpoint.load_atlas!(atlas_path)
    portfolios = DSEx.IdentityCheckpoint.load_portfolios!(inbox_glob)

    case DSEx.IdentityCheckpoint.compile(atlas, portfolios) do
      {:error, errors} ->
        Mix.raise("identity corpus is invalid:\n" <> Enum.map_join(errors, "\n", &"- #{&1}"))

      {:ok, %{events: events, report: report}} ->
        if Keyword.get(opts, :build, false) do
          DSEx.IdentityCheckpoint.write_atomic!(
            registry_path,
            DSEx.IdentityCheckpoint.render_registry(events)
          )

          DSEx.IdentityCheckpoint.write_atomic!(
            report_path,
            Jason.encode!(report, pretty: true) <> "\n"
          )
        end

        print_summary(report, length(portfolios))

        if Keyword.get(opts, :require_generation_floor, false) and
             not report["generation_floor_pass"] do
          Mix.raise("identity generation floor is incomplete")
        end
    end
  end

  defp print_summary(report, portfolio_count) do
    summary = report["summary"]

    Mix.shell().info("identity portfolios: #{portfolio_count}")
    Mix.shell().info("identity runs: #{summary["runs"]}")
    Mix.shell().info("raw candidate occurrences: #{summary["raw_occurrences"]}")

    Mix.shell().info(
      "distinct normalized candidates: #{summary["distinct_normalized_candidates"]}"
    )

    Mix.shell().info("generation floor passing: #{report["generation_floor_pass"]}")

    if report["gaps"] != [] do
      Mix.shell().info("remaining generation gaps: #{length(report["gaps"])}")
    end
  end
end

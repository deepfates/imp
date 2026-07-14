defmodule Mix.Tasks.Dsex.Identity.Review do
  @moduledoc """
  Build deterministic, non-destructive review pools from identity decision views.

      mix dsex.identity.review
      mix dsex.identity.review --scenario-limit 20 --disagreement-limit 50
  """

  use Mix.Task

  alias DSEx.IdentityReviewPools

  @shortdoc "Project deterministic identity review pools"

  @switches [
    decision_views: :string,
    assessments: :string,
    out: :string,
    scenario_limit: :integer,
    disagreement_limit: :integer,
    flagged_rank_threshold: :integer,
    resurrection_top_k: :integer
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    if argv != [], do: Mix.raise("unexpected arguments: #{Enum.join(argv, " ")}")

    Mix.Task.run("app.start")
    report = IdentityReviewPools.run_files!(opts)

    Mix.shell().info(
      "identity review pools: #{Keyword.get(opts, :out, "identity/reports/review-pools.json")}"
    )

    Mix.shell().info("candidate coverage: #{report["candidate_coverage"]["total_candidates"]}")
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end
end

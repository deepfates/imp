defmodule Mix.Tasks.Imp.ResearchPortfolio do
  @moduledoc "Generate or verify the capacity-first research portfolio."

  use Mix.Task

  @shortdoc "Generate or check the research portfolio"

  @impl true
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [check: :boolean, portfolio: :string, claims: :string, doc: :string]
      )

    if argv != [] or invalid != [], do: Mix.raise("invalid arguments")

    portfolio_path = Keyword.get(opts, :portfolio, "benchmarks/research_portfolio.json")
    claims_path = Keyword.get(opts, :claims, "benchmarks/claims.json")
    doc_path = Keyword.get(opts, :doc, "docs/maintainers/RESEARCH_PROTOCOLS.md")

    portfolio = Imp.ResearchPortfolio.load!(portfolio_path, claims_path: claims_path)
    current = File.read!(doc_path)

    expected =
      Imp.ResearchPortfolio.replace_summary!(current, Imp.ResearchPortfolio.render(portfolio))

    if Keyword.get(opts, :check, false) do
      if expected != current,
        do: Mix.raise("#{doc_path} is stale; regenerate research portfolio docs")

      Mix.shell().info("research claims, capacity portfolios, manifests, and documentation agree")
    else
      File.write!(doc_path, expected)
      Mix.shell().info(doc_path)
    end
  end
end

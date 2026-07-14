defmodule Mix.Tasks.Imp.EvidenceAuthorities do
  @moduledoc "Generate or verify the evidence-authority summary from its JSON ledger."

  use Mix.Task

  @shortdoc "Generate or check the evidence authority documentation"

  @impl true
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [check: :boolean, ledger: :string, doc: :string]
      )

    if argv != [] or invalid != [], do: Mix.raise("invalid arguments")

    ledger_path = Keyword.get(opts, :ledger, "benchmarks/authorities.json")
    doc_path = Keyword.get(opts, :doc, "docs/EVIDENCE_AUTHORITIES.md")
    ledger = Imp.EvidenceAuthorities.load!(ledger_path)
    current = File.read!(doc_path)

    expected =
      Imp.EvidenceAuthorities.replace_summary!(
        current,
        Imp.EvidenceAuthorities.render_family_summary(ledger)
      )

    if Keyword.get(opts, :check, false) do
      if expected != current, do: Mix.raise("#{doc_path} is stale; regenerate authority docs")
      Mix.shell().info("evidence authority ledger and documentation agree")
    else
      File.write!(doc_path, expected)
      Mix.shell().info(doc_path)
    end
  end
end

defmodule Mix.Tasks.Dsex.Reproductions do
  @moduledoc "Generate or verify the canonical research reproduction registry documentation."

  use Mix.Task

  @shortdoc "Generate or check the research reproduction registry"

  @impl true
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [check: :boolean, registry: :string, authority: :string, doc: :string]
      )

    if argv != [] or invalid != [], do: Mix.raise("invalid arguments")

    registry_path = Keyword.get(opts, :registry, "benchmarks/reproductions.json")
    authority_path = Keyword.get(opts, :authority, "benchmarks/authorities.json")
    doc_path = Keyword.get(opts, :doc, "docs/REPRODUCTION_STATUS.md")

    registry = DSEx.ReproductionRegistry.load!(registry_path, authority_path: authority_path)
    current = File.read!(doc_path)

    expected =
      DSEx.ReproductionRegistry.replace_summary!(
        current,
        DSEx.ReproductionRegistry.render(registry)
      )

    if Keyword.get(opts, :check, false) do
      if expected != current, do: Mix.raise("#{doc_path} is stale; regenerate reproduction docs")

      Mix.shell().info(
        "reproduction registry, authorities, tasks, artifacts, and documentation agree"
      )
    else
      File.write!(doc_path, expected)
      Mix.shell().info(doc_path)
    end
  end
end

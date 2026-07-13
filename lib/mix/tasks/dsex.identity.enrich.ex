defmodule Mix.Tasks.Dsex.Identity.Enrich do
  @moduledoc """
  Render baseline code, spoken, prose, and architecture forms for every identity.

      mix dsex.identity.enrich
  """

  use Mix.Task

  @shortdoc "Build baseline embodiments for every identity candidate"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [registry: :string, atlas: :string, out: :string, generated_at: :string]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    registry_path = Keyword.get(opts, :registry, "identity/registry.jsonl")
    atlas_path = Keyword.get(opts, :atlas, "identity/atlas.json")
    out = Keyword.get(opts, :out, "identity/enrichments.jsonl")

    registry = DSEx.IdentityEvaluation.load_jsonl!(registry_path)
    atlas = atlas_path |> File.read!() |> Jason.decode!()

    baseline_opts =
      case Keyword.get(opts, :generated_at) do
        nil -> []
        value -> [generated_at: value]
      end

    enrichments = DSEx.IdentityEnrichment.baseline(registry, atlas, baseline_opts)

    body =
      Enum.map_join(enrichments, "\n", &Jason.encode!/1) <>
        if(enrichments == [], do: "", else: "\n")

    DSEx.IdentityCheckpoint.write_atomic!(out, body)
    Mix.shell().info("identity baseline enrichments: #{length(enrichments)} -> #{out}")
  end
end

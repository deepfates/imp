defmodule Mix.Tasks.Dsex.Identity.Evaluate do
  @moduledoc """
  Build transparent scenario, tier, and Pareto views from identity assessments.

      mix dsex.identity.evaluate
  """

  use Mix.Task

  @shortdoc "Render non-destructive identity decision views"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          registry: :string,
          assessments: :string,
          flags: :string,
          dissent: :string,
          atlas: :string,
          scenarios: :string,
          out: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    registry = jsonl(opts, :registry, "identity/registry.jsonl")
    assessments = jsonl(opts, :assessments, "identity/assessments.jsonl", optional: true)
    flags = jsonl(opts, :flags, "identity/flags.jsonl", optional: true)
    dissent = jsonl(opts, :dissent, "identity/dissent.jsonl", optional: true)
    atlas = json(opts, :atlas, "identity/atlas.json")
    scenarios = json(opts, :scenarios, "identity/scenarios.json")
    out = Keyword.get(opts, :out, "identity/reports/decision-views.json")

    case DSEx.IdentityEvaluation.compile(registry, assessments, flags, dissent, atlas, scenarios) do
      {:error, errors} ->
        Mix.raise("identity evaluation is invalid:\n" <> Enum.map_join(errors, "\n", &"- #{&1}"))

      {:ok, report} ->
        DSEx.IdentityCheckpoint.write_atomic!(out, Jason.encode!(report, pretty: true) <> "\n")
        Mix.shell().info("identity decision views: #{out}")
        Mix.shell().info("candidate entities: #{report["summary"]["candidate_entities"]}")
    end
  end

  defp jsonl(opts, key, default, load_opts \\ []) do
    opts
    |> Keyword.get(key, default)
    |> DSEx.IdentityEvaluation.load_jsonl!(load_opts)
  end

  defp json(opts, key, default) do
    opts
    |> Keyword.get(key, default)
    |> File.read!()
    |> Jason.decode!()
  end
end

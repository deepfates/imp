defmodule Mix.Tasks.Imp.Benchmark.RlmRuntimeDifferential do
  @moduledoc """
  Compare Imp RLM with the pinned standalone RLM runtime.

      mix imp.benchmark.rlm_runtime_differential

  This is provider-free C1/C2 runtime evidence. It does not claim long-context
  effectiveness, DSPy adapter parity, or paper-scale reproduction.
  """

  use Mix.Task

  @shortdoc "Run the pinned standalone RLM runtime differential"
  @default_manifest "benchmarks/config/rlm-runtime-differential-v1.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          upstream: :string,
          python: :string,
          out: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir =
      Keyword.get(
        opts,
        :out,
        Imp.BenchmarkTruth.Paths.runs("rlm-runtime-differential")
      )

    File.mkdir_p!(out_dir)

    slug = Imp.BenchmarkTruth.ArtifactFile.run_name("rlm-runtime-differential", [])

    official_out = Path.join(out_dir, "official-standalone-rlm-#{slug}.json")

    manifest = Keyword.get(opts, :manifest, @default_manifest)
    upstream = Keyword.get(opts, :upstream, "tmp/rlm-upstream")
    python = Keyword.get(opts, :python, "tmp/rlm-upstream/.venv/bin/python")

    case Imp.BenchmarkTruth.RLMRuntimeDifferential.readiness(
           manifest: manifest,
           upstream: upstream,
           python: python
         ) do
      {:ok, _ready} ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "RLM differential setup is not ready: #{reason}. " <>
            "Prepare the pinned checkout and venv, then rerun " <>
            "mix imp.benchmark.rlm_runtime_differential."
        )
    end

    artifact =
      Imp.BenchmarkTruth.RLMRuntimeDifferential.run(
        manifest: manifest,
        upstream: upstream,
        python: python,
        official_out: official_out
      )

    path =
      Path.join(out_dir, "imp-standalone-rlm-#{slug}.json")
      |> Imp.BenchmarkTruth.ArtifactFile.write_json!(artifact)

    Mix.shell().info("Standalone RLM runtime differential: #{path}")
    Mix.shell().info("Official runtime sidecar: #{official_out}")

    unless get_in(artifact, ["summary", "differential_complete"]) do
      Mix.raise("standalone RLM runtime differential failed; inspect #{path}")
    end
  end
end

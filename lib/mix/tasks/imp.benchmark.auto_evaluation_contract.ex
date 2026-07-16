defmodule Mix.Tasks.Imp.Benchmark.AutoEvaluationContract do
  @moduledoc "Run or validate the provider-free DSPy 3.2.1 auto-evaluation differential."
  use Mix.Task

  @shortdoc "Run pinned auto-evaluation behavioral contracts"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [manifest: :string, out: :string, validate: :string, allow_dirty: :boolean]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    manifest =
      Keyword.get(
        opts,
        :manifest,
        Imp.BenchmarkTruth.AutoEvaluationContract.default_manifest()
      )

    case Keyword.fetch(opts, :validate) do
      {:ok, path} ->
        path
        |> Imp.BenchmarkTruth.ArtifactFile.read_run_json!()
        |> Imp.BenchmarkTruth.AutoEvaluationContract.validate_artifact!(manifest)

        Mix.shell().info("Valid auto-evaluation differential: #{path}")

      :error ->
        result =
          Imp.BenchmarkTruth.AutoEvaluationContract.run!(
            manifest: manifest,
            output:
              Keyword.get(
                opts,
                :out,
                "benchmarks/runs/auto-evaluation-differential-v1.json"
              ),
            allow_dirty: Keyword.get(opts, :allow_dirty, false)
          )

        Mix.shell().info("Auto-evaluation provider-free differential: #{result.path}")
    end
  end
end

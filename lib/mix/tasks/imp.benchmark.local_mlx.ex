defmodule Mix.Tasks.Imp.Benchmark.LocalMlx do
  use Mix.Task

  @shortdoc "Runs the fresh local MLX weight-training effectiveness campaign"

  @switches [
    dataset: :string,
    root: :string,
    artifact: :string,
    model_path: :string,
    executable: :string,
    port: :integer,
    concurrency: :integer,
    allow_dirty: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("invalid local MLX campaign arguments: #{inspect(rest ++ invalid)}")
    end

    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    root = Keyword.get(opts, :root, "tmp/mlx-campaign-#{stamp}")

    result =
      Imp.BenchmarkTruth.LocalMLXCampaign.run!(
        dataset:
          Keyword.get(opts, :dataset, "benchmarks/data/provider-training-banking77-v1.json"),
        root: root,
        artifact:
          Keyword.get(opts, :artifact, "benchmarks/results/local-mlx/local-mlx-#{stamp}.json"),
        model_path: Keyword.get(opts, :model_path),
        executable: Keyword.get(opts, :executable, "uvx"),
        port: Keyword.get(opts, :port, 18_821),
        concurrency: Keyword.get(opts, :concurrency, 1),
        require_clean: not Keyword.get(opts, :allow_dirty, false)
      )

    Mix.shell().info(
      Jason.encode!(%{path: result.path, acceptance: result.artifact["acceptance"]}, pretty: true)
    )

    unless result.artifact["acceptance"]["admissible"] do
      Mix.raise("local MLX campaign completed but failed admission")
    end
  end
end

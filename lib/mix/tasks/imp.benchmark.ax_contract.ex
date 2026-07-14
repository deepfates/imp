defmodule Mix.Tasks.Imp.Benchmark.AxContract do
  @moduledoc "Run the provider-free differential against pinned Ax 23.0.0."
  use Mix.Task

  @shortdoc "Run pinned Ax independent-implementation contracts"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          ax_package_dir: :string,
          ax_tarball: :string,
          out: :string,
          allow_dirty: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    result =
      Imp.BenchmarkTruth.AxContract.run!(
        ax_package_dir: Keyword.fetch!(opts, :ax_package_dir),
        ax_tarball: Keyword.fetch!(opts, :ax_tarball),
        output: Keyword.get(opts, :out, "benchmarks/results/ax-contract.json"),
        allow_dirty: Keyword.get(opts, :allow_dirty, false)
      )

    Mix.shell().info("Ax provider-free differential: #{result.path}")
  end
end

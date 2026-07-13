defmodule Mix.Tasks.Dsex.Benchmark.InstructionOptimizerExperiment do
  @moduledoc """
  Run or resume a matched DSEx/DSPy instruction-optimizer experiment.

      mix dsex.benchmark.instruction_optimizer_experiment \
        --manifest benchmarks/config/instruction-optimizer-experiment.json \
        --runtime both \
        --out benchmarks/results

  `--runtime` accepts `both`, `dsex`, `dspy`, or `none`. When a runtime is
  skipped, pass `--dsex-artifact` and/or `--dspy-artifact` to perform a
  fail-closed merge of existing outputs.
  The command emits one-seed AIME research preflight evidence, never T3.
  """

  use Mix.Task

  @shortdoc "Run a matched DSEx/DSPy instruction-optimizer preflight"

  @impl true
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          runtime: :string,
          out: :string,
          checkpoint_dir: :string,
          python: :string,
          python_script: :string,
          dspy_pythonpath: :string,
          repo_root: :string,
          api_key_env: :string,
          dsex_artifact: :string,
          dspy_artifact: :string,
          plan: :boolean
        ]
      )

    if invalid != [] or argv != [],
      do: Mix.raise("invalid arguments: #{inspect(invalid ++ argv)}")

    Mix.Task.run("app.start")

    experiment_opts =
      [
        manifest: fetch!(opts, :manifest),
        runtimes: runtimes!(Keyword.get(opts, :runtime, "both"))
      ]
      |> maybe_put(:out_dir, Keyword.get(opts, :out))
      |> maybe_put(:checkpoint_dir, Keyword.get(opts, :checkpoint_dir))
      |> maybe_put(:python, Keyword.get(opts, :python))
      |> maybe_put(:python_script, Keyword.get(opts, :python_script))
      |> maybe_put(:dspy_pythonpath, Keyword.get(opts, :dspy_pythonpath))
      |> maybe_put(:repo_root, Keyword.get(opts, :repo_root))
      |> maybe_put(:api_key_env, Keyword.get(opts, :api_key_env))
      |> maybe_put(:dsex_artifact, Keyword.get(opts, :dsex_artifact))
      |> maybe_put(:dspy_artifact, Keyword.get(opts, :dspy_artifact))

    if Keyword.get(opts, :plan, false) do
      plan =
        DSEx.BenchmarkTruth.InstructionOptimizerExperiment.plan!(
          Keyword.fetch!(experiment_opts, :manifest),
          experiment_opts
        )

      Mix.shell().info(Jason.encode!(plan, pretty: true))
      Mix.shell().info("Plan only: no provider calls were made")
    else
      result = DSEx.BenchmarkTruth.InstructionOptimizerExperiment.run(experiment_opts)

      Mix.shell().info("Experiment identity: #{result.identity["identity_sha256"]}")

      Mix.shell().info("DSPy config: #{result.python_config}")

      case result.merged do
        nil ->
          Mix.shell().info(
            "Matched report not written: both complete runtime outputs are required"
          )

        %{path: path} ->
          Mix.shell().info("Matched research preflight: #{path}")
      end
    end
  rescue
    error in [ArgumentError, File.Error, Jason.DecodeError] -> Mix.raise(Exception.message(error))
  end

  defp runtimes!("both"), do: [:dsex, :dspy]
  defp runtimes!("dsex"), do: [:dsex]
  defp runtimes!("dspy"), do: [:dspy]
  defp runtimes!("none"), do: []
  defp runtimes!(other), do: Mix.raise("invalid --runtime #{inspect(other)}")

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp fetch!(opts, key) do
    Keyword.get(opts, key) ||
      Mix.raise("--#{key |> Atom.to_string() |> String.replace("_", "-")} is required")
  end
end

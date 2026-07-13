defmodule Mix.Tasks.Dsex.Benchmark.RlmCampaign do
  @moduledoc """
  Validate, plan, or execute the manifest-pinned T2/T3 RLM campaign.

      mix dsex.benchmark.rlm_campaign --plan
      mix dsex.benchmark.rlm_campaign --dry-run --manifest benchmarks/config/rlm-paper-protocol-v3.json
      mix dsex.benchmark.rlm_campaign --runtime both --out benchmarks/results

  `--plan` permits explicit acquisition placeholders and performs no provider
  calls. `--dry-run` requires all hashes, frozen IDs, sources, and datasets to
  validate but performs no provider calls. Execution is always live and
  checkpointed; there is no oracle or scripted fixture mode.
  """

  use Mix.Task

  alias DSEx.BenchmarkTruth.{RLMCampaign, RLMDataset, RLMManifest}

  @shortdoc "Run the manifest-pinned RLM T2/T3 campaign"
  @default_manifest "benchmarks/config/rlm-paper-protocol-v3.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          out: :string,
          checkpoint_dir: :string,
          runtime: :string,
          python: :string,
          plan: :boolean,
          dry_run: :boolean
        ]
      )

    if invalid != [] or argv != [],
      do: Mix.raise("invalid arguments: #{inspect(invalid ++ argv)}")

    manifest_path = Keyword.get(opts, :manifest, @default_manifest)

    cond do
      Keyword.get(opts, :plan, false) ->
        plan = RLMCampaign.plan(manifest_path)
        Mix.shell().info(Jason.encode!(plan, pretty: true))

      Keyword.get(opts, :dry_run, false) ->
        manifest = RLMManifest.load!(manifest_path)
        RLMManifest.verify_sources!(manifest)
        datasets = RLMDataset.load_all!(manifest)

        Mix.shell().info(
          Jason.encode!(
            %{
              "validated" => true,
              "provider_calls" => 0,
              "families" =>
                Map.new(datasets, fn {family, data} -> {family, data["evaluated_rows"]} end)
            }, pretty: true)
        )

      true ->
        result =
          RLMCampaign.run(manifest_path,
            out: Keyword.get(opts, :out, "benchmarks/results"),
            checkpoint_dir:
              Keyword.get(opts, :checkpoint_dir, "benchmarks/results/rlm-checkpoints"),
            runtime: Keyword.get(opts, :runtime, "dsex"),
            python: Keyword.get(opts, :python, default_python())
          )

        Mix.shell().info("RLM campaign artifact: #{result.path}")
        Mix.shell().info("RLM campaign checkpoint: #{result.checkpoint_path}")
    end
  rescue
    error in [ArgumentError, File.Error] -> Mix.raise(Exception.message(error))
  end

  defp default_python do
    local = Path.expand("tmp/dspy-current-venv/bin/python")
    if File.exists?(local), do: local, else: System.find_executable("python3") || "python3"
  end
end

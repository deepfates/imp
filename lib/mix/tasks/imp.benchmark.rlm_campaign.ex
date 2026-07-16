defmodule Mix.Tasks.Imp.Benchmark.RlmCampaign do
  @moduledoc """
  Validate, plan, or execute the manifest-pinned T2/T3 RLM campaign.

      mix imp.benchmark.rlm_campaign --plan
      mix imp.benchmark.rlm_campaign --plan --family oolong --approach direct,rlm --runtime both --row-limit 1
      mix imp.benchmark.rlm_campaign --dry-run --manifest benchmarks/config/rlm-paper-protocol-v3.json
      mix imp.benchmark.rlm_campaign --runtime both --out benchmarks/runs/rlm-campaign

  `--plan` emits exact jobs for selected pinned families and performs no
  provider calls. `--dry-run` also performs no provider calls. Execution is
  always live and checkpointed; there is no oracle or scripted fixture mode.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.RLMCampaign

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
          family: :keep,
          approach: :keep,
          row_limit: :integer,
          sample_limit: :integer,
          python: :string,
          plan: :boolean,
          dry_run: :boolean
        ]
      )

    if invalid != [] or argv != [],
      do: Mix.raise("invalid arguments: #{inspect(invalid ++ argv)}")

    manifest_path = Keyword.get(opts, :manifest, @default_manifest)
    campaign_opts = campaign_opts(opts)

    cond do
      Keyword.get(opts, :plan, false) ->
        plan = RLMCampaign.plan(manifest_path, campaign_opts)
        Mix.shell().info(Jason.encode!(plan, pretty: true))

      Keyword.get(opts, :dry_run, false) ->
        plan = RLMCampaign.plan(manifest_path, campaign_opts)

        Mix.shell().info(
          Jason.encode!(
            %{
              "validated" => true,
              "provider_calls" => 0,
              "selection" => plan["selection"],
              "job_count" => plan["job_count"],
              "families" => plan["families"]
            },
            pretty: true
          )
        )

      true ->
        result =
          RLMCampaign.run(
            manifest_path,
            campaign_opts ++
              [
                out: Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("rlm-campaign")),
                checkpoint_dir:
                  Keyword.get(
                    opts,
                    :checkpoint_dir,
                    Imp.BenchmarkTruth.Paths.checkpoints("rlm-campaign")
                  ),
                python: Keyword.get(opts, :python, default_python())
              ]
          )

        Mix.shell().info("RLM campaign artifact: #{result.path}")
        Mix.shell().info("RLM campaign checkpoint: #{result.checkpoint_path}")
    end
  rescue
    error in [ArgumentError, File.Error] -> Mix.raise(Exception.message(error))
  end

  defp campaign_opts(opts) do
    row_limit = Keyword.get(opts, :row_limit)
    sample_limit = Keyword.get(opts, :sample_limit)

    if row_limit && sample_limit,
      do: raise(ArgumentError, "use only one of --row-limit or --sample-limit")

    [
      runtime: Keyword.get(opts, :runtime, "imp"),
      families: csv_values(opts, :family),
      approaches: csv_values(opts, :approach),
      row_limit: row_limit || sample_limit
    ]
  end

  defp csv_values(opts, key) do
    opts
    |> Keyword.get_values(key)
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
  end

  defp default_python do
    local = Path.expand("tmp/dspy-current-venv/bin/python")
    if File.exists?(local), do: local, else: System.find_executable("python3") || "python3"
  end
end

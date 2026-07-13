defmodule Mix.Tasks.Dsex.Benchmark.InstructionOptimizerCampaign do
  @moduledoc """
  Run a resumable, cost-capped AIME preflight for DSEx instruction optimizers.

      mix dsex.benchmark.instruction_optimizer_campaign \
        --dataset-root benchmarks/data/gepa-campaign-full \
        --config benchmarks/config/instruction-optimizer-aime-preflight.json \
        --api-key-env OPENAI_API_KEY \
        --out benchmarks/results

  The JSON config pins the campaign/model/seed, optimizer arms and effective
  configs, conservative reservation pricing, and hard request/token/USD caps.
  This command emits one-seed research preflight evidence. It never labels the
  result as T3 effectiveness or cross-runtime parity.
  """

  use Mix.Task

  @shortdoc "Run the cost-capped DSEx instruction-optimizer preflight"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          dataset_root: :string,
          config: :string,
          api_key_env: :string,
          out: :string,
          checkpoint_dir: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    Mix.Task.run("app.start")

    config = opts |> fetch!(:config) |> File.read!() |> Jason.decode!()
    api_key_env = Keyword.get(opts, :api_key_env, "OPENAI_API_KEY")
    api_key = System.get_env(api_key_env) || Mix.raise("#{api_key_env} is required")
    model = Map.fetch!(config, "model")
    max_tokens = Map.fetch!(config, "max_output_tokens")

    lm =
      DSEx.req_llm(model,
        api_key: api_key,
        temperature: Map.get(config, "temperature", 1.0),
        max_tokens: max_tokens,
        max_retries: 0
      )

    result =
      DSEx.BenchmarkTruth.InstructionOptimizerCampaign.run(
        dataset_root: fetch!(opts, :dataset_root),
        campaign_id: Map.fetch!(config, "campaign_id"),
        family: Map.get(config, "family", "AIMEBench"),
        model: model,
        lm: lm,
        seed: Map.get(config, "seed", 17),
        arms: Map.fetch!(config, "arms"),
        arm_configs: Map.fetch!(config, "arm_configs"),
        budget: Map.fetch!(config, "budget"),
        pricing: Map.fetch!(config, "reservation_pricing"),
        max_output_tokens: max_tokens,
        source_commits: Map.fetch!(config, "source_commits"),
        out_dir: Keyword.get(opts, :out, "benchmarks/results"),
        checkpoint_dir:
          Keyword.get(opts, :checkpoint_dir, "benchmarks/results/optimizer-checkpoints")
      )

    Mix.shell().info("Instruction optimizer preflight: #{result.path}")
    Mix.shell().info("Checkpoint: #{result.checkpoint_path}")
  end

  defp fetch!(opts, key),
    do:
      Keyword.get(opts, key) ||
        Mix.raise("--#{key |> Atom.to_string() |> String.replace("_", "-")} is required")
end

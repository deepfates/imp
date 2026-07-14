defmodule Mix.Tasks.Dsex.Benchmark.ProviderTraining do
  use Mix.Task

  @shortdoc "Runs the paid provider training and held-out effectiveness campaign"

  @switches [
    dataset: :string,
    checkpoint: :string,
    state: :string,
    artifact: :string,
    program: :string,
    model: :string,
    poll_ms: :integer,
    max_polls: :integer,
    concurrency: :integer,
    epochs: :integer,
    suffix: :string,
    max_cost_usd: :float,
    training_file: :string,
    allow_dirty: :boolean,
    env_file: :keep
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("invalid provider training arguments: #{inspect(rest ++ invalid)}")
    end

    env_files = Keyword.get_values(opts, :env_file)
    DSEx.BenchmarkEnv.load_files!(if(env_files == [], do: [".env"], else: env_files))

    paths = default_paths()

    campaign_opts = [
      dataset: Keyword.get(opts, :dataset, paths.dataset),
      checkpoint: Keyword.get(opts, :checkpoint, paths.checkpoint),
      state: Keyword.get(opts, :state, paths.state),
      artifact: Keyword.get(opts, :artifact, paths.artifact),
      program: Keyword.get(opts, :program, paths.program),
      model: Keyword.get(opts, :model, "openai:gpt-4.1-mini-2025-04-14"),
      poll_ms: Keyword.get(opts, :poll_ms, 30_000),
      max_polls: Keyword.get(opts, :max_polls, 360),
      concurrency: Keyword.get(opts, :concurrency, 8),
      epochs: Keyword.get(opts, :epochs, 3),
      suffix: Keyword.get(opts, :suffix, "dsex-route-v1"),
      max_cost_usd: Keyword.get(opts, :max_cost_usd, 5.0),
      training_file: Keyword.get(opts, :training_file),
      require_clean: not Keyword.get(opts, :allow_dirty, false),
      api_key: System.fetch_env!("OPENAI_API_KEY")
    ]

    result = DSEx.BenchmarkTruth.ProviderTrainingCampaign.run!(campaign_opts)

    Mix.shell().info(
      Jason.encode!(
        %{path: result.path, acceptance: result.artifact["acceptance"]},
        pretty: true
      )
    )

    unless result.artifact["acceptance"]["admissible"] do
      Mix.raise("paid provider training campaign completed but failed admission")
    end
  end

  defp default_paths do
    root = "benchmarks/results/provider-training"

    %{
      dataset: "benchmarks/data/provider-training-banking77-v1.json",
      checkpoint: Path.join(root, "openai-banking77-v2-job.json"),
      state: Path.join(root, "openai-banking77-v2-state.json"),
      artifact: Path.join(root, "openai-banking77-v2-campaign.json"),
      program: Path.join(root, "openai-banking77-v2-program.json")
    }
  end
end

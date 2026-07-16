defmodule Mix.Tasks.Imp.Benchmark.FailureCampaign do
  @moduledoc """
  Run the repeated failure and recovery campaign.

      mix imp.benchmark.failure_campaign --iterations 10 --out tmp/failure-campaign
      mix imp.benchmark.failure_campaign --live --live-iterations 2 --model gpt-4.1-mini
  """

  use Mix.Task

  @shortdoc "Run repeated Imp failure and recovery checks"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          iterations: :integer,
          max_concurrency: :integer,
          iteration_timeout_ms: :integer,
          live: :boolean,
          live_iterations: :integer,
          live_timeout_ms: :integer,
          api_key_env: :string,
          model: :string,
          agent_model: :string,
          base_url: :string,
          require_clean: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    live? = Keyword.get(opts, :live, false)

    run_context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: Keyword.get(opts, :require_clean, false),
        inputs: %{
          "protocol_id" => "failure_campaign",
          "iterations" => Keyword.get(opts, :iterations, 10),
          "max_concurrency" => Keyword.get(opts, :max_concurrency, 4),
          "iteration_timeout_ms" => Keyword.get(opts, :iteration_timeout_ms, 15_000),
          "live" => live?,
          "live_iterations" => Keyword.get(opts, :live_iterations, 2),
          "live_timeout_ms" => Keyword.get(opts, :live_timeout_ms, 30_000),
          "model" => Keyword.get(opts, :model, "gpt-4.1-mini"),
          "agent_model" =>
            Keyword.get(opts, :agent_model, Keyword.get(opts, :model, "gpt-4.1-mini"))
        }
      )

    api_key_env = Keyword.get(opts, :api_key_env, "OPENAI_API_KEY")
    api_key = if live?, do: System.get_env(api_key_env) || Mix.raise("#{api_key_env} is required")

    artifact =
      Imp.BenchmarkTruth.FailureCampaign.run(
        iterations: Keyword.get(opts, :iterations, 10),
        max_concurrency: Keyword.get(opts, :max_concurrency, 4),
        iteration_timeout_ms: Keyword.get(opts, :iteration_timeout_ms, 15_000),
        live: live?,
        live_iterations: Keyword.get(opts, :live_iterations, 2),
        live_timeout_ms: Keyword.get(opts, :live_timeout_ms, 30_000),
        api_key: api_key,
        secrets: if(api_key, do: [api_key], else: []),
        model: Keyword.get(opts, :model, "gpt-4.1-mini"),
        agent_model: Keyword.get(opts, :agent_model, Keyword.get(opts, :model, "gpt-4.1-mini")),
        base_url:
          Keyword.get(
            opts,
            :base_url,
            System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"
          )
      )

    out_dir = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("failure-recovery"))
    File.mkdir_p!(out_dir)
    path = Path.join(out_dir, "failure-campaign-#{timestamp_slug()}.json")

    %{artifact: artifact, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, artifact, run_context)

    Mix.shell().info("failure campaign report: #{path}")

    unless artifact["summary"]["deterministic_complete"] and artifact["runtime"]["leak_free"] and
             (not live? or artifact["summary"]["live_complete"]) do
      Mix.raise("deterministic failure campaign failed; inspect #{path}")
    end
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
  end
end

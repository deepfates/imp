defmodule Mix.Tasks.Imp.Benchmark.Playbook do
  use Mix.Task

  @evaluation_requests_per_row 3
  @proposal_max_attempts 2
  @input_per_million 0.40
  @output_per_million 1.60
  @shortdoc "Runs the bounded persistent-playbook held-out campaign"

  @moduledoc """
  Runs the source-pinned Dynamic Cheatsheet equation-balancing campaign through
  `Imp.Optimizer.Playbook`.

      mix imp.benchmark.playbook \
        --config benchmarks/config/playbook-live.json \
        --api-key-env OPENAI_API_KEY
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [config: :string, api_key_env: :string, plan: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid playbook campaign arguments")
    config_path = Keyword.get(opts, :config, "benchmarks/config/playbook-live.json")
    config = config_path |> File.read!() |> Jason.decode!()

    if Keyword.get(opts, :plan, false) do
      Mix.shell().info(Jason.encode!(plan(config), pretty: true))
    else
      env = Keyword.get(opts, :api_key_env, "OPENAI_API_KEY")
      api_key = System.get_env(env) || Mix.raise("#{env} is required")
      artifact = Imp.Optimizer.Playbook.Campaign.run(config, api_key)
      Mix.shell().info("playbook campaign artifact: #{config["out"]}")
      Mix.shell().info("promoted: #{get_in(artifact, ["outcome", "promoted"])}")
    end
  end

  defp plan(config) do
    evaluation_rows =
      config["train_count"] + 2 * config["promotion_count"] + 2 * config["audit_count"]

    evaluation_calls = evaluation_rows * @evaluation_requests_per_row

    max_input_tokens =
      evaluation_calls * config["max_input_tokens_per_call"] +
        @proposal_max_attempts * config["max_proposal_input_tokens"]

    max_output_tokens =
      evaluation_calls * config["max_output_tokens"] +
        @proposal_max_attempts * config["max_proposal_output_tokens"]

    %{
      "network_calls" => evaluation_calls + @proposal_max_attempts,
      "model" => config["model"],
      "splits" => %{
        "train" => config["train_count"],
        "promotion" => config["promotion_count"],
        "audit" => config["audit_count"]
      },
      "max_input_tokens" => max_input_tokens,
      "max_output_tokens" => max_output_tokens,
      "max_cost_usd" =>
        max_input_tokens / 1_000_000 * @input_per_million +
          max_output_tokens / 1_000_000 * @output_per_million,
      "provider_calls_per_plan" => 0
    }
  end
end

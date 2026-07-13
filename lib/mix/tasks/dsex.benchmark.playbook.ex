defmodule Mix.Tasks.Dsex.Benchmark.Playbook do
  use Mix.Task

  @shortdoc "Runs the bounded persistent-playbook held-out campaign"

  @moduledoc """
  Runs the source-pinned Dynamic Cheatsheet equation-balancing campaign through
  `DSEx.Optimizer.Playbook`.

      mix dsex.benchmark.playbook \
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
      artifact = DSEx.Optimizer.Playbook.Campaign.run(config, api_key)
      Mix.shell().info("playbook campaign artifact: #{config["out"]}")
      Mix.shell().info("promoted: #{get_in(artifact, ["outcome", "promoted"])}")
    end
  end

  defp plan(config) do
    %{
      "network_calls" =>
        config["train_count"] + 2 * config["promotion_count"] +
          2 * config["audit_count"] + 1,
      "model" => config["model"],
      "splits" => %{
        "train" => config["train_count"],
        "promotion" => config["promotion_count"],
        "audit" => config["audit_count"]
      },
      "max_input_tokens" =>
        (config["train_count"] + 2 * config["promotion_count"] +
           2 * config["audit_count"]) * config["max_input_tokens_per_call"] +
          config["max_proposal_input_tokens"],
      "max_output_tokens" =>
        (config["train_count"] + 2 * config["promotion_count"] +
           2 * config["audit_count"]) * config["max_output_tokens"] +
          config["max_proposal_output_tokens"],
      "provider_calls_per_plan" => 0
    }
  end
end

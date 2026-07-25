defmodule Mix.Tasks.Imp.Benchmark.SupportTicketLift do
  @moduledoc """
  Run the three-seed untouched support-ticket baseline/LabeledFewShot preflight.

      mix imp.benchmark.support_ticket_lift --runtime local --out /tmp/ticket-local.json
      mix imp.benchmark.support_ticket_lift --runtime openrouter-free --out /tmp/ticket-free.json
      mix imp.benchmark.support_ticket_lift --runtime openrouter-free \
        --manifest benchmarks/config/support-ticket-lift-openrouter-free-v2.json \
        --out /tmp/ticket-free-v2.json

  `openrouter-free` requires `OPENROUTER_API_KEY` in the process environment and
  is pinned to 48 logical calls/transport attempts under the exact free-route
  guard. This is a one-task preflight, not general optimizer effectiveness.
  """

  use Mix.Task

  @shortdoc "Run the untouched support-ticket lift preflight"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [runtime: :string, model: :string, manifest: :string, out: :string]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    Mix.Task.run("app.start")

    runtime = parse_runtime(Keyword.get(opts, :runtime, "local"))
    out = Keyword.get(opts, :out, "/tmp/imp-support-ticket-lift.json") |> Path.expand()

    campaign_opts =
      [runtime: runtime]
      |> Keyword.merge(manifest_options(opts[:manifest], runtime))
      |> maybe_put(:model, opts[:model])
      |> maybe_put_api_key(runtime)
      |> maybe_put_model_metadata(runtime, opts[:model])

    artifact = Imp.BenchmarkTruth.SupportTicketLiftCampaign.run(campaign_opts)
    write_atomic!(out, Jason.encode!(artifact, pretty: true) <> "\n")

    Mix.shell().info("Support-ticket lift preflight: #{out}")
    Mix.shell().info("Status: #{artifact["summary"]["execution_complete"]}")
    Mix.shell().info("Mean held-out lift: #{artifact["summary"]["mean_test_lift"]}")

    unless artifact["summary"]["execution_complete"] do
      Mix.raise("support-ticket lift preflight did not complete")
    end
  end

  defp parse_runtime("local"), do: :local
  defp parse_runtime("openrouter-free"), do: :openrouter_free
  defp parse_runtime(other), do: Mix.raise("unsupported --runtime #{inspect(other)}")

  defp manifest_options(nil, _runtime), do: []

  defp manifest_options(path, :openrouter_free) do
    Imp.BenchmarkTruth.SupportTicketLiftCampaign.v2_options!(path)
  end

  defp manifest_options(_path, runtime) do
    Mix.raise("a campaign manifest is not supported for runtime #{inspect(runtime)}")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_api_key(opts, :local), do: opts

  defp maybe_put_api_key(opts, :openrouter_free) do
    key = System.get_env("OPENROUTER_API_KEY") || Mix.raise("OPENROUTER_API_KEY is required")
    Keyword.put(opts, :api_key, key)
  end

  defp maybe_put_model_metadata(opts, :openrouter_free, _model), do: opts

  defp maybe_put_model_metadata(opts, :local, model) do
    model = model || "ollama:llama3.2:3b"
    Keyword.put(opts, :model_metadata, ollama_metadata(model))
  end

  defp ollama_metadata("ollama:" <> model) do
    case Req.get("http://127.0.0.1:11434/api/tags", retry: false, max_retries: 0) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} ->
        row = Enum.find(models, &(&1["name"] == model)) || %{}
        %{"name" => model, "digest" => row["digest"], "self_hosted_provider_cost_usd" => 0.0}

      _ ->
        %{"name" => model, "digest" => nil, "self_hosted_provider_cost_usd" => 0.0}
    end
  end

  defp ollama_metadata(model), do: %{"name" => model, "digest" => nil}

  defp write_atomic!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, bytes)
      File.rename!(temporary, path)
    after
      if File.exists?(temporary), do: File.rm(temporary)
    end
  end
end

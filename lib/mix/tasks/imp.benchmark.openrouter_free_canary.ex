defmodule Mix.Tasks.Imp.Benchmark.OpenrouterFreeCanary do
  @moduledoc """
  Run one fail-closed OpenRouter free-route canary.

      mix imp.benchmark.openrouter_free_canary --out /tmp/openrouter-free-canary.json

  The task requires `OPENROUTER_API_KEY` in the process environment. It never
  prints or writes the key. It makes exactly one non-sensitive logical call and
  refuses success unless the serialized route is exact-free, the transport
  attempt count is one, and both provider-reported and computed cost are zero.
  """

  use Mix.Task

  @shortdoc "Run one exact-free, single-attempt OpenRouter canary"

  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [out: :string])
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    Mix.Task.run("app.start")
    out = Keyword.get(opts, :out, "/tmp/imp-openrouter-free-canary.json") |> Path.expand()
    api_key = System.get_env("OPENROUTER_API_KEY") || Mix.raise("OPENROUTER_API_KEY is required")

    result = Imp.BenchmarkTruth.OpenRouterFreeGuard.run(api_key: api_key)
    artifact = elem(result, 1)
    write_atomic!(out, Jason.encode!(artifact, pretty: true) <> "\n")

    case result do
      {:ok, _artifact} -> Mix.shell().info("OpenRouter free canary passed: #{out}")
      {:error, artifact} -> Mix.raise("OpenRouter free canary failed: #{artifact["error"]}")
    end
  end

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

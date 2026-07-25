defmodule Mix.Tasks.Imp.Benchmark.OpenrouterFreeTypedCanary do
  @moduledoc """
  Run the preregistered synthetic typed-format canary once per exact-free candidate.

      mix imp.benchmark.openrouter_free_typed_canary \
        --manifest benchmarks/config/openrouter-free-typed-format-canary-v1.json \
        --out /tmp/openrouter-free-typed-format-canary.json

  This task requires `OPENROUTER_API_KEY`. It does not use benchmark rows or
  measure optimizer effectiveness.
  """

  use Mix.Task

  @shortdoc "Run exact-free synthetic typed-format canaries"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [manifest: :string, out: :string])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    Mix.Task.run("app.start")

    manifest =
      Keyword.get(
        opts,
        :manifest,
        "benchmarks/config/openrouter-free-typed-format-canary-v1.json"
      )

    out =
      Keyword.get(opts, :out, "/tmp/openrouter-free-typed-format-canary.json") |> Path.expand()

    api_key = System.get_env("OPENROUTER_API_KEY") || Mix.raise("OPENROUTER_API_KEY is required")

    artifact =
      Imp.BenchmarkTruth.TypedFormatCanary.run(
        api_key: api_key,
        manifest: manifest
      )

    write_atomic!(out, Jason.encode!(artifact, pretty: true) <> "\n")
    Mix.shell().info("OpenRouter typed-format canary: #{out}")

    Enum.each(artifact["results"], fn result ->
      Mix.shell().info(
        "#{get_in(result, ["candidate", "id"])}: " <>
          to_string(get_in(result, ["format_status", "passed"]))
      )
    end)
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

pattern = ~r/DSEx|DSEX_|dsex[._-]|lib\/dsex/

allowed_prefixes = [
  "benchmarks/data/",
  "benchmarks/results/",
  "benchmarks/upstream/",
  "identity/DECISION.md",
  "test/fixtures/"
]

allowed_files =
  MapSet.new([
    "benchmarks/authorities.json",
    "benchmarks/config/failure-recovery-live.json",
    "benchmarks/config/gepa-paper-campaign-v1.json",
    "benchmarks/config/gepa-paper-campaign-v2.json",
    "benchmarks/config/rlm-paper-protocol-v3.json",
    "docs/IDENTITY_COMPATIBILITY.md",
    "docs/README.md",
    "lib/imp/benchmark_truth/local_mlx_campaign.ex",
    "lib/imp/benchmark_truth/provider_training_campaign.ex",
    "lib/imp/persistence/legacy.ex",
    "lib/imp/saving.ex",
    "lib/mix/tasks/imp.benchmark.trace.ex",
    "scripts/legacy_identity_audit.exs",
    "test/persistence_legacy_test.exs"
  ])

allowed? = fn path ->
  MapSet.member?(allowed_files, path) or
    Enum.any?(allowed_prefixes, &String.starts_with?(path, &1))
end

{tracked, 0} = System.cmd("git", ["ls-files", "-co", "--exclude-standard"])

findings =
  tracked
  |> String.split("\n", trim: true)
  |> Enum.flat_map(fn path ->
    case File.read(path) do
      {:ok, content} ->
        if String.valid?(content) do
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, number} ->
            if Regex.match?(pattern, line), do: [{path, number, line}], else: []
          end)
        else
          []
        end

      {:error, _reason} ->
        []
    end
  end)

case Enum.reject(findings, fn {path, _number, _line} -> allowed?.(path) end) do
  [] ->
    files = findings |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()

    IO.puts(
      "legacy identity audit passed: #{length(findings)} matches in #{files} allowlisted files"
    )

  violations ->
    Enum.each(violations, fn {path, number, line} ->
      IO.puts(:stderr, "#{path}:#{number}:#{line}")
    end)

    System.halt(1)
end

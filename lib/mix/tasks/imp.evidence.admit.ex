defmodule Mix.Tasks.Imp.Evidence.Admit do
  @moduledoc "Validate and admit one immutable research artifact."

  use Mix.Task

  @shortdoc "Admit a validated artifact into the canonical evidence store"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          artifact: :string,
          protocol: :string,
          tier: :string,
          features: :string,
          registry: :string,
          authority: :string
        ]
      )

    if argv != [] or invalid != [],
      do: Mix.raise("invalid arguments: #{inspect(argv ++ invalid)}")

    result =
      Imp.BenchmarkTruth.EvidenceAdmission.admit!(
        artifact_path: required!(opts, :artifact),
        protocol_id: required!(opts, :protocol),
        tier: required!(opts, :tier),
        feature_ids: parse_features(required!(opts, :features)),
        registry_path: Keyword.get(opts, :registry, "benchmarks/reproductions.json"),
        authority_path: Keyword.get(opts, :authority, "benchmarks/authorities.json")
      )

    Mix.shell().info("admitted evidence: #{result.artifact}")
    Mix.shell().info("sha256: #{result.artifact_sha256}")
    Mix.shell().info("features: #{Enum.join(result.features, ", ")}")

    if result.supporting_features != [] do
      Mix.shell().info(
        "retained as complementary evidence without downgrading: #{Enum.join(result.supporting_features, ", ")}"
      )
    end
  rescue
    error in [ArgumentError, KeyError] -> Mix.raise(Exception.message(error))
  end

  defp required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "--#{key} is required"
    end
  end

  defp parse_features(value) do
    features = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if features == [],
      do: raise(ArgumentError, "--features must name at least one feature"),
      else: features
  end
end

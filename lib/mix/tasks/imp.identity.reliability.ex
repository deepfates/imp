defmodule Mix.Tasks.Imp.Identity.Reliability do
  @moduledoc """
  Compute descriptive inter-rater reliability for identity assessments.

      mix imp.identity.reliability
  """

  use Mix.Task

  alias Imp.{IdentityCheckpoint, IdentityEvaluation, IdentityReliability}

  @shortdoc "Compute identity assessment inter-rater reliability"

  @impl true
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [assessments: :string, scenarios: :string, out: :string]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    if argv != [], do: Mix.raise("unexpected arguments: #{Enum.join(argv, " ")}")

    assessments =
      opts
      |> Keyword.get(:assessments, "identity/assessments.jsonl")
      |> IdentityEvaluation.load_jsonl!()

    scenarios =
      opts
      |> Keyword.get(:scenarios, "identity/scenarios.json")
      |> File.read!()
      |> Jason.decode!()

    out = Keyword.get(opts, :out, "identity/reports/inter-rater-reliability.json")
    report = IdentityReliability.compile!(assessments, scenarios)

    IdentityCheckpoint.write_atomic!(out, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info(
      "identity reliability: #{report["candidate_count"]} candidates, " <>
        "#{report["profile_count"]} profiles, #{report["axis_count"]} axes"
    )
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end
end

defmodule DSEx.Optimizer.COPRO do
  @moduledoc "Coordinate prompt optimizer over instruction candidates."

  defstruct [:metric, :proposer_lm, breadth: 5, depth: 2, extra_instructions: []]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      breadth: non_negative_integer(Keyword.get(opts, :breadth, 5)),
      depth: non_negative_integer(Keyword.get(opts, :depth, 2)),
      proposer_lm: Keyword.get(opts, :proposer_lm),
      extra_instructions: Keyword.get(opts, :extra_instructions, [])
    }
  end

  def compile(%__MODULE__{depth: 0} = optimizer, program, trainset, devset) do
    baseline =
      DSEx.Optimizer.InstructionSearch.compile(
        program,
        optimizer.metric,
        trainset,
        devset,
        []
      )

    baseline_report = DSEx.Optimizer.Report.fetch(baseline)

    DSEx.Optimizer.Report.attach(
      baseline,
      DSEx.Optimizer.Report.new(%{
        optimizer: :copro,
        best_score: baseline_report.best_score,
        candidate_count: 0,
        candidates: [],
        errors: baseline_report.errors,
        metadata: %{
          breadth: optimizer.breadth,
          depth: 0,
          rounds: [],
          baseline_score: baseline_report.metadata[:baseline_score],
          status: :baseline_only
        }
      })
    )
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    {compiled, round_reports} =
      1..optimizer.depth
      |> Enum.reduce({program, []}, fn round, {current, reports} ->
        candidates =
          current
          |> DSEx.Optimizer.InstructionSearch.candidate_instructions(trainset,
            lm: optimizer.proposer_lm,
            scores: round_score_summary(reports),
            extra_instructions: optimizer.extra_instructions
          )
          |> Enum.take(optimizer.breadth)

        next =
          DSEx.Optimizer.InstructionSearch.compile(
            current,
            optimizer.metric,
            trainset,
            devset,
            candidates
          )

        report = DSEx.Optimizer.Report.fetch(next)
        {next, reports ++ [Map.put(report, :metadata, Map.put(report.metadata, :round, round))]}
      end)

    final_report = List.last(round_reports)

    DSEx.Optimizer.Report.attach(
      compiled,
      DSEx.Optimizer.Report.new(%{
        optimizer: :copro,
        best_score: final_report.best_score,
        candidate_count: Enum.reduce(round_reports, 0, &(&1.candidate_count + &2)),
        candidates:
          Enum.flat_map(round_reports, fn report ->
            round = report.metadata.round
            Enum.map(report.candidates, &Map.put(&1, :round, round))
          end),
        metadata: %{
          breadth: optimizer.breadth,
          depth: optimizer.depth,
          rounds: round_reports
        }
      })
    )
  end

  defp round_score_summary(reports) do
    reports
    |> Enum.flat_map(& &1.candidates)
    |> Enum.map(&Map.take(&1, [:instruction, :score, :round]))
  end

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0
end

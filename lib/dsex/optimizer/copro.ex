defmodule DSEx.Optimizer.COPRO do
  @moduledoc "Coordinate prompt optimizer over instruction candidates."

  defstruct [:metric, :proposer_lm, breadth: 5, depth: 2, extra_instructions: []]

  @option_schema [
    breadth: [type: :non_neg_integer, default: 5],
    depth: [type: :non_neg_integer, default: 2],
    proposer_lm: [type: :any, default: nil],
    extra_instructions: [type: {:list, :string}, default: []]
  ]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(metric, [2, 3], "DSEx.Optimizer.COPRO.new/2", "metric")
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.COPRO.new/2")

    %__MODULE__{
      metric: metric,
      breadth: opts[:breadth],
      depth: opts[:depth],
      proposer_lm: opts[:proposer_lm],
      extra_instructions: opts[:extra_instructions]
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
        {candidates, proposal_errors} =
          candidate_instructions(current, trainset,
            lm: optimizer.proposer_lm,
            scores: round_score_summary(reports),
            extra_instructions: optimizer.extra_instructions
          )

        next =
          DSEx.Optimizer.InstructionSearch.compile(
            current,
            optimizer.metric,
            trainset,
            devset,
            Enum.take(candidates, optimizer.breadth)
          )

        report = DSEx.Optimizer.Report.fetch(next)

        report =
          report
          |> Map.update!(:errors, &(proposal_errors ++ &1))
          |> Map.put(:metadata, Map.put(report.metadata, :round, round))

        {next, reports ++ [report]}
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
        errors:
          Enum.flat_map(round_reports, fn report ->
            round = report.metadata.round
            Enum.map(report.errors, &Map.put(&1, :round, round))
          end),
        metadata: %{
          breadth: optimizer.breadth,
          depth: optimizer.depth,
          rounds: round_reports,
          status: if(Enum.any?(round_reports, &(&1.errors != [])), do: :with_errors, else: :ok)
        }
      })
    )
  end

  defp candidate_instructions(program, trainset, opts) do
    {DSEx.Optimizer.InstructionSearch.candidate_instructions(program, trainset, opts), []}
  rescue
    error ->
      {fallback_candidate(program, opts),
       [%{stage: :instruction_proposal, reason: error_message(error)}]}
  catch
    kind, reason ->
      {fallback_candidate(program, opts),
       [%{stage: :instruction_proposal, reason: error_message({kind, reason})}]}
  end

  defp fallback_candidate(program, opts) do
    base = DSEx.Optimizer.InstructionSearch.current_instruction(program) || "Complete the task."
    [base | Keyword.get(opts, :extra_instructions, [])]
  end

  defp round_score_summary(reports) do
    reports
    |> Enum.flat_map(& &1.candidates)
    |> Enum.map(&Map.take(&1, [:instruction, :score, :round]))
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

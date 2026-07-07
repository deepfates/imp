defmodule DSEx.Optimizer.InstructionSearch do
  @moduledoc """
  Search over candidate signature instructions and keep the best program.

  `InstructionSearch` is the small, explicit optimizer underneath
  instruction-only workflows such as `DSEx.Optimizer.SignatureOptimizer` and
  coordinate prompt optimization. It evaluates each proposed instruction on the
  dev set, evaluates the original program as a baseline, and attaches an
  optimizer report to the selected program.

  Failed candidates are recorded in the report instead of aborting the whole
  compile. If every evaluation fails, `compile/6` returns the original program
  with a diagnostic report.
  """

  def compile(program, metric, trainset, devset, candidates, opts \\ []) do
    demos = Keyword.get(opts, :demos, [])
    evaluator = DSEx.Evaluate.new(devset, metric)
    candidate_instructions = unique_candidates(candidates)

    candidate_results =
      candidate_instructions
      |> Enum.map(fn instruction ->
        candidate =
          program
          |> put_instruction(instruction)
          |> maybe_put_demos(demos)

        evaluate_candidate(evaluator, candidate, instruction, %{baseline: false})
      end)

    baseline_result =
      evaluate_candidate(evaluator, program, current_instruction(program), %{baseline: true})

    {best_score, best, report_candidates, errors, report_metadata} =
      summarize(candidate_results ++ [baseline_result], program)

    best
    |> attach_optimizer_metadata(%{
      trainset_size: safe_count(trainset),
      candidate_count: length(candidate_instructions)
    })
    |> DSEx.Optimizer.Report.attach(
      DSEx.Optimizer.Report.new(%{
        optimizer: :instruction_search,
        best_score: best_score,
        candidate_count: length(report_candidates),
        candidates: report_candidates,
        errors: errors,
        metadata:
          Map.merge(report_metadata, %{
            requested_candidates: length(candidate_instructions),
            trainset_size: safe_count(trainset)
          })
      })
    )
  end

  def put_instruction(%DSEx.Predict.Predict{signature: signature} = program, instruction) do
    DSEx.Predict.Predict.with_signature(program, %{signature | instructions: instruction})
  end

  def put_instruction(%DSEx.Predict.ChainOfThought{predict: predict} = program, instruction) do
    %{program | predict: put_instruction(predict, instruction)}
  end

  def put_instruction(program, _instruction), do: program

  def current_instruction(%DSEx.Predict.Predict{signature: signature}),
    do: signature.instructions

  def current_instruction(%DSEx.Predict.ChainOfThought{predict: predict}),
    do: current_instruction(predict)

  def current_instruction(_program), do: nil

  def candidate_instructions(program, trainset, opts \\ []) do
    DSEx.Optimizer.InstructionProposer.propose(program, trainset, opts)
  end

  defp evaluate_candidate(evaluator, candidate, instruction, metadata) do
    result = DSEx.Evaluate.run(evaluator, candidate)
    {:ok, result.score, candidate, instruction, metadata}
  rescue
    error -> {:error, error, instruction, metadata}
  catch
    kind, reason -> {:error, {kind, reason}, instruction, metadata}
  end

  defp summarize(results, fallback) do
    successes =
      Enum.flat_map(results, fn
        {:ok, score, candidate, instruction, metadata} ->
          [{score, candidate, instruction, metadata}]

        _ ->
          []
      end)

    errors =
      Enum.flat_map(results, fn
        {:error, error, instruction, metadata} ->
          [%{error: error_message(error), instruction: instruction, metadata: metadata}]

        _ ->
          []
      end)

    report_candidates =
      Enum.map(successes, fn {score, _candidate, instruction, metadata} ->
        metadata
        |> Map.take([:baseline])
        |> Map.merge(%{score: score, instruction: instruction})
      end)

    case successes do
      [] ->
        {nil, fallback, [], errors, %{status: :all_candidates_failed}}

      _ ->
        {best_score, best, _instruction, _metadata} =
          Enum.max_by(successes, fn {score, _candidate, _instruction, _metadata} -> score end)

        {best_score, best, report_candidates, errors,
         %{
           status: :ok,
           baseline_score: baseline_score(report_candidates),
           successful_candidates: length(report_candidates)
         }}
    end
  end

  defp maybe_put_demos(program, []), do: program

  defp maybe_put_demos(%DSEx.Predict.Predict{} = program, demos),
    do: DSEx.Predict.Predict.with_demos(program, demos)

  defp maybe_put_demos(%DSEx.Predict.ChainOfThought{predict: predict} = program, demos) do
    %{program | predict: DSEx.Predict.Predict.with_demos(predict, demos)}
  end

  defp maybe_put_demos(program, _demos), do: program

  defp attach_optimizer_metadata(%DSEx.Predict.Predict{} = program, metadata),
    do: %{program | metadata: Map.merge(program.metadata, metadata)}

  defp attach_optimizer_metadata(
         %DSEx.Predict.ChainOfThought{predict: predict} = program,
         metadata
       ) do
    %{program | predict: attach_optimizer_metadata(predict, metadata)}
  end

  defp attach_optimizer_metadata(program, _metadata), do: program

  defp unique_candidates(candidates), do: Enum.uniq(candidates)

  defp safe_count(enumerable), do: Enum.count(enumerable)

  defp baseline_score(candidates) do
    candidates
    |> Enum.find(& &1.baseline)
    |> case do
      nil -> nil
      candidate -> candidate.score
    end
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

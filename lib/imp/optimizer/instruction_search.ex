defmodule Imp.Optimizer.InstructionSearch do
  @moduledoc """
  Search over candidate signature instructions and keep the best program.

  `InstructionSearch` is the small, explicit optimizer underneath
  instruction-only workflows such as `Imp.Optimizer.SignatureOptimizer` and
  coordinate prompt optimization. It evaluates each proposed instruction on the
  dev set, evaluates the original program as a baseline, and attaches an
  optimizer report to the selected program.

  Failed candidates are recorded in the report instead of aborting the whole
  compile. If every evaluation fails, `compile/6` returns the original program
  with a diagnostic report.
  """

  def compile(program, metric, trainset, devset, candidates, opts \\ []) do
    demos = Keyword.get(opts, :demos, [])
    candidate_instructions = unique_candidates(candidates)

    {candidate_results, baseline_result} =
      case new_evaluator(devset, metric) do
        {:ok, evaluator} ->
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

          {candidate_results, baseline_result}

        {:error, error} ->
          candidate_results =
            Enum.map(candidate_instructions, fn instruction ->
              {:error, error, instruction, %{baseline: false}}
            end)

          {candidate_results, {:error, error, current_instruction(program), %{baseline: true}}}
      end

    {best_score, best, report_candidates, errors, report_metadata} =
      summarize(candidate_results ++ [baseline_result], program)

    best
    |> attach_optimizer_metadata(%{
      trainset_size: safe_count(trainset),
      candidate_count: length(candidate_instructions)
    })
    |> Imp.Optimizer.Report.attach(
      Imp.Optimizer.Report.new(%{
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

  defp new_evaluator(devset, metric) do
    {:ok, Imp.Evaluate.new(devset, metric)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def put_instruction(%Imp.Predict.Predict{signature: signature} = program, instruction) do
    Imp.Predict.Predict.with_signature(program, %{signature | instructions: instruction})
  end

  def put_instruction(%Imp.Predict.ChainOfThought{predict: predict} = program, instruction) do
    %{program | predict: put_instruction(predict, instruction)}
  end

  def put_instruction(
        %Imp.Predict.ProgramOfThought{signature: signature, predict: predict} = program,
        instruction
      ) do
    %{
      program
      | signature: %{signature | instructions: instruction},
        predict: put_instruction(predict, instruction)
    }
  end

  def put_instruction(%Imp.Predict.CodeAct{program_of_thought: pot} = program, instruction) do
    %{program | program_of_thought: put_instruction(pot, instruction)}
  end

  def put_instruction(%Imp.Predict.RAG{program: inner} = program, instruction) do
    %{program | program: put_instruction(inner, instruction)}
  end

  def put_instruction(%module{} = program, instruction) do
    if function_exported?(module, :put_instruction, 2),
      do: module.put_instruction(program, instruction),
      else: program
  end

  def put_instruction(program, _instruction), do: program

  def current_instruction(%Imp.Predict.Predict{signature: signature}),
    do: signature.instructions

  def current_instruction(%Imp.Predict.ChainOfThought{predict: predict}),
    do: current_instruction(predict)

  def current_instruction(%Imp.Predict.ProgramOfThought{predict: predict}),
    do: current_instruction(predict)

  def current_instruction(%Imp.Predict.CodeAct{program_of_thought: pot}),
    do: current_instruction(pot)

  def current_instruction(%Imp.Predict.RAG{program: inner}),
    do: current_instruction(inner)

  def current_instruction(%module{} = program) do
    if function_exported?(module, :current_instruction, 1),
      do: module.current_instruction(program),
      else: nil
  end

  def current_instruction(_program), do: nil

  def candidate_instructions(program, trainset, opts \\ []) do
    Imp.Optimizer.InstructionProposer.propose(program, trainset, opts)
  end

  defp evaluate_candidate(evaluator, candidate, instruction, metadata) do
    result = Imp.Evaluate.run(evaluator, candidate)
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

  defp maybe_put_demos(program, demos) do
    case Imp.ProgramAccess.predict(program) do
      nil -> program
      _predict -> Imp.with_demos(program, demos)
    end
  end

  defp attach_optimizer_metadata(program, metadata) do
    Imp.ProgramAccess.merge_metadata(program, metadata)
  end

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

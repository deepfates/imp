defmodule DSEx.Optimizer.InstructionSearch do
  @moduledoc false

  def compile(program, metric, trainset, devset, candidates, opts \\ []) do
    demos = Keyword.get(opts, :demos, [])
    evaluator = DSEx.Evaluate.new(devset, metric)

    results =
      candidates
      |> Enum.uniq()
      |> Enum.map(fn instruction ->
        candidate =
          program
          |> put_instruction(instruction)
          |> maybe_put_demos(demos)

        {DSEx.Evaluate.run(evaluator, candidate).score, candidate, instruction}
      end)
      |> Kernel.++([
        {DSEx.Evaluate.run(evaluator, program).score, program, current_instruction(program)}
      ])

    {best_score, best, _instruction} =
      Enum.max_by(results, fn {score, _candidate, _instruction} -> score end)

    best
    |> attach_optimizer_metadata(%{
      trainset_size: length(trainset),
      candidate_count: length(candidates)
    })
    |> DSEx.Optimizer.Report.attach(
      DSEx.Optimizer.Report.new(%{
        optimizer: :instruction_search,
        best_score: best_score,
        candidate_count: length(results),
        candidates:
          Enum.map(results, fn {score, _candidate, instruction} ->
            %{score: score, instruction: instruction}
          end)
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
end

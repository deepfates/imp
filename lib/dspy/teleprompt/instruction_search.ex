defmodule DSPy.Teleprompt.InstructionSearch do
  @moduledoc false

  def compile(program, metric, trainset, devset, candidates, opts \\ []) do
    demos = Keyword.get(opts, :demos, [])
    evaluator = DSPy.Evaluate.new(devset, metric)

    results =
      candidates
      |> Enum.uniq()
      |> Enum.map(fn instruction ->
        candidate =
          program
          |> put_instruction(instruction)
          |> maybe_put_demos(demos)

        {DSPy.Evaluate.run(evaluator, candidate).score, candidate, instruction}
      end)
      |> Kernel.++([
        {DSPy.Evaluate.run(evaluator, program).score, program, current_instruction(program)}
      ])

    {best_score, best, _instruction} =
      Enum.max_by(results, fn {score, _candidate, _instruction} -> score end)

    best
    |> attach_optimizer_metadata(%{
      trainset_size: length(trainset),
      candidate_count: length(candidates)
    })
    |> DSPy.Teleprompt.Report.attach(
      DSPy.Teleprompt.Report.new(%{
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

  def put_instruction(%DSPy.Predict.Predict{signature: signature} = program, instruction) do
    DSPy.Predict.Predict.with_signature(program, %{signature | instructions: instruction})
  end

  def put_instruction(%DSPy.Predict.ChainOfThought{predict: predict} = program, instruction) do
    %{program | predict: put_instruction(predict, instruction)}
  end

  def put_instruction(program, _instruction), do: program

  def current_instruction(%DSPy.Predict.Predict{signature: signature}), do: signature.instructions

  def current_instruction(%DSPy.Predict.ChainOfThought{predict: predict}),
    do: current_instruction(predict)

  def current_instruction(_program), do: nil

  def candidate_instructions(program, trainset, opts \\ []) do
    base = current_instruction(program) || "Complete the task."
    labels = infer_labels(trainset)

    [
      base,
      base <> "\nBe concise and exact.",
      base <> "\nUse the demonstrations as ground truth patterns.",
      base <> "\nReturn only fields requested by the signature.",
      "Solve the task by matching inputs to outputs. Expected labels include: #{labels}."
    ] ++ Keyword.get(opts, :extra_instructions, [])
  end

  defp infer_labels(trainset) do
    trainset
    |> Enum.flat_map(fn example ->
      example |> DSPy.Example.labels() |> DSPy.Example.to_map() |> Map.keys()
    end)
    |> Enum.uniq()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")
  end

  defp maybe_put_demos(program, []), do: program

  defp maybe_put_demos(%DSPy.Predict.Predict{} = program, demos),
    do: DSPy.Predict.Predict.with_demos(program, demos)

  defp maybe_put_demos(%DSPy.Predict.ChainOfThought{predict: predict} = program, demos) do
    %{program | predict: DSPy.Predict.Predict.with_demos(predict, demos)}
  end

  defp maybe_put_demos(program, _demos), do: program

  defp attach_optimizer_metadata(%DSPy.Predict.Predict{} = program, metadata),
    do: %{program | metadata: Map.merge(program.metadata, metadata)}

  defp attach_optimizer_metadata(
         %DSPy.Predict.ChainOfThought{predict: predict} = program,
         metadata
       ) do
    %{program | predict: attach_optimizer_metadata(predict, metadata)}
  end

  defp attach_optimizer_metadata(program, _metadata), do: program
end

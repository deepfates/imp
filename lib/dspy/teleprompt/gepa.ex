defmodule DSPy.Teleprompt.GEPA do
  @moduledoc "Reflective prompt optimizer that turns feedback into instruction candidates."

  defstruct [:metric, feedback_fn: nil, generations: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      feedback_fn: Keyword.get(opts, :feedback_fn),
      generations: Keyword.get(opts, :generations, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    feedback =
      case optimizer.feedback_fn do
        nil -> default_feedback(trainset)
        fun when is_function(fun, 1) -> fun.(trainset)
      end

    base = DSPy.Teleprompt.InstructionSearch.candidate_instructions(program, trainset)

    candidates =
      (base ++
         Enum.map(1..optimizer.generations, fn index ->
           "#{feedback}\nReflection #{index}: repair likely mistakes before answering."
         end))
      |> Enum.take(length(base) + optimizer.generations)

    DSPy.Teleprompt.InstructionSearch.compile(
      program,
      optimizer.metric,
      trainset,
      devset,
      candidates
    )
  end

  defp default_feedback(trainset),
    do: "Use observed examples carefully. Training examples available: #{length(trainset)}."
end

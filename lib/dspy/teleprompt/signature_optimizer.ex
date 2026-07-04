defmodule DSPy.Teleprompt.SignatureOptimizer do
  @moduledoc "Optimizes only signature instructions, leaving demos unchanged."

  defstruct [:metric, candidates: []]

  def new(metric, opts \\ []),
    do: %__MODULE__{metric: metric, candidates: Keyword.get(opts, :candidates, [])}

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    candidates =
      case optimizer.candidates do
        [] -> DSPy.Teleprompt.InstructionSearch.candidate_instructions(program, trainset)
        values -> values
      end

    DSPy.Teleprompt.InstructionSearch.compile(
      program,
      optimizer.metric,
      trainset,
      devset,
      candidates
    )
  end
end

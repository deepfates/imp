defmodule DSEx.Optimizer.SignatureOptimizer do
  @moduledoc "Optimizes only signature instructions, leaving demos unchanged."

  defstruct [:metric, candidates: []]

  @option_schema [
    candidates: [type: {:list, :string}, default: []]
  ]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(
      metric,
      [2, 3],
      "DSEx.Optimizer.SignatureOptimizer.new/2",
      "metric"
    )

    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.SignatureOptimizer.new/2")

    %__MODULE__{metric: metric, candidates: opts[:candidates]}
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    candidates =
      case optimizer.candidates do
        [] -> DSEx.Optimizer.InstructionSearch.candidate_instructions(program, trainset)
        values -> values
      end

    DSEx.Optimizer.InstructionSearch.compile(
      program,
      optimizer.metric,
      trainset,
      devset,
      candidates
    )
  end
end

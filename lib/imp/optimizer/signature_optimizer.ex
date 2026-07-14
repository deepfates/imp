defmodule Imp.Optimizer.SignatureOptimizer do
  @behaviour Imp.Optimizer
  @moduledoc "Optimizes only signature instructions, leaving demos unchanged."

  defstruct [:metric, candidates: []]

  @option_schema [
    candidates: [type: {:list, :string}, default: []]
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(
      metric,
      [2, 3],
      "Imp.Optimizer.SignatureOptimizer.new/2",
      "metric"
    )

    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.SignatureOptimizer.new/2")

    %__MODULE__{metric: metric, candidates: opts[:candidates]}
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :required},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      {:ok,
       compile(
         optimizer,
         program,
         Imp.Optimizer.fetch_dataset!(opts, :trainset),
         Imp.Optimizer.fetch_dataset!(opts, :validation)
       )}
    end
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    candidates =
      case optimizer.candidates do
        [] -> Imp.Optimizer.InstructionSearch.candidate_instructions(program, trainset)
        values -> values
      end

    Imp.Optimizer.InstructionSearch.compile(
      program,
      optimizer.metric,
      trainset,
      devset,
      candidates
    )
  end
end

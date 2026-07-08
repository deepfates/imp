defmodule DSEx.Optimizer.SignatureOptimizer do
  @moduledoc "Optimizes only signature instructions, leaving demos unchanged."

  defstruct [:metric, candidates: []]

  @option_schema [
    candidates: [type: {:list, :string}, default: []]
  ]

  def new(metric, opts \\ []) do
    validate_metric!(metric)
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

  defp validate_metric!(metric) when is_function(metric, 2) or is_function(metric, 3), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Optimizer.SignatureOptimizer.new/2 expects a metric function with arity 2 or 3; got: #{inspect(metric)}"
  end
end

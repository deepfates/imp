defmodule DSPy.Teleprompt.COPRO do
  @moduledoc "Coordinate prompt optimizer over instruction candidates."

  defstruct [:metric, breadth: 5, depth: 2, extra_instructions: []]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      breadth: Keyword.get(opts, :breadth, 5),
      depth: Keyword.get(opts, :depth, 2),
      extra_instructions: Keyword.get(opts, :extra_instructions, [])
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    1..optimizer.depth
    |> Enum.reduce(program, fn _round, current ->
      candidates =
        current
        |> DSPy.Teleprompt.InstructionSearch.candidate_instructions(trainset,
          extra_instructions: optimizer.extra_instructions
        )
        |> Enum.take(optimizer.breadth)

      DSPy.Teleprompt.InstructionSearch.compile(
        current,
        optimizer.metric,
        trainset,
        devset,
        candidates
      )
    end)
  end
end

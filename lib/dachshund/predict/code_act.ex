defmodule Dachshund.Predict.CodeAct do
  @moduledoc "CodeAct-style module backed by the BEAM-safe `Dachshund.Sandbox`."

  @behaviour Dachshund.Module

  defstruct [:program_of_thought, tools: [], max_iters: 5]

  def new(signature, tools \\ [], opts \\ []) do
    %__MODULE__{
      program_of_thought: Dachshund.Predict.ProgramOfThought.new(signature, opts),
      tools: tools,
      max_iters: Keyword.get(opts, :max_iters, 5)
    }
  end

  @impl true
  def call(%__MODULE__{program_of_thought: pot}, inputs),
    do: Dachshund.Predict.ProgramOfThought.call(pot, inputs)
end

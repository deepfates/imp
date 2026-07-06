defmodule DSEx.Predict.CodeAct do
  @moduledoc "CodeAct-style module backed by the BEAM-safe `DSEx.Sandbox`."

  @behaviour DSEx.Module

  defstruct [:program_of_thought, tools: [], max_iters: 5]

  def new(signature, tools \\ [], opts \\ []) do
    %__MODULE__{
      program_of_thought: DSEx.Predict.ProgramOfThought.new(signature, opts),
      tools: tools,
      max_iters: Keyword.get(opts, :max_iters, 5)
    }
  end

  @impl true
  def call(%__MODULE__{program_of_thought: pot}, inputs),
    do: DSEx.Predict.ProgramOfThought.call(pot, inputs)
end

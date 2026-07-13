defmodule DSEx.Predict.RLM.Runtime do
  @moduledoc false

  @enforce_keys [:budget, :rlm, :inputs, :depth]
  defstruct [:budget, :rlm, :inputs, :depth]

  def new(program, budget, inputs, depth) do
    %__MODULE__{rlm: program, budget: budget, inputs: inputs, depth: depth}
  end

  def put_input(%__MODULE__{} = runtime, key, value) do
    %{runtime | inputs: Map.put(runtime.inputs, key, value)}
  end
end

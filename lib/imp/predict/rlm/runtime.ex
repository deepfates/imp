defmodule Imp.Predict.RLM.Runtime do
  @moduledoc false

  @enforce_keys [:budget, :rlm, :inputs, :depth]
  defstruct [:budget, :rlm, :inputs, :depth, child_traces: [], max_observed_depth: 0]

  def new(program, budget, inputs, depth) do
    %__MODULE__{
      rlm: program,
      budget: budget,
      inputs: inputs,
      depth: depth,
      max_observed_depth: depth
    }
  end

  def put_input(%__MODULE__{} = runtime, key, value) do
    %{runtime | inputs: Map.put(runtime.inputs, key, value)}
  end

  def observe_recursion(%__MODULE__{} = runtime, depth, trace \\ [], action \\ :recurse) do
    event = %{action: action, depth: depth, trace: trace}

    %{
      runtime
      | child_traces: [event | runtime.child_traces],
        max_observed_depth: max(runtime.max_observed_depth, depth)
    }
  end
end

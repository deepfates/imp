defmodule DSEx.Predict.ReAct do
  @moduledoc """
  Compatibility facade for the canonical `DSEx.Predict.ReActV2` tool loop.
  """

  @behaviour DSEx.Module

  defstruct [:react_v2]

  def new(signature, tools, opts \\ []) do
    %__MODULE__{react_v2: DSEx.Predict.ReActV2.new(signature, tools, opts)}
  end

  @impl true
  def call(%__MODULE__{react_v2: react_v2}, inputs),
    do: DSEx.Predict.ReActV2.call(react_v2, inputs)
end

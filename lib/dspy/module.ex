defmodule DSPy.Module do
  @moduledoc "Behaviour for executable DSPy programs."

  @callback call(struct(), map() | keyword()) :: {:ok, DSPy.Prediction.t()} | {:error, term()}
end

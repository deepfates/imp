defmodule DSEx.Module do
  @moduledoc "Behaviour for executable DSEx programs."

  @callback call(struct(), map() | keyword()) ::
              {:ok, DSEx.Prediction.t()} | {:error, term()}
end

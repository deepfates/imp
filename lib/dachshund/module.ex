defmodule Dachshund.Module do
  @moduledoc "Behaviour for executable Dachshund programs."

  @callback call(struct(), map() | keyword()) ::
              {:ok, Dachshund.Prediction.t()} | {:error, term()}
end

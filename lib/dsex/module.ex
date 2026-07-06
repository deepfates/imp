defmodule DSEx.Module do
  @moduledoc "Behaviour for executable DSEx programs."

  @callback call(struct(), map() | keyword()) ::
              {:ok, DSEx.Prediction.t()} | {:error, term()}

  def call(%module{} = program, inputs) do
    if function_exported?(module, :call, 2) do
      module.call(program, inputs)
    else
      {:error, {:not_callable, module}}
    end
  end

  def call(other, _inputs), do: {:error, {:not_callable, other}}
end

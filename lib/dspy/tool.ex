defmodule DSPy.Tool do
  @moduledoc "Tool definition for ReAct-style programs."

  defstruct [:name, :description, :run, schema: %{}]

  def new(name, description, run, opts \\ []) when is_function(run, 1) do
    %__MODULE__{
      name: normalize_name(name),
      description: description,
      run: run,
      schema: Keyword.get(opts, :schema, %{})
    }
  end

  def call(%__MODULE__{run: run}, arg), do: run.(arg)

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: String.to_atom(name)
end

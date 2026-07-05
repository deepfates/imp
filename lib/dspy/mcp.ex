defmodule DSPy.MCP do
  @moduledoc "MCP-style tool catalog importer."

  defmodule Catalog do
    @moduledoc "In-process MCP-like catalog used for tests and adapters."
    defstruct tools: []

    def new(tools), do: %__MODULE__{tools: tools}
    def list_tools(%__MODULE__{tools: tools}), do: tools
  end

  def import_tools(catalog) do
    catalog
    |> list_tools()
    |> Enum.map(&tool_from_schema/1)
  end

  defp list_tools(%{__struct__: module} = catalog) do
    cond do
      function_exported?(module, :list_tools, 1) -> module.list_tools(catalog)
      true -> Map.fetch!(catalog, :tools)
    end
  end

  defp list_tools(tools) when is_list(tools), do: tools

  defp tool_from_schema(%{
         name: name,
         description: description,
         input_schema: input_schema,
         run: run
       }) do
    DSPy.Tool.new(
      name,
      description,
      fn input ->
        with :ok <- validate_tool_input(input, input_schema) do
          run.(input)
        end
      end,
      schema: input_schema
    )
  end

  defp validate_tool_input(input, schema) do
    missing =
      schema
      |> Map.get(:required, [])
      |> Enum.reject(&Map.has_key?(input, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_required, keys}}
    end
  end
end

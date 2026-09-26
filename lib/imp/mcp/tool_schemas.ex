defmodule Imp.MCP.ToolSchemas do
  @moduledoc false

  # Converts the tool schemas an MCP server lists into `Imp.Tool` structs.
  # Schemas follow the MCP specification dialect: the input contract is the
  # camelCase `"inputSchema"` key (MCP spec, Tool definition) and
  # `"description"` is optional.

  @doc false
  # Tool schemas as a server lists them, each with the `run` function the
  # connection attached, become `Imp.Tool` structs.
  def to_tools!(schemas) do
    schemas
    |> validate_tool_list!()
    |> validate_tool_schemas!()
    |> validate_unique_names!()
    |> Enum.map(&tool_from_schema/1)
  end

  defp validate_tool_list!(tools) when is_list(tools), do: tools

  defp validate_tool_list!(other) do
    raise ArgumentError, "MCP tool schemas must be a list, got: #{inspect(other)}"
  end

  defp validate_tool_schemas!(tools) do
    Enum.map(tools, fn
      schema when is_map(schema) ->
        schema

      other ->
        raise ArgumentError, "MCP tool schema must be a map, got: #{inspect(other)}"
    end)
  end

  defp tool_from_schema(schema) when is_map(schema) do
    name = validate_tool_name!(fetch_required!(schema, :name))
    description = validate_description!(fetch_description(schema), name)
    input_schema = validate_input_schema!(fetch_input_schema!(schema, name), name)
    run = validate_run!(fetch_required!(schema, :run), name)

    Imp.Tool.new(name, description, run,
      schema: input_schema,
      metadata: Map.get(schema, "metadata", Map.get(schema, :metadata, %{}))
    )
  end

  defp validate_unique_names!(tools) do
    names = Enum.map(tools, &fetch_required!(&1, :name))
    duplicates = names -- Enum.uniq(names)

    case Enum.uniq(duplicates) do
      [] ->
        tools

      duplicate_names ->
        raise ArgumentError, "duplicate MCP tool names: #{inspect(duplicate_names)}"
    end
  end

  defp validate_tool_name!(name) when is_atom(name) or is_binary(name), do: name

  defp validate_tool_name!(name) do
    raise ArgumentError, "MCP tool name must be an atom or string, got: #{inspect(name)}"
  end

  # MCP spec, Tool definition: description is optional. The MCP reference SDK
  # types it Optional[str], so both an absent key and an explicit null mean
  # "no description". Imp normalizes both to "" because downstream consumers
  # (adapters, Imp.ProgramParameters) require string descriptions.
  defp fetch_description(schema) do
    case fetch_optional(schema, :description, :__missing__) do
      :__missing__ -> ""
      nil -> ""
      description -> description
    end
  end

  # MCP spec, Tool definition: the input contract key is camelCase
  # "inputSchema".
  defp fetch_input_schema!(schema, name) do
    case fetch_optional(schema, :inputSchema, :__missing__) do
      :__missing__ -> raise ArgumentError, "MCP tool #{inspect(name)} schema missing inputSchema"
      input_schema -> input_schema
    end
  end

  defp validate_description!(description, _name) when is_binary(description), do: description

  defp validate_description!(description, name) do
    raise ArgumentError,
          "MCP tool #{inspect(name)} description must be a string, got: #{inspect(description)}"
  end

  defp validate_input_schema!(schema, _name) when is_map(schema), do: schema

  defp validate_input_schema!(schema, name) do
    raise ArgumentError,
          "MCP tool #{inspect(name)} inputSchema must be a map, got: #{inspect(schema)}"
  end

  defp validate_run!(run, _name) when is_function(run, 1), do: run

  defp validate_run!(run, name) do
    raise ArgumentError,
          "MCP tool #{inspect(name)} run must be a one-argument function, got: #{inspect(run)}"
  end

  defp fetch_required!(map, key) do
    case fetch_optional(map, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "MCP tool schema missing #{key}"
      value -> value
    end
  end

  defp fetch_optional(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end

defmodule DSPy.MCP do
  @moduledoc """
  MCP-style tool catalog importer.

  `DSPy.MCP.import_tools/1` converts either an in-process catalog or a
  transport-backed HTTP catalog into ordinary `DSPy.Tool` values. Imported tools
  validate required fields and basic JSON-schema-style property constraints.
  """

  defmodule Catalog do
    @moduledoc "In-process MCP-like catalog used for tests and adapters."
    defstruct tools: []

    def new(tools), do: %__MODULE__{tools: tools}
    def list_tools(%__MODULE__{tools: tools}), do: tools
  end

  defmodule HTTPClient do
    @moduledoc "Transport-backed MCP-style catalog client."

    defstruct [
      :url,
      transport: DSPy.HTTP.Hackneyless,
      headers: [],
      body: %{"method" => "tools/list"}
    ]

    def new(url, opts \\ []) do
      %__MODULE__{
        url: url,
        transport: Keyword.get(opts, :transport, DSPy.HTTP.Hackneyless),
        headers: Keyword.get(opts, :headers, []),
        body: Keyword.get(opts, :body, %{"method" => "tools/list"})
      }
    end

    def list_tools(%__MODULE__{} = client) do
      headers = [{"content-type", "application/json"} | client.headers]

      with {:ok, %{status: status, body: body}} when status in 200..299 <-
             DSPy.HTTP.post(client.transport, client.url, headers, Jason.encode!(client.body), []),
           {:ok, decoded} <- Jason.decode(body),
           {:ok, tools} <- decode_tools(decoded) do
        Enum.map(tools, &attach_remote_run(client, &1))
      else
        {:ok, %{status: status, body: body}} ->
          raise ArgumentError, "MCP tools/list HTTP #{status}: #{body}"

        {:error, reason} ->
          raise ArgumentError, "MCP tools/list failed: #{inspect(reason)}"
      end
    end

    defp decode_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{"result" => %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{tools: tools}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{result: %{tools: tools}}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(other), do: {:error, {:missing_tools, other}}

    defp attach_remote_run(client, tool) do
      name = Map.get(tool, "name", Map.get(tool, :name))

      Map.put(tool, "run", fn arguments ->
        body = %{
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => arguments}
        }

        headers = [{"content-type", "application/json"} | client.headers]

        with {:ok, %{status: status, body: response}} when status in 200..299 <-
               DSPy.HTTP.post(client.transport, client.url, headers, Jason.encode!(body), []),
             {:ok, decoded} <- Jason.decode(response) do
          Map.get(decoded, "result", decoded)
        else
          {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  @doc "Imports a catalog or list of tool schemas into `DSPy.Tool` structs."
  def import_tools(catalog) do
    catalog
    |> list_tools()
    |> validate_unique_names!()
    |> Enum.map(&tool_from_schema/1)
  end

  defp list_tools(%{__struct__: module} = catalog) do
    cond do
      function_exported?(module, :list_tools, 1) -> module.list_tools(catalog)
      true -> Map.fetch!(catalog, :tools)
    end
  end

  defp list_tools(tools) when is_list(tools), do: tools

  defp tool_from_schema(schema) when is_map(schema) do
    name = fetch_required!(schema, :name)
    description = fetch_required!(schema, :description)
    input_schema = fetch_required!(schema, :input_schema)
    run = fetch_required!(schema, :run)

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

  defp validate_tool_input(input, schema) do
    with :ok <- validate_required(input, schema),
         :ok <- validate_properties(input, schema) do
      :ok
    end
  end

  defp validate_required(input, schema) do
    missing =
      schema
      |> fetch_optional(:required, [])
      |> Enum.reject(&present?(input, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_required, keys}}
    end
  end

  defp validate_properties(input, schema) do
    errors =
      schema
      |> fetch_optional(:properties, %{})
      |> Enum.flat_map(fn {name, property_schema} ->
        case fetch_input(input, name) do
          {:ok, value} -> validate_value(name, value, property_schema)
          :error -> []
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:schema_validation, errors}}
    end
  end

  defp validate_value(name, value, schema) do
    []
    |> validate_type(name, value, fetch_optional(schema, :type))
    |> validate_enum(name, value, fetch_optional(schema, :enum))
    |> validate_minimum(name, value, fetch_optional(schema, :minimum))
    |> validate_maximum(name, value, fetch_optional(schema, :maximum))
  end

  defp validate_type(errors, _name, _value, nil), do: errors

  defp validate_type(errors, name, value, type) do
    valid? =
      case type do
        "string" -> is_binary(value)
        :string -> is_binary(value)
        "integer" -> is_integer(value)
        :integer -> is_integer(value)
        "number" -> is_number(value)
        :number -> is_number(value)
        "boolean" -> is_boolean(value)
        :boolean -> is_boolean(value)
        "array" -> is_list(value)
        :array -> is_list(value)
        "object" -> is_map(value)
        :object -> is_map(value)
        _ -> true
      end

    if valid?,
      do: errors,
      else: errors ++ [%{field: name, rule: :type, message: "expected #{type}"}]
  end

  defp validate_enum(errors, _name, _value, nil), do: errors

  defp validate_enum(errors, name, value, allowed) do
    if value in allowed,
      do: errors,
      else: errors ++ [%{field: name, rule: :enum, message: "must be one of #{inspect(allowed)}"}]
  end

  defp validate_minimum(errors, _name, _value, nil), do: errors

  defp validate_minimum(errors, name, value, min) when is_number(value) and value < min,
    do: errors ++ [%{field: name, rule: :minimum, message: "must be >= #{min}"}]

  defp validate_minimum(errors, _name, _value, _min), do: errors

  defp validate_maximum(errors, _name, _value, nil), do: errors

  defp validate_maximum(errors, name, value, max) when is_number(value) and value > max,
    do: errors ++ [%{field: name, rule: :maximum, message: "must be <= #{max}"}]

  defp validate_maximum(errors, _name, _value, _max), do: errors

  defp fetch_required!(map, key) do
    case fetch_optional(map, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "MCP tool schema missing #{key}"
      value -> value
    end
  end

  defp fetch_optional(map, key, default \\ nil)

  defp fetch_optional(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_optional(map, key, default), do: Map.get(map, key, default)

  defp present?(input, key),
    do: match?({:ok, value} when not is_nil(value), fetch_input(input, key))

  defp fetch_input(input, key) when is_atom(key),
    do: Map.fetch(input, key) |> or_fetch(input, Atom.to_string(key))

  defp fetch_input(input, key) when is_binary(key) do
    case Map.fetch(input, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case existing_atom(key) do
          {:ok, atom} -> Map.fetch(input, atom)
          :error -> :error
        end
    end
  end

  defp or_fetch({:ok, value}, _input, _key), do: {:ok, value}
  defp or_fetch(:error, input, key), do: Map.fetch(input, key)

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end
end

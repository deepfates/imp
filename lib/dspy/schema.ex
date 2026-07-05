defmodule DSPy.Schema do
  @moduledoc "Schema constraints, validation, JSON Schema export, and retry feedback."

  def validate_fields(fields, values) do
    errors =
      fields
      |> Enum.flat_map(fn field ->
        value = fetch_value(values, field.name)
        validate_field(field, value)
      end)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate_field(field, value) do
    constraints =
      Map.get(field.metadata, :constraints, Map.get(field.metadata, "constraints", %{}))

    optional = Map.get(field.metadata, :optional, Map.get(field.metadata, "optional", false))

    cond do
      is_nil(value) and optional ->
        []

      is_nil(value) ->
        [%{field: field.name, rule: :required, message: "#{field.name} is required"}]

      true ->
        []
        |> validate_type(field, value)
        |> validate_enum(field, value, constraints)
        |> validate_number(field, value, constraints)
        |> validate_string(field, value, constraints)
        |> validate_array(field, value, constraints)
        |> validate_object(field, value, constraints)
    end
  end

  def retry_feedback(errors) do
    errors
    |> Enum.map(fn error -> "- #{error.field}: #{error.message}" end)
    |> then(&(["Validation failed. Retry with corrected output:"] ++ &1))
    |> Enum.join("\n")
  end

  def json_schema(fields) do
    properties =
      Map.new(fields, fn field -> {to_string(field.name), field_schema(field)} end)

    required =
      fields
      |> Enum.reject(&(Map.get(&1.metadata, :optional) || Map.get(&1.metadata, "optional")))
      |> Enum.map(&to_string(&1.name))

    %{"type" => "object", "properties" => properties, "required" => required}
  end

  defp validate_type(errors, field, value) do
    valid? =
      case field.type do
        :string -> is_binary(value)
        :integer -> is_integer(value)
        :float -> is_float(value) or is_integer(value)
        :number -> is_number(value)
        :boolean -> is_boolean(value)
        :array -> is_list(value)
        :object -> is_map(value)
        _ -> true
      end

    if valid?, do: errors, else: errors ++ [error(field, :type, "expected #{field.type}")]
  end

  defp validate_enum(errors, field, value, %{enum: allowed}),
    do:
      if(value in allowed,
        do: errors,
        else: errors ++ [error(field, :enum, "must be one of #{inspect(allowed)}")]
      )

  defp validate_enum(errors, _field, _value, _constraints), do: errors

  defp validate_number(errors, field, value, constraints) when is_number(value) do
    errors
    |> maybe_min(field, value, constraints)
    |> maybe_max(field, value, constraints)
  end

  defp validate_number(errors, _field, _value, _constraints), do: errors

  defp validate_string(errors, field, value, constraints) when is_binary(value) do
    errors
    |> maybe_min_length(field, value, constraints)
    |> maybe_max_length(field, value, constraints)
    |> maybe_pattern(field, value, constraints)
  end

  defp validate_string(errors, _field, _value, _constraints), do: errors

  defp validate_array(errors, field, value, %{items: item_schema}) when is_list(value) do
    item_errors =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        pseudo = %{
          field
          | name: "#{field.name}[#{index}]",
            type: Map.get(item_schema, :type, :any),
            metadata: %{constraints: Map.delete(item_schema, :type)}
        }

        validate_field(pseudo, item)
      end)

    errors ++ item_errors
  end

  defp validate_array(errors, _field, _value, _constraints), do: errors

  defp validate_object(errors, field, value, %{properties: properties}) when is_map(value) do
    nested =
      Enum.flat_map(properties, fn {name, spec} ->
        pseudo = %{
          field
          | name: "#{field.name}.#{name}",
            type: Map.get(spec, :type, :any),
            metadata: %{
              constraints: Map.delete(spec, :type),
              optional: Map.get(spec, :optional, false)
            }
        }

        validate_field(pseudo, fetch_value(value, name))
      end)

    errors ++ nested
  end

  defp validate_object(errors, _field, _value, _constraints), do: errors

  defp maybe_min(errors, field, value, %{min: min}) when value < min,
    do: errors ++ [error(field, :min, "must be >= #{min}")]

  defp maybe_min(errors, _field, _value, _constraints), do: errors

  defp maybe_max(errors, field, value, %{max: max}) when value > max,
    do: errors ++ [error(field, :max, "must be <= #{max}")]

  defp maybe_max(errors, _field, _value, _constraints), do: errors

  defp maybe_min_length(errors, field, value, %{min_length: min}) when byte_size(value) < min,
    do: errors ++ [error(field, :min_length, "length must be >= #{min}")]

  defp maybe_min_length(errors, _field, _value, _constraints), do: errors

  defp maybe_max_length(errors, field, value, %{max_length: max}) when byte_size(value) > max,
    do: errors ++ [error(field, :max_length, "length must be <= #{max}")]

  defp maybe_max_length(errors, _field, _value, _constraints), do: errors

  defp maybe_pattern(errors, field, value, %{pattern: pattern}) do
    if Regex.match?(Regex.compile!(pattern), value),
      do: errors,
      else: errors ++ [error(field, :pattern, "must match #{pattern}")]
  end

  defp maybe_pattern(errors, _field, _value, _constraints), do: errors

  defp field_schema(field) do
    constraints =
      Map.get(field.metadata, :constraints, Map.get(field.metadata, "constraints", %{}))

    %{"type" => json_type(field.type)}
    |> maybe_put("enum", Map.get(constraints, :enum))
    |> maybe_put("minimum", Map.get(constraints, :min))
    |> maybe_put("maximum", Map.get(constraints, :max))
    |> maybe_put("minLength", Map.get(constraints, :min_length))
    |> maybe_put("maxLength", Map.get(constraints, :max_length))
    |> maybe_put("pattern", Map.get(constraints, :pattern))
    |> maybe_put("items", json_nested(Map.get(constraints, :items)))
    |> maybe_put("properties", json_properties(Map.get(constraints, :properties)))
  end

  defp json_nested(nil), do: nil
  defp json_nested(spec), do: %{"type" => json_type(Map.get(spec, :type, :string))}

  defp json_properties(nil), do: nil

  defp json_properties(properties) do
    Map.new(properties, fn {name, spec} ->
      {to_string(name), %{"type" => json_type(Map.get(spec, :type, :string))}}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp json_type(:integer), do: "integer"
  defp json_type(:float), do: "number"
  defp json_type(:number), do: "number"
  defp json_type(:boolean), do: "boolean"
  defp json_type(:array), do: "array"
  defp json_type(:object), do: "object"
  defp json_type(_), do: "string"

  defp error(field, rule, message), do: %{field: field.name, rule: rule, message: message}

  defp fetch_value(values, key) do
    case Map.fetch(values, key) do
      {:ok, value} -> value
      :error -> Map.get(values, to_string(key))
    end
  end
end

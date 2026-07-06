defmodule DSEx.Schema do
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
      field.metadata
      |> fetch_meta(:constraints, %{})
      |> normalize_constraints()

    optional = fetch_meta(field.metadata, :optional, false)

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
    item_schema = normalize_constraints(item_schema)

    item_errors =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        pseudo = %{
          field
          | name: "#{field.name}[#{index}]",
            type: fetch_meta(item_schema, :type, :any),
            metadata: %{constraints: delete_meta(item_schema, :type)}
        }

        validate_field(pseudo, item)
      end)

    errors ++ item_errors
  end

  defp validate_array(errors, _field, _value, _constraints), do: errors

  defp validate_object(errors, field, value, %{properties: properties}) when is_map(value) do
    nested =
      Enum.flat_map(properties, fn {name, spec} ->
        spec = normalize_constraints(spec)

        pseudo = %{
          field
          | name: "#{field.name}.#{name}",
            type: fetch_meta(spec, :type, :any),
            metadata: %{
              constraints: delete_meta(spec, :type),
              optional: fetch_meta(spec, :optional, false)
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
      field.metadata
      |> fetch_meta(:constraints, %{})
      |> normalize_constraints()

    %{"type" => json_type(field.type)}
    |> maybe_put("enum", fetch_meta(constraints, :enum))
    |> maybe_put("minimum", fetch_meta(constraints, :min))
    |> maybe_put("maximum", fetch_meta(constraints, :max))
    |> maybe_put("minLength", fetch_meta(constraints, :min_length))
    |> maybe_put("maxLength", fetch_meta(constraints, :max_length))
    |> maybe_put("pattern", fetch_meta(constraints, :pattern))
    |> maybe_put("items", json_nested(fetch_meta(constraints, :items)))
    |> maybe_put("properties", json_properties(fetch_meta(constraints, :properties)))
  end

  defp json_nested(nil), do: nil

  defp json_nested(spec) do
    spec = normalize_constraints(spec)
    %{"type" => json_type(fetch_meta(spec, :type, :string))}
  end

  defp json_properties(nil), do: nil

  defp json_properties(properties) do
    Map.new(properties, fn {name, spec} ->
      spec = normalize_constraints(spec)
      {to_string(name), %{"type" => json_type(fetch_meta(spec, :type, :string))}}
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
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(values, to_string(key)) do
          {:ok, value} -> value
          :error -> fetch_existing_atom(values, key)
        end
    end
  end

  defp fetch_existing_atom(values, key) do
    atom = String.to_existing_atom(to_string(key))
    Map.get(values, atom)
  rescue
    ArgumentError -> nil
  end

  defp fetch_meta(map, key, default \\ nil)

  defp fetch_meta(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_meta(map, key, default), do: Map.get(map, key, default)

  defp delete_meta(map, key) when is_atom(key),
    do: map |> Map.delete(key) |> Map.delete(Atom.to_string(key))

  defp normalize_constraints(%{} = constraints) do
    Map.new(constraints, fn {key, value} ->
      {normalize_constraint_key(key), normalize_constraint_value(value)}
    end)
  end

  defp normalize_constraints(other), do: other

  defp normalize_constraint_value(%{} = value), do: normalize_constraints(value)

  defp normalize_constraint_value(values) when is_list(values),
    do: Enum.map(values, &normalize_constraint_value/1)

  defp normalize_constraint_value(value), do: value

  defp normalize_constraint_key(key) when is_atom(key), do: key
  defp normalize_constraint_key("minLength"), do: :min_length
  defp normalize_constraint_key("maxLength"), do: :max_length

  defp normalize_constraint_key(key)
       when key in ["enum", "min", "max", "items", "properties", "type", "optional", "pattern"],
       do: String.to_existing_atom(key)

  defp normalize_constraint_key(key), do: key
end

defmodule Imp.Schema do
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

    optional = Imp.Adapter.OutputFields.optional?(field)
    nil_default? = Imp.Adapter.OutputFields.fetch_default(field) == {:ok, nil}

    cond do
      is_nil(value) and (optional or nil_default?) ->
        []

      is_nil(value) ->
        [%{field: field.name, rule: :required, message: "#{field.name} is required"}]

      true ->
        []
        |> validate_type(field, value)
        |> validate_union(field, value, constraints)
        |> validate_enum(field, value, constraints)
        |> validate_answer_shape(field, value, constraints)
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
      |> Enum.filter(&Imp.Adapter.OutputFields.required?/1)
      |> Enum.map(&to_string(&1.name))

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp validate_type(errors, field, value) do
    valid? =
      case field.type do
        :string ->
          is_binary(value)

        :integer ->
          is_integer(value)

        :float ->
          is_float(value) or is_integer(value)

        :number ->
          is_number(value)

        :boolean ->
          is_boolean(value)

        :array ->
          is_list(value)

        :object ->
          is_map(value)

        :datetime ->
          match?(%DateTime{}, value) or match?(%NaiveDateTime{}, value)

        :code ->
          match?(%Imp.Adapter.Types.Code{code: code} when is_binary(code), value)

        :reasoning ->
          match?(%Imp.Adapter.Types.Reasoning{text: text} when is_binary(text), value)

        "reasoning" ->
          match?(%Imp.Adapter.Types.Reasoning{text: text} when is_binary(text), value)

        :union ->
          true

        "union" ->
          true

        :null ->
          is_nil(value)

        "null" ->
          is_nil(value)

        "code" ->
          match?(%Imp.Adapter.Types.Code{code: code} when is_binary(code), value)

        _ ->
          true
      end

    if valid?, do: errors, else: errors ++ [error(field, :type, "expected #{field.type}")]
  end

  defp validate_union(errors, field, value, %{any_of: branches}) when is_list(branches) do
    valid? =
      Enum.any?(branches, fn branch ->
        branch = normalize_constraints(branch)

        pseudo = %{
          field
          | type: nested_type(branch, :any),
            metadata: %{
              constraints: delete_meta(branch, :type),
              optional: fetch_meta(branch, :optional, false)
            }
        }

        validate_field(pseudo, value) == []
      end)

    if valid?,
      do: errors,
      else: errors ++ [error(field, :union, "did not match any allowed type")]
  end

  defp validate_union(errors, _field, _value, _constraints), do: errors

  defp validate_enum(errors, field, value, %{enum: allowed}),
    do:
      if(value in allowed,
        do: errors,
        else: errors ++ [error(field, :enum, "must be one of #{inspect(allowed)}")]
      )

  defp validate_enum(errors, _field, _value, _constraints), do: errors

  defp validate_answer_shape(errors, field, value, %{answer_shape: shape})
       when is_binary(value) do
    shape = normalize_answer_shape(shape)

    if valid_answer_shape?(shape, value),
      do: errors,
      else: errors ++ [error(field, :answer_shape, answer_shape_message(shape))]
  end

  defp validate_answer_shape(errors, _field, _value, _constraints), do: errors

  defp validate_number(errors, field, value, constraints) when is_number(value) do
    errors
    |> maybe_min(field, value, constraints)
    |> maybe_max(field, value, constraints)
    |> maybe_gt(field, value, constraints)
    |> maybe_lt(field, value, constraints)
    |> maybe_multiple_of(field, value, constraints)
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
            type: nested_type(item_schema, :any),
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
            type: nested_type(spec, :any),
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

  defp maybe_gt(errors, field, value, %{gt: min}) when value <= min,
    do: errors ++ [error(field, :gt, "must be > #{min}")]

  defp maybe_gt(errors, _field, _value, _constraints), do: errors

  defp maybe_lt(errors, field, value, %{lt: max}) when value >= max,
    do: errors ++ [error(field, :lt, "must be < #{max}")]

  defp maybe_lt(errors, _field, _value, _constraints), do: errors

  defp maybe_multiple_of(errors, field, value, %{multiple_of: divisor})
       when is_number(divisor) and divisor != 0 do
    remainder = :math.fmod(value * 1.0, divisor * 1.0)

    if remainder == 0.0 do
      errors
    else
      errors ++ [error(field, :multiple_of, "must be a multiple of #{divisor}")]
    end
  end

  defp maybe_multiple_of(errors, _field, _value, _constraints), do: errors

  defp maybe_min_length(errors, field, value, %{min_length: min}) when byte_size(value) < min,
    do: errors ++ [error(field, :min_length, "length must be >= #{min}")]

  defp maybe_min_length(errors, _field, _value, _constraints), do: errors

  defp maybe_max_length(errors, field, value, %{max_length: max}) when byte_size(value) > max,
    do: errors ++ [error(field, :max_length, "length must be <= #{max}")]

  defp maybe_max_length(errors, _field, _value, _constraints), do: errors

  defp maybe_pattern(errors, field, value, %{pattern: pattern}) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, value),
          do: errors,
          else: errors ++ [error(field, :pattern, "must match #{pattern}")]

      {:error, {reason, _at}} ->
        errors ++
          [error(field, :pattern, "has invalid regex pattern #{inspect(pattern)}: #{reason}")]
    end
  end

  defp maybe_pattern(errors, _field, _value, _constraints), do: errors

  defp field_schema(field) do
    constraints =
      field.metadata
      |> fetch_meta(:constraints, %{})
      |> normalize_constraints()

    base_schema(field.type, constraints)
    |> maybe_put_default(field)
    |> maybe_put("enum", fetch_meta(constraints, :enum))
    |> maybe_put("x-imp-answerShape", fetch_meta(constraints, :answer_shape))
    |> maybe_put("minimum", fetch_meta(constraints, :min))
    |> maybe_put("maximum", fetch_meta(constraints, :max))
    |> maybe_put("minLength", fetch_meta(constraints, :min_length))
    |> maybe_put("maxLength", fetch_meta(constraints, :max_length))
    |> maybe_put("pattern", fetch_meta(constraints, :pattern))
    |> maybe_put("items", json_nested(fetch_meta(constraints, :items)))
    |> put_object_contract(fetch_meta(constraints, :properties))
    |> maybe_nullable(field)
    |> maybe_put_description(field)
  end

  # The field's own words about itself, at the top level of the property schema
  # so they survive the nullable `anyOf` wrapping. A provider reads this schema
  # as a tool's parameters (ReActV2's `submit`), and a host that replaces the
  # adapter's rendered system section has no other place where a field
  # description reaches the model.
  defp maybe_put_description(schema, field) do
    case field.desc do
      desc when is_binary(desc) ->
        if String.trim(desc) == "", do: schema, else: Map.put(schema, "description", desc)

      _no_desc ->
        schema
    end
  end

  defp maybe_nullable(schema, field) do
    if Imp.Adapter.OutputFields.optional?(field),
      do: %{"anyOf" => [schema, %{"type" => "null"}]},
      else: schema
  end

  defp maybe_put_default(schema, field) do
    case Imp.Adapter.OutputFields.fetch_default(field) do
      {:ok, default} -> Map.put(schema, "default", default)
      :error -> schema
    end
  end

  defp json_nested(nil), do: nil

  defp json_nested(spec) do
    spec = normalize_constraints(spec)

    spec =
      spec
      |> fetch_meta(:constraints, %{})
      |> normalize_constraints()
      |> Map.merge(delete_meta(spec, :constraints))

    base_schema(nested_type(spec, :string), spec)
    |> maybe_put("enum", fetch_meta(spec, :enum))
    |> maybe_put("x-imp-answerShape", fetch_meta(spec, :answer_shape))
    |> maybe_put("minimum", fetch_meta(spec, :min))
    |> maybe_put("maximum", fetch_meta(spec, :max))
    |> maybe_put("minLength", fetch_meta(spec, :min_length))
    |> maybe_put("maxLength", fetch_meta(spec, :max_length))
    |> maybe_put("pattern", fetch_meta(spec, :pattern))
    |> maybe_put("items", json_nested(fetch_meta(spec, :items)))
    |> put_object_contract(fetch_meta(spec, :properties))
  end

  defp base_schema(type, constraints) when type in [:union, "union"] do
    branches =
      constraints
      |> fetch_meta(:any_of, [])
      |> Enum.map(&json_nested/1)

    %{"anyOf" => branches}
  end

  defp base_schema(type, _constraints), do: %{"type" => json_type(type)}

  defp json_properties(nil), do: nil

  defp json_properties(properties) do
    Map.new(properties, fn {name, spec} ->
      {to_string(name), json_nested(spec)}
    end)
  end

  defp put_object_contract(schema, nil), do: schema

  defp put_object_contract(schema, properties) do
    required =
      properties
      |> Enum.reject(fn {_name, spec} ->
        spec = normalize_constraints(spec)
        fetch_meta(spec, :optional, false)
      end)
      |> Enum.map(fn {name, _spec} -> to_string(name) end)
      |> Enum.sort()

    schema
    |> Map.put("properties", json_properties(properties))
    |> Map.put("required", required)
    |> Map.put("additionalProperties", false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Datetimes travel the wire as ISO 8601 strings (JSON has no datetime type);
  # the chat adapter parses them back into DateTime/NaiveDateTime structs.
  defp json_type(:datetime), do: "string"
  defp json_type("datetime"), do: "string"
  defp json_type(:integer), do: "integer"
  defp json_type(:float), do: "number"
  defp json_type(:number), do: "number"
  defp json_type(:boolean), do: "boolean"
  defp json_type(:array), do: "array"
  defp json_type(:object), do: "object"
  defp json_type("integer"), do: "integer"
  defp json_type("float"), do: "number"
  defp json_type("number"), do: "number"
  defp json_type("boolean"), do: "boolean"
  defp json_type("array"), do: "array"
  defp json_type("object"), do: "object"
  defp json_type("string"), do: "string"
  defp json_type(:null), do: "null"
  defp json_type("null"), do: "null"
  defp json_type(_), do: "string"

  defp nested_type(spec, default) do
    case fetch_meta(spec, :type, default) do
      "integer" -> :integer
      "int" -> :integer
      "float" -> :float
      "number" -> :number
      "boolean" -> :boolean
      "bool" -> :boolean
      "array" -> :array
      "object" -> :object
      "string" -> :string
      "str" -> :string
      "datetime" -> :datetime
      "union" -> :union
      "null" -> :null
      type -> type
    end
  end

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

  defp normalize_constraint_key(:answerShape), do: :answer_shape
  # The pydantic spellings ge/le are Imp's inclusive :min/:max (dspy field.py
  # PYDANTIC_CONSTRAINT_MAP; rendered by Imp.Adapter.FieldConstraints).
  defp normalize_constraint_key(:ge), do: :min
  defp normalize_constraint_key(:le), do: :max
  defp normalize_constraint_key(key) when is_atom(key), do: key
  defp normalize_constraint_key("minLength"), do: :min_length
  defp normalize_constraint_key("maxLength"), do: :max_length
  defp normalize_constraint_key("answerShape"), do: :answer_shape
  defp normalize_constraint_key("anyOf"), do: :any_of
  defp normalize_constraint_key("additionalProperties"), do: :additional_properties
  defp normalize_constraint_key("ge"), do: :min
  defp normalize_constraint_key("le"), do: :max

  defp normalize_constraint_key(key)
       when key in [
              "enum",
              "min",
              "max",
              "gt",
              "lt",
              "multiple_of",
              "allow_inf_nan",
              "any_of",
              "additional_properties",
              "items",
              "properties",
              "type",
              "optional",
              "pattern",
              "answer_shape"
            ],
       do: String.to_existing_atom(key)

  defp normalize_constraint_key(key), do: key

  defp normalize_answer_shape(shape) when is_atom(shape), do: shape

  defp normalize_answer_shape(shape) when is_binary(shape) do
    shape
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> shape
  end

  defp valid_answer_shape?(:yes_no, value) do
    value
    |> Imp.Metrics.normalize_text()
    |> Kernel.in(["yes", "no"])
  end

  defp valid_answer_shape?(:numeric_span, value) do
    value
    |> String.trim()
    |> String.match?(~r/^-?\$?\d[\d,]*(?:\.\d+)?%?$/)
  end

  defp valid_answer_shape?(:short_span, value) do
    normalized = Imp.Metrics.normalize_text(value)
    tokens = String.split(normalized)

    normalized != "" and length(tokens) <= 12 and not String.contains?(value, ["\n", ";"])
  end

  defp valid_answer_shape?(_shape, _value), do: true

  defp answer_shape_message(:yes_no), do: "must be exactly yes or no"

  defp answer_shape_message(:numeric_span),
    do: "must be only the numeric answer span, with no words or explanation"

  defp answer_shape_message(:short_span),
    do: "must be a concise exact answer span"

  defp answer_shape_message(shape), do: "must satisfy answer shape #{inspect(shape)}"
end

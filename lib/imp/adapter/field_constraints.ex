defmodule Imp.Adapter.FieldConstraints do
  @moduledoc false

  # DSPy 3.2.1 turns pydantic Field constraints into a human-readable string at
  # field construction (dspy/signatures/field.py: PYDANTIC_CONSTRAINT_MAP +
  # _translate_pydantic_field_constraints, joined with ", ") and every adapter's
  # get_field_description_string (dspy/adapters/utils.py:238-240) appends
  # "\nConstraints: <string>" to that field's description line. Imp keeps
  # constraints as machine data on `field.metadata.constraints` (validated by
  # Imp.Schema); this module renders the SAME text from the machine form so the
  # prompt bytes match upstream. (de-hzcv gap #4)
  #
  # Ordering: upstream renders in Python kwarg order, which a map cannot carry;
  # we render in PYDANTIC_CONSTRAINT_MAP declaration order (gt, ge, lt, le,
  # min_length, max_length, multiple_of, allow_inf_nan) — the order both
  # upstream fidelity tests write their kwargs in. Imp's :min/:max are the
  # inclusive bounds, i.e. pydantic ge/le, and render with those phrases.

  @phrases [
    {:gt, "greater than: "},
    {:min, "greater than or equal to: "},
    {:lt, "less than: "},
    {:max, "less than or equal to: "},
    {:min_length, "minimum length: "},
    {:max_length, "maximum length: "},
    {:multiple_of, "a multiple of the given number: "},
    {:allow_inf_nan, "allow 'inf', '-inf', 'nan' values: "}
  ]

  @doc """
  The upstream `json_schema_extra["constraints"]` string for a field, or `nil`
  when the field carries none of the eight pydantic constraint keys.
  """
  def description(field) do
    constraints =
      field.metadata
      |> fetch(:constraints)
      |> normalize()

    parts =
      for {key, phrase} <- @phrases,
          value = Map.get(constraints, key),
          value != nil,
          do: phrase <> py_str(value)

    case parts do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  @doc """
  The `"\\nConstraints: ..."` suffix `get_field_description_string` appends to a
  field's description line, or `""` when the field has no rendered constraints.
  """
  def suffix(field) do
    case description(field) do
      nil -> ""
      description -> "\nConstraints: " <> description
    end
  end

  defp fetch(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp fetch(_map, _key), do: nil

  defp normalize(%{} = constraints) do
    Map.new(constraints, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize(_other), do: %{}

  # The pydantic spellings ge/le are Imp's inclusive :min/:max; minLength /
  # maxLength are the JSON-schema spellings Imp.Schema already accepts.
  defp normalize_key(:ge), do: :min
  defp normalize_key(:le), do: :max
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("ge"), do: :min
  defp normalize_key("le"), do: :max
  defp normalize_key("minLength"), do: :min_length
  defp normalize_key("maxLength"), do: :max_length

  defp normalize_key(key)
       when key in ~w(gt lt min max min_length max_length multiple_of allow_inf_nan),
       do: String.to_existing_atom(key)

  defp normalize_key(key), do: key

  # Python f"{value}" as _translate_pydantic_field_constraints applies it.
  defp py_str(true), do: "True"
  defp py_str(false), do: "False"
  defp py_str(value) when is_float(value), do: Imp.PyFloat.repr(value)
  defp py_str(value), do: to_string(value)
end

defmodule Imp.Adapter.OutputFields do
  @moduledoc "Internal output fallback/completeness logic shared by adapters."

  # DSPy 3.3.1 `apply_output_field_defaults/2`: present values win by key
  # presence; otherwise use a declared default, then nil for a nullable field.
  def complete(signature, present) when is_map(present) do
    {completed, missing} =
      Enum.reduce(signature.outputs, {%{}, []}, fn field, {completed, missing} ->
        case fetch_present(present, field.name) do
          {:ok, value} ->
            {Map.put(completed, field.name, value), missing}

          :error ->
            case fetch_default(field) do
              {:ok, default} ->
                {Map.put(completed, field.name, default), missing}

              :error ->
                if optional?(field),
                  do: {Map.put(completed, field.name, nil), missing},
                  else: {completed, missing ++ [field.name]}
            end
        end
      end)

    if missing == [], do: {:ok, completed}, else: {:error, {:missing_output_fields, missing}}
  end

  def optional?(field),
    do: Map.get(field.metadata, :optional, Map.get(field.metadata, "optional", false)) == true

  def fetch_default(field) do
    case Map.fetch(field.metadata, :default) do
      {:ok, default} -> {:ok, default}
      :error -> Map.fetch(field.metadata, "default")
    end
  end

  def required?(field), do: not optional?(field) and fetch_default(field) == :error

  defp fetch_present(values, name) do
    case Map.fetch(values, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(values, to_string(name))
    end
  end
end

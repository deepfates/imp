defmodule DSEx.FieldSelector do
  @moduledoc false

  @name_error "expected an atom/string field name"
  @selector_error "expected an atom/string field name or a non-empty list of field names"
  @optional_name_error "expected nil or an atom/string field name"

  def validate_name(value) do
    if field_name?(value) do
      {:ok, value}
    else
      {:error, "#{@name_error}, got: #{inspect(value)}"}
    end
  end

  def validate_optional_name(nil), do: {:ok, nil}

  def validate_optional_name(value) do
    if field_name?(value) do
      {:ok, value}
    else
      {:error, "#{@optional_name_error}, got: #{inspect(value)}"}
    end
  end

  def validate_selector([_ | _] = values) do
    if Enum.all?(values, &field_name?/1) do
      {:ok, values}
    else
      {:error, "#{@selector_error}, got: #{inspect(values)}"}
    end
  end

  def validate_selector(value) do
    if field_name?(value) do
      {:ok, value}
    else
      {:error, "#{@selector_error}, got: #{inspect(value)}"}
    end
  end

  defp field_name?(value) when is_atom(value), do: not is_boolean(value) and not is_nil(value)

  defp field_name?(value) when is_binary(value), do: String.trim(value) != ""

  defp field_name?(_value), do: false
end

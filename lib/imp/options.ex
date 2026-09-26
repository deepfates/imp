defmodule Imp.Options do
  @moduledoc """
  Internal. Validates keyword options against a NimbleOptions schema and
  re-raises failures as `ArgumentError` with the caller's context prefixed,
  so error messages name the public entry point (for example
  `Imp.Tool.new/4`) rather than the validation library.
  """

  def validate!(opts, schema, context) when is_list(opts) do
    NimbleOptions.validate!(opts, schema)
  rescue
    error in NimbleOptions.ValidationError ->
      reraise ArgumentError, [message: "#{context}: #{message(error)}"], __STACKTRACE__
  end

  def validate!(opts, _schema, context) do
    raise ArgumentError, "#{context}: expected keyword options, got #{shape(opts)}"
  end

  @doc false
  # The kind of a value, for an error that must not print it.
  def shape(value) when is_map(value), do: "a map"
  def shape(value) when is_list(value), do: "a list"
  def shape(value) when is_binary(value), do: "a string"
  def shape(value) when is_tuple(value), do: "a tuple"
  def shape(value) when is_atom(value), do: "an atom"
  def shape(value) when is_number(value), do: "a number"
  def shape(value) when is_function(value), do: "a function"
  def shape(_value), do: "an unsupported value"

  # NimbleOptions prints the offending value. For an option that can hold a
  # credential (a key, a token, headers) the error names the option only.
  defp message(%NimbleOptions.ValidationError{key: key} = error) do
    if sensitive?(key),
      do:
        "invalid value for #{inspect(key)} option (#{shape(error.value)}; the value is not shown)",
      else: Exception.message(error)
  end

  defp sensitive?(key),
    do: key in [:headers, :auth, :authorization] or Imp.Redaction.credential_key?(key)
end

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
      reraise ArgumentError, [message: "#{context}: #{Exception.message(error)}"], __STACKTRACE__
  end

  def validate!(opts, _schema, context) do
    raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
  end
end

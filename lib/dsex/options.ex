defmodule DSEx.Options do
  @moduledoc false

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

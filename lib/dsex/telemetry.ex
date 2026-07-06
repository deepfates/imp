defmodule DSEx.Telemetry do
  @moduledoc "Small telemetry boundary for LM calls."

  def execute(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    case Process.get(:dsex_telemetry_handler) do
      fun when is_function(fun, 3) -> fun.(event, measurements, metadata)
      _other -> :ok
    end

    :ok
  end
end

defmodule Imp.Observability.StageRecorder do
  @moduledoc false

  @doc false
  def persist_then_validate!(path, stage, validator)
      when is_binary(path) and is_function(validator, 1) do
    write_atomic!(path, Jason.encode!(stage, pretty: true) <> "\n")
    validator.(stage)
    stage
  end

  def persist_then_validate!(path, _stage, validator) do
    raise ArgumentError,
          "stage recorder expects a path and arity-one validator, got: #{inspect({path, validator})}"
  end

  defp write_atomic!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    io = File.open!(temporary, [:write, :binary, :exclusive])

    try do
      :ok = IO.binwrite(io, contents)
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    try do
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end
end

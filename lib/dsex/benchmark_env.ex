defmodule DSEx.BenchmarkEnv do
  @moduledoc false

  def load_files!(paths) do
    paths
    |> values_from_files!()
    |> Enum.each(fn {key, value} -> System.put_env(key, value) end)
  end

  def values_from_files!(paths) do
    Enum.flat_map(paths, fn path ->
      if File.exists?(path) do
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.flat_map(&parse_line/1)
      else
        raise ArgumentError, "env file not found: #{path}"
      end
    end)
  end

  defp parse_line(line) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        []

      true ->
        line
        |> String.trim_leading("export ")
        |> String.split("=", parts: 2)
        |> case do
          [key, value] when key != "" -> [{key, unquote_value(value)}]
          _ -> []
        end
    end
  end

  defp unquote_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end
end

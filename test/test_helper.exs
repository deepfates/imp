defmodule Imp.Test.EnvLoader do
  @moduledoc false

  def load(path \\ ".env") do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(&put_env/1)
    end

    :ok
  end

  defp put_env(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] when key != "" ->
        System.put_env(String.trim(key), clean(value))

      _ ->
        :ok
    end
  end

  defp clean(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end
end

Imp.Test.EnvLoader.load()

external_excludes =
  [
    {"LIVE_PROVIDER", :live},
    {"PROTOCOL_TRAINING", :protocol_training},
    {"PROTOCOL_RETRIEVER", :protocol_retriever},
    {"PROTOCOL_MCP", :protocol_mcp}
  ]
  |> Enum.reject(fn {env, _tag} -> System.get_env(env) in ["1", "true", "TRUE", "yes"] end)
  |> Enum.map(fn {_env, tag} -> {tag, true} end)

ExUnit.configure(exclude: external_excludes)

ExUnit.start()

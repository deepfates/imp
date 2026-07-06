defmodule DSEx.Test.EnvLoader do
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

DSEx.Test.EnvLoader.load()

unless System.get_env("LIVE_PROVIDER") in ["1", "true", "TRUE", "yes"] do
  ExUnit.configure(exclude: [live: true])
end

ExUnit.start()

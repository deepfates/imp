defmodule DSEx.Test.Mode do
  @moduledoc false

  def mode do
    case System.get_env("DSEX_TEST_MODE", "live") |> String.downcase() do
      "live" -> :live
      "fallback" -> :fallback
      "mock" -> :mock
      other -> raise ArgumentError, "unsupported DSEX_TEST_MODE: #{inspect(other)}"
    end
  end
end

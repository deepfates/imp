defmodule Imp.Test.Mode do
  @moduledoc false

  def mode do
    case System.get_env("IMP_TEST_MODE", "live") |> String.downcase() do
      "live" -> :live
      "fallback" -> :fallback
      "mock" -> :mock
      other -> raise ArgumentError, "unsupported IMP_TEST_MODE: #{inspect(other)}"
    end
  end
end

defmodule DSEx.TestMode do
  @moduledoc """
  Runtime provider test mode.

  `DSEX_TEST_MODE=mock` keeps provider-contract tests deterministic.
  `fallback` attempts the real provider when credentials exist and otherwise
  uses the mock response. `live` always uses the configured transport.
  """

  def mode do
    case System.get_env("DSEX_TEST_MODE", "live") |> String.downcase() do
      "live" -> :live
      "fallback" -> :fallback
      "mock" -> :mock
      other -> raise ArgumentError, "unsupported DSEX_TEST_MODE: #{inspect(other)}"
    end
  end

  def explicit?(opts), do: Keyword.has_key?(opts, :test_mode)

  def mode(opts), do: Keyword.get(opts, :test_mode, mode())

  def mock_content(_lm, _messages, opts) do
    Keyword.get(opts, :mock_response, "Answer: mock")
  end
end

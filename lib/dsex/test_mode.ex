defmodule DSEx.TestMode do
  @moduledoc """
  Runtime provider test mode.

  `DSEX_TEST_MODE=mock` keeps provider-contract tests deterministic.
  `fallback` attempts the real provider when credentials exist and otherwise
  uses the mock response. `live` always uses the configured transport.
  """

  def mode do
    default = if System.get_env("LIVE_PROVIDER") == "1", do: "live", else: "mock"

    case System.get_env("DSEX_TEST_MODE", default) |> String.downcase() do
      "live" -> :live
      "fallback" -> :fallback
      "mock" -> :mock
      _other -> :mock
    end
  end

  def explicit?(opts), do: Keyword.has_key?(opts, :test_mode)

  def mode(opts), do: Keyword.get(opts, :test_mode, mode())

  def mock_content(_lm, _messages, opts) do
    Keyword.get(opts, :mock_response, "Answer: mock")
  end
end

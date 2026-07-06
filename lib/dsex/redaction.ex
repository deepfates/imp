defmodule DSEx.Redaction do
  @moduledoc "Shared redaction helpers for traces and runtime metadata."

  @default_redact_keys [
    :api_key,
    :authorization,
    :token,
    :password,
    :secret,
    :access_token,
    :client_secret,
    :private_key,
    :"x-api-key"
  ]

  def default_keys, do: @default_redact_keys

  def redact(value, keys \\ @default_redact_keys)

  def redact(value, keys) when is_struct(value) do
    value
    |> Map.from_struct()
    |> redact(keys)
  end

  def redact(value, keys) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if redacted_key?(key, keys), do: {key, "[REDACTED]"}, else: {key, redact(nested, keys)}
    end)
  end

  def redact(value, keys) when is_list(value), do: Enum.map(value, &redact(&1, keys))

  def redact(value, _keys) when is_binary(value) do
    if secret_value?(value), do: "[REDACTED]", else: value
  end

  def redact(value, _keys), do: value

  defp redacted_key?(key, keys) do
    normalized = key |> to_string() |> String.downcase() |> String.replace("-", "_")

    Enum.any?(keys, fn redact_key ->
      redact_key = redact_key |> to_string() |> String.downcase() |> String.replace("-", "_")

      normalized == redact_key or
        String.ends_with?(normalized, "_#{redact_key}") or
        String.contains?(normalized, redact_key)
    end)
  end

  defp secret_value?(value) do
    String.match?(value, ~r/\bsk-[A-Za-z0-9_-]{8,}\b/) or
      String.match?(value, ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{12,}\b/i) or
      String.match?(value, ~r/\b[A-Fa-f0-9]{32,}\b/) or
      String.match?(value, ~r/\b[A-Za-z0-9+\/_-]{40,}={0,2}\b/)
  end
end

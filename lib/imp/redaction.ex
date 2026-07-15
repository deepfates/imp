defmodule Imp.Redaction do
  @moduledoc """
  Shared redaction helpers for traces, telemetry, and runtime metadata.

  Imp keeps prompts, tool inputs, provider metadata, and optimizer reports
  inspectable, but credentials and credential-shaped strings must not leak into
  those artifacts. `redact/2` walks ordinary Elixir maps, lists, tuples, and structs,
  replacing known secret fields and secret-looking string values with
  `"[REDACTED]"`.
  """

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

  @doc """
  Returns the default key names treated as sensitive.

      iex> :api_key in Imp.Redaction.default_keys()
      true

      iex> :"x-api-key" in Imp.Redaction.default_keys()
      true

  """
  def default_keys, do: @default_redact_keys

  @doc """
  Validates custom redaction keys.

  Redaction keys must be atoms or strings because Imp compares them with map
  keys after normalizing ordinary Elixir key names.

      iex> Imp.Redaction.validate_keys([:api_key, "authorization"])
      {:ok, [:api_key, "authorization"]}

      iex> {:error, message} = Imp.Redaction.validate_keys([:api_key, 123])
      iex> message =~ "expected a list of atom or string key names"
      true

  """
  def validate_keys(keys) when is_list(keys) do
    case Enum.find(keys, &(not valid_key?(&1))) do
      nil ->
        {:ok, keys}

      invalid ->
        {:error,
         "expected a list of atom or string key names, got invalid key: #{inspect(invalid)}"}
    end
  end

  def validate_keys(keys) do
    {:error, "expected a list of atom or string key names, got: #{inspect(keys)}"}
  end

  @doc """
  Redacts sensitive keys and secret-looking string values.

  Key matching is intentionally conservative around common credential names:
  exact keys, hyphen/underscore variants, suffixes, and containing names such as
  `:openai_api_key` are redacted.

      iex> Imp.Redaction.redact(%{api_key: "sk-test-secret-1234567890", model: "demo"})
      %{api_key: "[REDACTED]", model: "demo"}

      iex> Imp.Redaction.redact(%{nested: [%{"authorization" => "Bearer abcdefghijklmnop"}]})
      %{nested: [%{"authorization" => "[REDACTED]"}]}

      iex> Imp.Redaction.redact("sk-test-secret-1234567890")
      "[REDACTED]"

      iex> Imp.Redaction.redact(%{tenant_id: "public"}, [:tenant_id])
      %{tenant_id: "[REDACTED]"}

      iex> Imp.Redaction.redact({:error, "Bearer abcdefghijklmnop"})
      {:error, "[REDACTED]"}

  """
  def redact(value, keys \\ @default_redact_keys)

  def redact(%Imp.Adapters.Types.Image{} = image, keys) do
    %{image | metadata: redact(image.metadata, keys)}
  end

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

  def redact(value, keys) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact(&1, keys))
    |> List.to_tuple()
  end

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

  defp valid_key?(key), do: is_atom(key) or is_binary(key)

  defp secret_value?(value) do
    String.match?(value, ~r/\bsk-[A-Za-z0-9_-]{8,}\b/) or
      String.match?(value, ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{12,}\b/i) or
      String.match?(value, ~r/\b[A-Fa-f0-9]{32,}\b/) or
      String.match?(value, ~r/\b[A-Za-z0-9+\/_-]{40,}={0,2}\b/)
  end
end

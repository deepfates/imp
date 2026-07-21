defmodule Imp.BenchmarkTruth.OptimizeAnything.PricingPolicy do
  @moduledoc false

  @openai_pricing_url "https://developers.openai.com/api/docs/pricing"

  @profiles %{
    "openai-gpt-5.4-standard-2026-03-05" => %{
      provider: "openai",
      model: "gpt-5.4-2026-03-05",
      pricing: %{"input_per_million" => 2.50, "output_per_million" => 15.00},
      source_url: @openai_pricing_url
    },
    "openai-gpt-5.4-mini-standard-2026-03-17" => %{
      provider: "openai",
      model: "gpt-5.4-mini-2026-03-17",
      pricing: %{"input_per_million" => 0.75, "output_per_million" => 4.50},
      source_url: @openai_pricing_url
    }
  }

  @credential_marker ~r/(?:api[_-]?key|authorization|proxy[_-]?authorization|bearer(?:[_-]?token)?|access[_-]?token|refresh[_-]?token|id[_-]?token|session(?:[_-]?token)?|secret(?:[_-]?(?:access[_-]?key|key))?|client[_-]?secret|private[_-]?(?:key|token)|password|credential(?:s)?)/i
  @secret_shape ~r/(?:sk-(?:proj-)?[A-Za-z0-9_-]{12,}|AKIA[0-9A-Z]{12,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/

  @doc false
  def profile!(provider, model, profile) do
    case Map.fetch(@profiles, profile) do
      {:ok, %{provider: ^provider, model: ^model} = policy} ->
        Map.put(policy, :profile, profile)

      {:ok, policy} ->
        raise ArgumentError,
              "pricing profile #{profile} requires provider #{policy.provider} and model #{policy.model}"

      :error ->
        raise ArgumentError, "unknown pricing profile #{inspect(profile)}"
    end
  end

  @doc false
  def custom!(provider, model, pricing, source_url) do
    unless nonempty_string?(provider) and nonempty_string?(model) and valid_pricing?(pricing) do
      raise ArgumentError,
            "custom pricing requires provider, model, and positive finite input/output rates"
    end

    validate_source_url!(source_url)

    %{
      profile: "custom",
      provider: provider,
      model: model,
      pricing: pricing,
      source_url: source_url
    }
  end

  @doc false
  def resolve!(provider, model, profile, pricing, source_url) do
    policy =
      case profile do
        "custom" -> custom!(provider, model, pricing, source_url)
        profile when is_binary(profile) -> profile!(provider, model, profile)
        _ -> raise ArgumentError, "pricing_profile must be a known profile or custom"
      end

    unless policy.pricing == pricing and policy.source_url == source_url do
      raise ArgumentError,
            "pricing profile #{profile} does not match its exact rates and authority URL"
    end

    policy
  end

  @doc false
  def valid?(provider, model, profile, pricing, source_url) do
    resolve!(provider, model, profile, pricing, source_url)
    true
  rescue
    ArgumentError -> false
  end

  @doc false
  def validate_source_url!(url) when is_binary(url) do
    uri = URI.parse(url)

    valid? =
      url == String.trim(url) and not String.contains?(url, ["\\", "\0", "\r", "\n"]) and
        uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
        is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
        ordinary_port?(uri.port) and
        Enum.all?([uri.host, uri.path], &credential_free_component?/1)

    unless valid? do
      raise ArgumentError,
            "campaign pricing source_url must be an ordinary credential-free HTTP(S) documentation URL"
    end

    url
  end

  def validate_source_url!(_url) do
    raise ArgumentError,
          "campaign pricing source_url must be an ordinary credential-free HTTP(S) documentation URL"
  end

  defp credential_free_component?(nil), do: true

  defp credential_free_component?(component) when is_binary(component) do
    case decoded_forms(component) do
      {:ok, forms} ->
        Enum.all?(forms, fn decoded ->
          Imp.Redaction.redact(decoded) == decoded and
            not Regex.match?(@credential_marker, decoded) and
            not Regex.match?(@secret_shape, decoded)
        end)

      :error ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp decoded_forms(component), do: decode_component(component, [component], 0)

  defp decode_component(_current, _forms, 8), do: :error

  defp decode_component(current, forms, depth) do
    decoded = current |> URI.decode() |> URI.decode_www_form()

    cond do
      decoded == current -> {:ok, forms}
      decoded in forms -> :error
      true -> decode_component(decoded, [decoded | forms], depth + 1)
    end
  end

  defp ordinary_port?(nil), do: true
  defp ordinary_port?(port), do: is_integer(port) and port in 1..65_535

  defp valid_pricing?(%{"input_per_million" => input, "output_per_million" => output} = pricing),
    do:
      Enum.sort(Map.keys(pricing)) == ~w(input_per_million output_per_million) and
        finite_positive?(input) and finite_positive?(output)

  defp valid_pricing?(_pricing), do: false

  defp finite_positive?(value) when is_number(value),
    do: value > 0 and match?({:ok, _}, Jason.encode(value))

  defp finite_positive?(_value), do: false

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
end

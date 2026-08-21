defmodule Imp.Test.LiveProvider do
  @moduledoc false

  def lm(opts \\ []) when is_list(opts) do
    %{provider: provider, model: model, api_key: api_key} = config!()
    opts = normalize_token_limit(opts, provider)

    Imp.req_llm(
      "#{provider}:#{model}",
      Keyword.merge([api_key: api_key, temperature: 0, cache: false, max_retries: 0], opts)
    )
  end

  def config! do
    provider = configured_provider()
    {provider, key_env, model_env} = provider_environment!(provider)
    api_key = System.get_env(key_env)
    model = System.get_env("IMP_LIVE_MODEL") || System.get_env(model_env)

    unless is_binary(api_key) and byte_size(api_key) > 0,
      do: raise("#{key_env} must be configured for the live provider gate")

    unless is_binary(model) and byte_size(model) > 0,
      do: raise("IMP_LIVE_MODEL or #{model_env} must be configured for the live provider gate")

    %{provider: provider, model: model, api_key: api_key}
  end

  defp configured_provider do
    case System.get_env("IMP_LIVE_PROVIDER") do
      provider when is_binary(provider) and provider != "" -> String.downcase(provider)
      _missing -> first_configured_provider()
    end
  end

  defp first_configured_provider do
    [
      {"openai", "OPENAI_API_KEY"},
      {"anthropic", "ANTHROPIC_API_KEY"},
      {"gemini", "GEMINI_API_KEY"},
      {"openrouter", "OPENROUTER_API_KEY"}
    ]
    |> Enum.find_value(fn {provider, key_env} ->
      case System.get_env(key_env) do
        key when is_binary(key) and key != "" -> provider
        _missing -> nil
      end
    end)
    |> case do
      nil ->
        raise(
          "configure IMP_LIVE_PROVIDER and its API key, or set one of " <>
            "OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, or OPENROUTER_API_KEY"
        )

      provider ->
        provider
    end
  end

  defp provider_environment!("openai"), do: {"openai", "OPENAI_API_KEY", "OPENAI_MODEL"}

  defp provider_environment!("anthropic"),
    do: {"anthropic", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL"}

  defp provider_environment!(provider) when provider in ["gemini", "google"],
    do: {"gemini", "GEMINI_API_KEY", "GEMINI_MODEL"}

  defp provider_environment!("openrouter"),
    do: {"openrouter", "OPENROUTER_API_KEY", "OPENROUTER_MODEL"}

  defp provider_environment!(provider),
    do: raise("unsupported IMP_LIVE_PROVIDER #{inspect(provider)}")

  defp normalize_token_limit(opts, "openai"), do: opts

  defp normalize_token_limit(opts, _provider) do
    case Keyword.pop(opts, :max_completion_tokens) do
      {nil, opts} -> opts
      {limit, opts} -> Keyword.put(opts, :max_tokens, limit)
    end
  end
end

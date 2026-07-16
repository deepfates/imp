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
    provider = System.get_env("IMP_LIVE_PROVIDER", "openai") |> String.downcase()
    {provider, key_env, model_env} = provider_environment!(provider)
    api_key = System.get_env(key_env)
    model = System.get_env("IMP_LIVE_MODEL") || System.get_env(model_env)

    unless is_binary(api_key) and byte_size(api_key) > 0,
      do: raise("#{key_env} must be configured for the live provider gate")

    unless is_binary(model) and byte_size(model) > 0,
      do: raise("IMP_LIVE_MODEL or #{model_env} must be configured for the live provider gate")

    %{provider: provider, model: model, api_key: api_key}
  end

  defp provider_environment!("openai"), do: {"openai", "OPENAI_API_KEY", "OPENAI_MODEL"}

  defp provider_environment!("anthropic"),
    do: {"anthropic", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL"}

  defp provider_environment!(provider) when provider in ["gemini", "google"],
    do: {"gemini", "GEMINI_API_KEY", "GEMINI_MODEL"}

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

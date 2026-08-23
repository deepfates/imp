defmodule Imp.Capabilities do
  @moduledoc """
  Runtime capability checks for provider features that cannot be inferred safely.

  Token logprob support is determined from the response metadata. The current
  ReqLLM integration supports OpenAI Chat Completions responses with a nonempty
  logprob list. OpenAI Responses, Anthropic, Google/Gemini, and responses without
  logprob metadata return an explicit unsupported reason.
  """

  @type unavailable_reason ::
          :missing_provider_metadata
          | :missing_logprobs
          | :openai_responses_unsupported
          | :anthropic_unsupported
          | :gemini_unsupported
          | :provider_unsupported
          | :api_unsupported

  @doc "Checks whether metadata proves token logprob support for this response."
  @spec token_logprobs(map()) :: :ok | {:error, unavailable_reason()}
  def token_logprobs(metadata) when is_map(metadata) do
    req_llm = map_value(metadata, :req_llm) || metadata
    provider = req_llm |> map_value(:provider) |> normalize()
    api = req_llm |> map_value(:api) |> normalize()
    logprobs = map_value(req_llm, :logprobs)

    cond do
      provider in [nil, ""] -> {:error, :missing_provider_metadata}
      provider == "anthropic" -> {:error, :anthropic_unsupported}
      provider in ["google", "google_vertex", "gemini"] -> {:error, :gemini_unsupported}
      provider == "openai" and api == "responses" -> {:error, :openai_responses_unsupported}
      provider != "openai" -> {:error, :provider_unsupported}
      api not in ["chat", "chat_completions"] -> {:error, :api_unsupported}
      not is_list(logprobs) or logprobs == [] -> {:error, :missing_logprobs}
      true -> :ok
    end
  end

  def token_logprobs(_metadata), do: {:error, :missing_provider_metadata}

  defp normalize(nil), do: nil
  defp normalize(value), do: value |> to_string() |> String.downcase()

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

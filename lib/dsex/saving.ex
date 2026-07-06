defmodule DSEx.Saving do
  @moduledoc "JSON save/load helpers for portable program state."

  def save!(program, path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(dump(program), pretty: true))
    :ok
  end

  def load!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> load()
  end

  def dump(%DSEx.Predict.Predict{} = program),
    do: Map.put(DSEx.Predict.Predict.dump(program), "type", "predict")

  def dump(%DSEx.Predict.ChainOfThought{predict: predict}) do
    predict |> dump() |> Map.put("type", "chain_of_thought")
  end

  def load(
        %{
          "type" => "predict",
          "signature" => signature,
          "demos" => demos,
          "config" => config,
          "metadata" => metadata
        } = state
      ) do
    DSEx.Predict.Predict.new(DSEx.Signature.load(signature),
      demos: Enum.map(demos, &DSEx.Example.new/1),
      config: decode_config(config),
      metadata: metadata,
      adapter: decode_adapter(Map.get(state, "adapter")),
      lm: decode_lm(Map.get(state, "lm"))
    )
  end

  def load(%{"type" => "chain_of_thought"} = state) do
    predict = state |> Map.put("type", "predict") |> load()
    %DSEx.Predict.ChainOfThought{predict: predict}
  end

  def load(%{"type" => type}) do
    raise ArgumentError, "unsupported saved DSEx program type: #{inspect(type)}"
  end

  defp decode_config(config) when is_list(config) do
    Enum.map(config, fn
      {k, v} -> {decode_config_key(k), v}
      [k, v] -> {decode_config_key(k), v}
    end)
  end

  defp decode_config(config) when is_map(config),
    do: Enum.map(config, fn {k, v} -> {decode_config_key(k), v} end)

  defp decode_adapter(nil), do: DSEx.Adapter.Chat
  defp decode_adapter(name) when is_binary(name), do: String.to_existing_atom(name)

  defp decode_lm(nil), do: nil

  defp decode_lm(%{"provider" => provider, "model" => model} = state) do
    provider = decode_provider(provider)

    DSEx.Clients.HTTPLM.new(model,
      api_key: nil,
      provider: provider,
      base_url: state["base_url"],
      path: state["path"],
      opts: decode_config(Map.get(state, "opts", []))
    )
  end

  defp decode_config_key(key) when is_atom(key), do: key

  defp decode_config_key(key) do
    case to_string(key) do
      "temperature" -> :temperature
      "max_tokens" -> :max_tokens
      "top_p" -> :top_p
      "stop" -> :stop
      "response_format" -> :response_format
      "tools" -> :tools
      "tool_choice" -> :tool_choice
      "stream" -> :stream
      "timeout" -> :timeout
      "retries" -> :retries
      "retry_backoff_ms" -> :retry_backoff_ms
      other -> other
    end
  end

  defp decode_provider(provider) when provider in [:openai, :litellm, :local, :databricks],
    do: provider

  defp decode_provider(provider) do
    case to_string(provider) do
      "openai" -> :openai
      "litellm" -> :litellm
      "local" -> :local
      "databricks" -> :databricks
      other -> raise ArgumentError, "unsupported saved DSEx provider: #{inspect(other)}"
    end
  end
end

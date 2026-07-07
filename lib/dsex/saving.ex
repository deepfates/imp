defmodule DSEx.Saving do
  @moduledoc """
  JSON save/load helpers for portable program state.

  Saved programs are treated as an external trust boundary. Loading validates the
  artifact shape, allowlists adapters and provider clients, and never restores
  credentials from disk.
  """

  @predict_required_keys ["type", "signature", "demos", "config", "metadata"]

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

  def load(%{"type" => "predict"} = state) do
    require_keys!(state, @predict_required_keys)
    signature = Map.fetch!(state, "signature")
    demos = require_list!(state, "demos")
    config = Map.fetch!(state, "config")
    metadata = require_map!(state, "metadata")

    opts =
      [
        demos: Enum.map(demos, &load_demo!/1),
        config: decode_config(config),
        metadata: metadata
      ]
      |> maybe_put_adapter(state)
      |> maybe_put_lm(state)

    DSEx.Predict.Predict.new(DSEx.Signature.load(signature), opts)
  end

  def load(%{"type" => "chain_of_thought"} = state) do
    predict = state |> Map.put("type", "predict") |> load()
    %DSEx.Predict.ChainOfThought{predict: predict}
  end

  def load(%{"type" => type}) do
    raise ArgumentError, "unsupported saved DSEx program type: #{inspect(type)}"
  end

  def load(state) when is_map(state) do
    raise ArgumentError, "saved DSEx program is missing required key \"type\""
  end

  def load(state) do
    raise ArgumentError, "saved DSEx program must be a map, got: #{inspect(state)}"
  end

  defp maybe_put_adapter(opts, %{"dynamic_adapter" => true}), do: opts

  defp maybe_put_adapter(opts, state) do
    Keyword.put(opts, :adapter, decode_adapter(Map.get(state, "adapter")))
  end

  defp maybe_put_lm(opts, %{"dynamic_lm" => true}), do: opts

  defp maybe_put_lm(opts, state) do
    case decode_lm(Map.get(state, "lm")) do
      nil -> opts
      lm -> Keyword.put(opts, :lm, lm)
    end
  end

  defp decode_config(config) when is_list(config) do
    Enum.map(config, fn
      {k, v} -> {decode_config_key(k), v}
      [k, v] -> {decode_config_key(k), v}
      other -> raise ArgumentError, "invalid saved DSEx config entry: #{inspect(other)}"
    end)
  end

  defp decode_config(config) when is_map(config),
    do: Enum.map(config, fn {k, v} -> {decode_config_key(k), v} end)

  defp decode_config(config) do
    raise ArgumentError, "saved DSEx config must be a map or list, got: #{inspect(config)}"
  end

  defp decode_adapter(nil), do: DSEx.Adapter.Chat

  defp decode_adapter(name) when is_binary(name) do
    case name do
      "Elixir.DSEx.Adapter.Chat" -> DSEx.Adapter.Chat
      "Elixir.DSEx.Adapter.JSON" -> DSEx.Adapter.JSON
      "Elixir.DSEx.Adapter.XML" -> DSEx.Adapter.XML
      "Elixir.DSEx.Adapter.TwoStep" -> DSEx.Adapter.TwoStep
      other -> raise ArgumentError, "unsupported saved DSEx adapter: #{inspect(other)}"
    end
  end

  defp decode_lm(nil), do: nil

  defp decode_lm(%{provider: :req_llm, model: model} = state) do
    DSEx.Clients.ReqLLM.new(model, opts: decode_config(Map.get(state, :opts, [])))
  end

  defp decode_lm(%{"provider" => "req_llm", "model" => model} = state) do
    DSEx.Clients.ReqLLM.new(model, opts: decode_config(Map.get(state, "opts", [])))
  end

  defp decode_lm(%{"provider" => :req_llm, "model" => model} = state) do
    DSEx.Clients.ReqLLM.new(model, opts: decode_config(Map.get(state, "opts", [])))
  end

  defp decode_lm(%{"provider" => provider}) do
    raise ArgumentError,
          "unsupported saved DSEx provider: #{inspect(provider)}; saved provider clients must use req_llm"
  end

  defp decode_lm(%{provider: provider}) do
    raise ArgumentError,
          "unsupported saved DSEx provider: #{inspect(provider)}; saved provider clients must use req_llm"
  end

  defp decode_lm(lm) do
    raise ArgumentError, "invalid saved DSEx LM client: #{inspect(lm)}"
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
      "num_retries" -> :num_retries
      "retry_backoff_ms" -> :retry_backoff_ms
      "max_completion_tokens" -> :max_completion_tokens
      "receive_timeout" -> :receive_timeout
      "provider_options" -> :provider_options
      other -> other
    end
  end

  defp require_keys!(state, keys) do
    missing = Enum.reject(keys, &Map.has_key?(state, &1))

    case missing do
      [] ->
        :ok

      _ ->
        raise ArgumentError,
              "saved DSEx #{Map.get(state, "type", "program")} is missing required keys: #{inspect(missing)}"
    end
  end

  defp require_list!(state, key) do
    case Map.fetch!(state, key) do
      value when is_list(value) -> value
      value -> raise ArgumentError, "saved DSEx #{key} must be a list, got: #{inspect(value)}"
    end
  end

  defp require_map!(state, key) do
    case Map.fetch!(state, key) do
      value when is_map(value) -> value
      value -> raise ArgumentError, "saved DSEx #{key} must be a map, got: #{inspect(value)}"
    end
  end

  defp load_demo!(demo) when is_map(demo) or is_list(demo), do: DSEx.Example.new(demo)

  defp load_demo!(demo) do
    raise ArgumentError, "saved DSEx demo must be a map or keyword list, got: #{inspect(demo)}"
  end
end

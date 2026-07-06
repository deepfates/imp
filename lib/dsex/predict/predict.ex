defmodule DSEx.Predict.Predict do
  @moduledoc "Basic DSEx module that maps signature inputs to outputs with an LM."

  @behaviour DSEx.Module

  defstruct [
    :signature,
    :lm,
    :adapter,
    demos: [],
    config: [],
    traces: [],
    metadata: %{},
    dynamic_lm?: true,
    dynamic_adapter?: true
  ]

  def new(signature, opts \\ []) do
    %__MODULE__{
      signature: DSEx.Signature.ensure(signature),
      lm: Keyword.get(opts, :lm),
      adapter: Keyword.get(opts, :adapter),
      demos: Keyword.get(opts, :demos, []),
      config: Keyword.get(opts, :config, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      dynamic_lm?: not Keyword.has_key?(opts, :lm),
      dynamic_adapter?: not Keyword.has_key?(opts, :adapter)
    }
  end

  @impl true
  def call(%__MODULE__{} = predict, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, lm} <- require_lm(resolve_lm(predict)),
         adapter <- resolve_adapter(predict),
         inputs <- Map.new(inputs),
         messages <- adapter.format(predict.signature, inputs, demos: predict.demos),
         lm_opts <- adapter_lm_opts(adapter, predict.signature, predict.config),
         {:ok, raw} <- DSEx.LM.generate(lm, messages, lm_opts),
         {:ok, prediction} <-
           parse_with_retry(adapter, predict.signature, raw, messages, lm, lm_opts) do
      {:ok, add_trace(prediction, messages, raw)}
    end
  end

  def with_demos(%__MODULE__{} = predict, demos), do: %{predict | demos: List.wrap(demos)}
  def with_lm(%__MODULE__{} = predict, lm), do: %{predict | lm: lm, dynamic_lm?: false}

  def with_signature(%__MODULE__{} = predict, signature),
    do: %{predict | signature: DSEx.Signature.ensure(signature)}

  def dump(%__MODULE__{} = predict) do
    %{
      "signature" => DSEx.Signature.dump(predict.signature),
      "demos" => Enum.map(predict.demos, &DSEx.Example.to_map/1),
      "config" => encode_keyword(predict.config),
      "metadata" => predict.metadata,
      "adapter" => predict |> resolve_adapter() |> Atom.to_string(),
      "lm" => dump_lm(predict.lm)
    }
  end

  defp dump_lm(%DSEx.Clients.HTTPLM{} = lm), do: DSEx.Clients.HTTPLM.dump(lm)
  defp dump_lm(_lm), do: nil

  defp encode_keyword(values) when is_list(values),
    do: Enum.map(values, fn {k, v} -> [Atom.to_string(k), v] end)

  defp encode_keyword(values), do: values

  defp require_lm(nil), do: {:error, :lm_not_configured}
  defp require_lm(lm), do: {:ok, lm}

  defp adapter_lm_opts(adapter, signature, config) do
    if function_exported?(adapter, :lm_opts, 2) do
      Keyword.merge(config, adapter.lm_opts(signature, config))
    else
      config
    end
  end

  defp parse_with_retry(adapter, signature, raw, messages, lm, opts) do
    case adapter.parse(signature, raw, []) do
      {:ok, prediction} ->
        {:ok, prediction}

      {:error, %DSEx.AdapterParseError{} = error} ->
        if Keyword.get(opts, :json_retries, 0) > 0 do
          retry_messages = messages ++ [%{role: :user, content: error.message}]
          retry_opts = Keyword.update!(opts, :json_retries, &(&1 - 1))

          with {:ok, raw} <- DSEx.LM.generate(lm, retry_messages, retry_opts) do
            adapter.parse(signature, raw, [])
          end
        else
          {:error, error}
        end

      error ->
        error
    end
  end

  defp resolve_lm(%__MODULE__{dynamic_lm?: true}), do: DSEx.Settings.get().lm
  defp resolve_lm(%__MODULE__{lm: lm}), do: lm

  defp resolve_adapter(%__MODULE__{dynamic_adapter?: true}), do: DSEx.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: nil}), do: DSEx.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: adapter}), do: adapter

  defp add_trace(%DSEx.Prediction{} = prediction, messages, raw) do
    metadata = Map.put(prediction.metadata, :trace, %{messages: messages, raw: raw})
    %{prediction | metadata: metadata}
  end
end

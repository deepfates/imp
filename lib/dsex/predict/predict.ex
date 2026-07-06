defmodule DSEx.Predict.Predict do
  @moduledoc "Basic DSEx module that maps signature inputs to outputs with an LM."

  @behaviour DSEx.Module

  defstruct [:signature, :lm, :adapter, demos: [], config: [], traces: [], metadata: %{}]

  def new(signature, opts \\ []) do
    settings = DSEx.Settings.get()

    %__MODULE__{
      signature: DSEx.Signature.ensure(signature),
      lm: Keyword.get(opts, :lm, settings.lm),
      adapter: Keyword.get(opts, :adapter, settings.adapter),
      demos: Keyword.get(opts, :demos, []),
      config: Keyword.get(opts, :config, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl true
  def call(%__MODULE__{} = predict, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, lm} <- require_lm(predict.lm),
         inputs <- Map.new(inputs),
         messages <- predict.adapter.format(predict.signature, inputs, demos: predict.demos),
         {:ok, raw} <- DSEx.LM.generate(lm, messages, predict.config),
         {:ok, prediction} <- predict.adapter.parse(predict.signature, raw, []) do
      {:ok, add_trace(prediction, messages, raw)}
    end
  end

  def with_demos(%__MODULE__{} = predict, demos), do: %{predict | demos: List.wrap(demos)}
  def with_lm(%__MODULE__{} = predict, lm), do: %{predict | lm: lm}

  def with_signature(%__MODULE__{} = predict, signature),
    do: %{predict | signature: DSEx.Signature.ensure(signature)}

  def dump(%__MODULE__{} = predict) do
    %{
      "signature" => DSEx.Signature.dump(predict.signature),
      "demos" => Enum.map(predict.demos, &DSEx.Example.to_map/1),
      "config" => encode_keyword(predict.config),
      "metadata" => predict.metadata,
      "adapter" => Atom.to_string(predict.adapter),
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

  defp add_trace(%DSEx.Prediction{} = prediction, messages, raw) do
    metadata = Map.put(prediction.metadata, :trace, %{messages: messages, raw: raw})
    %{prediction | metadata: metadata}
  end
end

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
         :ok <- validate_inputs(predict.signature, inputs),
         messages <- adapter.format(predict.signature, inputs, demos: predict.demos),
         lm_opts <- adapter_lm_opts(adapter, predict.signature, predict.config),
         {:ok, raw} <- DSEx.LM.generate(lm, messages, provider_lm_opts(lm_opts)),
         {:ok, prediction, trace_messages, trace_raw} <-
           parse_with_retry(
             adapter,
             predict.signature,
             raw,
             messages,
             lm,
             lm_opts,
             inputs,
             predict.demos
           ) do
      {:ok, add_trace(prediction, trace_messages, trace_raw)}
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
      "metadata" => DSEx.Optimizer.Report.json_safe(predict.metadata),
      "adapter" => predict |> resolve_adapter() |> Atom.to_string(),
      "lm" => dump_lm(predict.lm),
      "dynamic_lm" => predict.dynamic_lm?,
      "dynamic_adapter" => predict.dynamic_adapter?
    }
  end

  defp dump_lm(%DSEx.Clients.ReqLLM{} = lm), do: DSEx.Clients.ReqLLM.dump(lm)
  defp dump_lm(_lm), do: nil

  defp encode_keyword(values) when is_list(values),
    do: Enum.map(values, fn {k, v} -> [Atom.to_string(k), v] end)

  defp encode_keyword(values), do: values

  defp require_lm(nil), do: {:error, :lm_not_configured}
  defp require_lm(lm), do: {:ok, lm}

  defp validate_inputs(signature, inputs) do
    required =
      signature.inputs
      |> Enum.reject(&(Map.get(&1.metadata, :optional) || Map.get(&1.metadata, "optional")))
      |> Enum.map(& &1.name)

    missing = Enum.reject(required, &input_present?(inputs, &1))

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_input_fields, missing}}
    end
  end

  defp input_present?(inputs, name) do
    string_name = to_string(name)

    cond do
      Map.has_key?(inputs, name) ->
        true

      Map.has_key?(inputs, string_name) ->
        true

      is_binary(name) ->
        case existing_atom(name) do
          atom when is_atom(atom) -> Map.has_key?(inputs, atom)
          _string -> false
        end

      true ->
        false
    end
  end

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp adapter_lm_opts(adapter, signature, config) do
    if function_exported?(adapter, :lm_opts, 2) do
      Keyword.merge(config, adapter.lm_opts(signature, config))
    else
      config
    end
  end

  defp parse_with_retry(adapter, signature, raw, messages, lm, opts, inputs, demos) do
    case adapter.parse(signature, raw, []) do
      {:ok, prediction} ->
        {:ok, prediction, messages, raw}

      {:error, _reason} = error ->
        recover_parse_failure(error, adapter, signature, messages, lm, opts, inputs, demos, raw)
    end
  end

  defp recover_parse_failure(error, adapter, signature, messages, lm, opts, inputs, demos, raw) do
    cond do
      chat_json_fallback?(adapter, opts) ->
        retry_with_json_adapter(error, signature, lm, opts, inputs, demos, messages, raw)

      adapter_parse_error?(error) and Keyword.get(opts, :json_retries, 0) > 0 ->
        retry_with_feedback(error, adapter, signature, messages, lm, opts, raw)

      true ->
        emit_parse_error(adapter, signature, error)
        parse_error(error, messages, raw)
    end
  end

  defp chat_json_fallback?(DSEx.Adapter.Chat, opts),
    do: Keyword.get(opts, :json_fallback, true)

  defp chat_json_fallback?(_adapter, _opts), do: false

  defp retry_with_json_adapter(
         error,
         signature,
         lm,
         opts,
         inputs,
         demos,
         original_messages,
         original_raw
       ) do
    DSEx.Telemetry.execute([:dsex, :adapter, :parse, :json_fallback], %{count: 1}, %{
      adapter: DSEx.Adapter.Chat,
      signature: DSEx.Signature.to_spec(signature),
      error: parse_error_message(error)
    })

    retry_messages = DSEx.Adapter.JSON.format(signature, inputs, demos: demos)

    retry_opts =
      opts
      |> Keyword.merge(DSEx.Adapter.JSON.lm_opts(signature, opts))
      |> Keyword.put(:json_fallback, false)

    case DSEx.LM.generate(lm, retry_messages, provider_lm_opts(retry_opts)) do
      {:ok, retry_raw} ->
        case DSEx.Adapter.JSON.parse(signature, retry_raw, []) do
          {:ok, prediction} -> {:ok, prediction, retry_messages, retry_raw}
          _retry_error -> parse_error(error, original_messages, original_raw)
        end

      {:error, _reason} = lm_error ->
        parse_error(lm_error, original_messages, original_raw)
    end
  end

  defp retry_with_feedback(
         {:error, %DSEx.AdapterParseError{} = error},
         adapter,
         signature,
         messages,
         lm,
         opts,
         _raw
       ) do
    DSEx.Telemetry.execute([:dsex, :adapter, :parse, :retry], %{count: 1}, %{
      adapter: adapter,
      signature: DSEx.Signature.to_spec(signature),
      error: error.message
    })

    retry_messages = messages ++ [%{role: :user, content: error.message}]
    retry_opts = Keyword.update!(opts, :json_retries, &(&1 - 1))

    with {:ok, retry_raw} <- DSEx.LM.generate(lm, retry_messages, provider_lm_opts(retry_opts)) do
      case adapter.parse(signature, retry_raw, []) do
        {:ok, prediction} -> {:ok, prediction, retry_messages, retry_raw}
        retry_error -> parse_error(retry_error, retry_messages, retry_raw)
      end
    end
  end

  defp adapter_parse_error?({:error, %DSEx.AdapterParseError{}}), do: true
  defp adapter_parse_error?(_error), do: false

  defp emit_parse_error(adapter, signature, error) do
    DSEx.Telemetry.execute([:dsex, :adapter, :parse, :error], %{count: 1}, %{
      adapter: adapter,
      signature: DSEx.Signature.to_spec(signature),
      error: parse_error_message(error)
    })
  end

  defp parse_error_message({:error, %DSEx.AdapterParseError{} = error}), do: error.message
  defp parse_error_message(error), do: error

  defp provider_lm_opts(opts), do: Keyword.drop(opts, [:json_fallback, :json_retries])

  defp parse_error(error, messages, raw) do
    {:error,
     %{
       reason: error,
       trace: DSEx.Redaction.redact(%{messages: messages, raw: raw})
     }}
  end

  defp resolve_lm(%__MODULE__{dynamic_lm?: true}), do: DSEx.Settings.get().lm
  defp resolve_lm(%__MODULE__{lm: lm}), do: lm

  defp resolve_adapter(%__MODULE__{dynamic_adapter?: true}), do: DSEx.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: nil}), do: DSEx.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: adapter}), do: adapter

  defp add_trace(%DSEx.Prediction{} = prediction, messages, raw) do
    trace = DSEx.Redaction.redact(%{messages: messages, raw: raw})
    metadata = Map.put(prediction.metadata, :trace, trace)
    %{prediction | metadata: metadata}
  end
end

defmodule DSEx.Predict.Predict do
  @moduledoc """
  Basic DSEx program that maps signature inputs to typed outputs with an LM.

  `Predict` is the smallest executable DSEx module. It formats a signature and
  input map with an adapter, calls the configured LM, parses the result into a
  `DSEx.Prediction`, and attaches trace metadata. Most higher-level modules
  such as ChainOfThought, RAG, ReAct, BestOfN, and optimizers eventually compose
  around this shape.

  Required inputs are validated before an LM call is made. This keeps missing
  data as a local program error instead of spending provider calls on malformed
  prompts.

  ## Example

      iex> lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
      iex> program = DSEx.Predict.Predict.new("question -> answer", lm: lm)
      iex> {:ok, prediction} = DSEx.Predict.Predict.call(program, %{question: "2+2?"})
      iex> DSEx.Prediction.get(prediction, :answer)
      "4"

      iex> silent_lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "unused"} end]}
      iex> missing = DSEx.Predict.Predict.new("question, context -> answer", lm: silent_lm)
      iex> DSEx.Predict.Predict.call(missing, %{question: "2+2?"})
      {:error, {:missing_input_fields, [:context]}}
  """

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

  @doc """
  Builds a prediction program.

  Pass `:lm` and `:adapter` for a self-contained program, or omit them to resolve
  from process/global DSEx settings at call time. `:demos`, `:config`, and
  `:metadata` are retained on the program and participate in dump/load where
  supported.
  """
  @option_schema [
    lm: [type: :any],
    adapter: [type: :any],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}]
  ]

  def new(signature, opts \\ []) do
    {opts, predict_opts} = validate_opts!(opts)

    %__MODULE__{
      signature: DSEx.Signature.ensure(signature),
      lm: predict_opts[:lm],
      adapter: predict_opts[:adapter],
      demos: predict_opts[:demos],
      config: predict_opts[:config],
      metadata: predict_opts[:metadata],
      dynamic_lm?: not Keyword.has_key?(opts, :lm),
      dynamic_adapter?: not Keyword.has_key?(opts, :adapter)
    }
  end

  @doc """
  Calls the program with a map or keyword list of inputs.

  Returns `{:ok, prediction}` on success or `{:error, reason}` for local input
  errors, LM errors, or adapter parse errors. Successful predictions include
  redacted trace metadata with the rendered messages and raw LM output.
  """
  @impl true
  def call(%__MODULE__{} = predict, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, lm} <- require_lm(resolve_lm(predict)),
         adapter <- resolve_adapter(predict),
         {:ok, inputs} <- normalize_inputs(inputs),
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

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_predict_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  @doc "Returns a copy of the program with demonstrations attached."
  def with_demos(%__MODULE__{} = predict, demos), do: %{predict | demos: List.wrap(demos)}

  @doc "Returns a copy of the program pinned to a concrete LM."
  def with_lm(%__MODULE__{} = predict, lm), do: %{predict | lm: lm, dynamic_lm?: false}

  @doc "Returns a copy of the program with a new signature."
  def with_signature(%__MODULE__{} = predict, signature),
    do: %{predict | signature: DSEx.Signature.ensure(signature)}

  @doc "Serializes portable program state for `DSEx.Saving`."
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

  defp validate_opts!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      predict_opts =
        DSEx.Options.validate!(
          Keyword.take(opts, Keyword.keys(@option_schema)),
          @option_schema,
          "DSEx.Predict.Predict.new/2"
        )

      {opts, predict_opts}
    else
      raise ArgumentError,
            "DSEx.Predict.Predict.new/2: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts) do
    raise ArgumentError,
          "DSEx.Predict.Predict.new/2: expected keyword options, got: #{inspect(opts)}"
  end

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error ->
      {:error, {:invalid_predict_inputs, "expected inputs as {key, value} pairs"}}
  end

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

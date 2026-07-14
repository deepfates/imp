defmodule Imp.Predict.Predict do
  @moduledoc """
  Basic Imp program that maps signature inputs to typed outputs with an LM.

  `Predict` is the smallest executable Imp module. It formats a signature and
  input map with an adapter, calls the configured LM, parses the result into a
  `Imp.Prediction`, and attaches trace metadata. Most higher-level modules
  such as ChainOfThought, RAG, ReAct, BestOfN, and optimizers eventually compose
  around this shape.

  Required inputs are validated before an LM call is made. This keeps missing
  data as a local program error instead of spending provider calls on malformed
  prompts.

  ## Example

      iex> lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
      iex> program = Imp.Predict.Predict.new("question -> answer", lm: lm)
      iex> {:ok, prediction} = Imp.Predict.Predict.call(program, %{question: "2+2?"})
      iex> Imp.Prediction.get(prediction, :answer)
      "4"

      iex> silent_lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "unused"} end]}
      iex> missing = Imp.Predict.Predict.new("question, context -> answer", lm: silent_lm)
      iex> Imp.Predict.Predict.call(missing, %{question: "2+2?"})
      {:error, {:missing_input_fields, [:context]}}
  """

  @behaviour Imp.Module

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
  from process/global Imp settings at call time. `:demos`, `:config`, and
  `:metadata` are retained on the program and participate in dump/load where
  supported.
  """
  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}]
  ]

  def new(signature, opts \\ []) do
    {opts, predict_opts} = validate_opts!(opts)

    %__MODULE__{
      signature: Imp.Signature.ensure(signature),
      lm: predict_opts[:lm],
      adapter: predict_opts[:adapter],
      demos: Imp.Example.normalize_demos!(predict_opts[:demos], "Imp.Predict.Predict.new/2"),
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
         {:ok, messages} <-
           format_with_adapter(adapter, predict.signature, inputs, demos: predict.demos),
         {:ok, lm_opts} <- adapter_lm_opts(adapter, predict.signature, predict.config),
         {:ok, raw} <- Imp.LM.generate(lm, messages, provider_lm_opts(lm_opts)),
         {:ok, prediction, trace_messages, trace_raw, trace_lm_metadata} <-
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
      prediction = add_trace(prediction, trace_messages, trace_raw, trace_lm_metadata)
      Imp.Optimizer.Trace.capture(predict, inputs, prediction)
      {:ok, prediction}
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_predict_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  @doc "Returns a copy of the program with demonstrations attached."
  def with_demos(%__MODULE__{} = predict, demos),
    do: %{
      predict
      | demos: Imp.Example.normalize_demos!(demos, "Imp.Predict.Predict.with_demos/2")
    }

  @doc "Returns a copy of the program pinned to a concrete LM."
  def with_lm(%__MODULE__{} = predict, lm), do: %{predict | lm: lm, dynamic_lm?: false}

  @doc "Returns a copy of the program with a new signature."
  def with_signature(%__MODULE__{} = predict, signature),
    do: %{predict | signature: Imp.Signature.ensure(signature)}

  @doc "Serializes portable program state for `Imp.Saving`."
  def dump(%__MODULE__{} = predict) do
    %{
      "signature" => Imp.Signature.dump(predict.signature),
      "demos" => Enum.map(predict.demos, &Imp.Optimizer.Report.json_safe/1),
      "config" => encode_keyword(predict.config),
      "metadata" => Imp.Optimizer.Report.json_safe(predict.metadata),
      "adapter" => predict |> resolve_adapter() |> Atom.to_string(),
      "lm" => dump_lm(predict.lm),
      "dynamic_lm" => predict.dynamic_lm?,
      "dynamic_adapter" => predict.dynamic_adapter?
    }
  end

  defp dump_lm(%Imp.Clients.ReqLLM{} = lm), do: Imp.Clients.ReqLLM.dump(lm)
  defp dump_lm(_lm), do: nil

  defp encode_keyword(values) when is_list(values),
    do: Enum.map(values, fn {k, v} -> [Atom.to_string(k), v] end)

  defp encode_keyword(values), do: values

  defp require_lm(nil), do: {:error, :lm_not_configured}
  defp require_lm(lm), do: {:ok, lm}

  defp validate_opts!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      predict_opts =
        Imp.Options.validate!(
          Keyword.take(opts, Keyword.keys(@option_schema)),
          @option_schema,
          "Imp.Predict.Predict.new/2"
        )

      {opts, predict_opts}
    else
      raise ArgumentError,
            "Imp.Predict.Predict.new/2: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts) do
    raise ArgumentError,
          "Imp.Predict.Predict.new/2: expected keyword options, got: #{inspect(opts)}"
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

  defp format_with_adapter(adapter, signature, inputs, opts) do
    with :ok <- ensure_adapter_loaded(adapter),
         true <- function_exported?(adapter, :format, 3) do
      {:ok, adapter.format(signature, inputs, opts)}
    else
      {:error, _reason} = error ->
        error

      false ->
        {:error, {:invalid_adapter, adapter, :format}}
    end
  rescue
    error ->
      {:error, {:adapter_format_failed, adapter, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:adapter_format_failed, adapter, {kind, reason}}}
  end

  defp adapter_lm_opts(adapter, signature, config) do
    with :ok <- ensure_adapter_loaded(adapter),
         true <- function_exported?(adapter, :lm_opts, 2),
         {:ok, opts} <- call_adapter_lm_opts(adapter, signature, config) do
      {:ok, Keyword.merge(config, opts)}
    else
      false ->
        {:ok, config}

      {:error, _reason} = error ->
        error
    end
  end

  defp call_adapter_lm_opts(adapter, signature, config) do
    opts = adapter.lm_opts(signature, config)

    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error, {:invalid_adapter_lm_opts, adapter, opts}}
    end
  rescue
    error ->
      {:error, {:adapter_lm_opts_failed, adapter, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:adapter_lm_opts_failed, adapter, {kind, reason}}}
  end

  defp ensure_adapter_loaded(adapter) when is_atom(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, _module} -> :ok
      {:error, reason} -> {:error, {:adapter_not_loaded, adapter, reason}}
    end
  end

  defp ensure_adapter_loaded(adapter), do: {:error, {:invalid_adapter, adapter}}

  defp parse_with_retry(adapter, signature, raw, messages, lm, opts, inputs, demos) do
    with {:ok, output, lm_metadata} <- Imp.LM.Result.split(raw) do
      case adapter.parse(signature, output, []) do
        {:ok, prediction} ->
          {:ok, prediction, messages, output, lm_metadata}

        {:error, _reason} = error ->
          recover_parse_failure(
            error,
            adapter,
            signature,
            messages,
            lm,
            opts,
            inputs,
            demos,
            output
          )
      end
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

  defp chat_json_fallback?(Imp.Adapter.Chat, opts),
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
    Imp.Telemetry.execute([:imp, :adapter, :parse, :json_fallback], %{count: 1}, %{
      adapter: Imp.Adapter.Chat,
      signature: Imp.Signature.to_spec(signature),
      error: parse_error_message(error)
    })

    retry_messages = Imp.Adapter.JSON.format(signature, inputs, demos: demos)

    retry_opts =
      opts
      |> Keyword.merge(Imp.Adapter.JSON.lm_opts(signature, opts))
      |> Keyword.put(:json_fallback, false)

    with {:ok, retry_raw} <- Imp.LM.generate(lm, retry_messages, provider_lm_opts(retry_opts)),
         {:ok, retry_raw, retry_lm_metadata} <- Imp.LM.Result.split(retry_raw) do
      case Imp.Adapter.JSON.parse(signature, retry_raw, []) do
        {:ok, prediction} -> {:ok, prediction, retry_messages, retry_raw, retry_lm_metadata}
        _retry_error -> parse_error(error, original_messages, original_raw)
      end
    else
      {:error, _reason} = retry_error ->
        parse_error(retry_error, original_messages, original_raw)
    end
  end

  defp retry_with_feedback(
         {:error, %Imp.AdapterParseError{} = error},
         adapter,
         signature,
         messages,
         lm,
         opts,
         _raw
       ) do
    Imp.Telemetry.execute([:imp, :adapter, :parse, :retry], %{count: 1}, %{
      adapter: adapter,
      signature: Imp.Signature.to_spec(signature),
      error: error.message
    })

    retry_messages = messages ++ [%{role: :user, content: error.message}]
    retry_opts = Keyword.update!(opts, :json_retries, &(&1 - 1))

    with {:ok, retry_raw} <- Imp.LM.generate(lm, retry_messages, provider_lm_opts(retry_opts)),
         {:ok, retry_raw, retry_lm_metadata} <- Imp.LM.Result.split(retry_raw) do
      case adapter.parse(signature, retry_raw, []) do
        {:ok, prediction} -> {:ok, prediction, retry_messages, retry_raw, retry_lm_metadata}
        retry_error -> parse_error(retry_error, retry_messages, retry_raw)
      end
    end
  end

  defp adapter_parse_error?({:error, %Imp.AdapterParseError{}}), do: true
  defp adapter_parse_error?(_error), do: false

  defp emit_parse_error(adapter, signature, error) do
    Imp.Telemetry.execute([:imp, :adapter, :parse, :error], %{count: 1}, %{
      adapter: adapter,
      signature: Imp.Signature.to_spec(signature),
      error: parse_error_message(error)
    })
  end

  defp parse_error_message({:error, %Imp.AdapterParseError{} = error}), do: error.message
  defp parse_error_message(error), do: error

  defp provider_lm_opts(opts), do: Keyword.drop(opts, [:json_fallback, :json_retries])

  defp parse_error(error, messages, raw) do
    {:error,
     %{
       reason: error,
       trace: Imp.Redaction.redact(%{messages: messages, raw: raw})
     }}
  end

  defp resolve_lm(%__MODULE__{dynamic_lm?: true}), do: Imp.Settings.get().lm
  defp resolve_lm(%__MODULE__{lm: lm}), do: lm

  defp resolve_adapter(%__MODULE__{dynamic_adapter?: true}), do: Imp.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: nil}), do: Imp.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: adapter}), do: adapter

  defp add_trace(%Imp.Prediction{} = prediction, messages, raw, lm_metadata) do
    trace = Imp.Redaction.redact(%{messages: messages, raw: raw, lm_metadata: lm_metadata})

    metadata =
      prediction.metadata
      |> Map.merge(lm_metadata)
      |> Map.put(:trace, trace)

    %{prediction | metadata: metadata}
  end
end

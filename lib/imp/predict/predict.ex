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
    if Map.get(Imp.Settings.get(), :track_usage, false) do
      # DSPy `track_usage=True`: the call runs inside a usage tracker and the
      # aggregate lands on the prediction (`Imp.Prediction.get_lm_usage/1`).
      {result, usage} = Imp.Usage.track(fn -> do_call(predict, inputs) end)

      case result do
        {:ok, prediction} -> {:ok, Imp.Prediction.set_lm_usage(prediction, usage)}
        error -> error
      end
    else
      do_call(predict, inputs)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_predict_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  @doc """
  Calls the program with a per-call config override.

  `config` is a keyword list merged over the program's stored config for this
  invocation only — the program itself is not mutated. This is the Imp analog
  of DSPy's call-time `config={...}` override (and of its predicted-outputs
  `prediction=` pass-through): every merged entry flows to the LM request.

      Imp.Predict.Predict.call(program, %{question: "..."},
        temperature: 0.2,
        prediction: %{type: "content", content: "..."}
      )
  """
  def call(%__MODULE__{} = predict, inputs, config) do
    unless Keyword.keyword?(config) do
      raise ArgumentError,
            "Imp.Predict.Predict.call/3 expects per-call config as a keyword list, got: #{inspect(config)}"
    end

    call(%{predict | config: Keyword.merge(predict.config, config)}, inputs)
  end

  defp do_call(%__MODULE__{} = predict, inputs) do
    with {:ok, lm} <- require_lm(resolve_lm(predict)),
         adapter <- resolve_adapter(predict),
         {:ok, inputs} <- normalize_inputs(inputs),
         :ok <- validate_inputs(predict.signature, inputs),
         {:ok, messages} <-
           format_with_adapter(adapter, predict.signature, inputs, demos: predict.demos),
         {:ok, lm_opts} <- adapter_lm_opts(adapter, predict.signature, predict.config, lm),
         {:ok, lm_opts} <- multi_completion_opts(lm_opts),
         {:ok, raw} <- Imp.LM.generate(lm, messages, provider_lm_opts(lm_opts)),
         :ok <- validate_completion_shape(lm_opts, raw),
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
      "demos" => Enum.map(predict.demos, &Imp.Optimizer.Report.encode_term/1),
      "config" => encode_keyword(predict.config),
      "metadata" => Imp.Optimizer.Report.encode_term(predict.metadata),
      "adapter" => predict |> resolve_adapter() |> Atom.to_string(),
      "lm" => dump_lm(predict.lm, predict.dynamic_lm?),
      "dynamic_lm" => predict.dynamic_lm?,
      "dynamic_adapter" => predict.dynamic_adapter?
    }
  end

  # Imp.Saving's portable-LM doctrine (already enforced by RLM): a program
  # pinned to a non-portable LM must fail LOUDLY at dump time instead of
  # silently persisting `dynamic_lm: false` with a nil LM — an artifact that
  # would load as a dynamic program answering with the global LM. The escape
  # hatch is explicit: pin a portable ReqLLM client, or opt in to dynamic LM
  # resolution (build the program without `:lm`).
  defp dump_lm(lm, dynamic_lm?),
    do: Imp.Saving.dump_portable_lm(lm, dynamic_lm?, "Predict LM")

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

  @doc false
  # DSPy 3.2.1 Predict.forward warns (logger.warning, "not in signature") on
  # every call that carries input keys outside the signature, then proceeds —
  # the extras are ignored, not fatal (dspy/predict/predict.py,
  # test_extra_fields_warning). Imp matches: loud per-call warning, call
  # continues. Public (doc-false) so entry points that filter inputs before
  # reaching Predict (ReActV2) can emit the same warning at their boundary.
  def warn_extra_inputs(signature, inputs, except \\ []) do
    expected = Enum.map(signature.inputs, & &1.name)
    allowed = MapSet.new(Enum.map(expected, &to_string/1) ++ Enum.map(except, &to_string/1))

    extra =
      inputs
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, to_string(&1)))

    if extra != [] do
      require Logger

      Logger.warning(
        "Imp.Predict: input contains fields not in signature. " <>
          "These fields will be ignored: #{inspect(extra)}. " <>
          "Expected fields: #{inspect(expected)}."
      )
    end

    :ok
  end

  defp validate_inputs(signature, inputs) do
    :ok = warn_extra_inputs(signature, inputs)

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

  defp adapter_lm_opts(adapter, signature, config, lm) do
    with :ok <- ensure_adapter_loaded(adapter),
         true <-
           function_exported?(adapter, :lm_opts, 3) or function_exported?(adapter, :lm_opts, 2),
         {:ok, opts} <- call_adapter_lm_opts(adapter, signature, config, lm) do
      {:ok, Keyword.merge(config, opts)}
    else
      false ->
        {:ok, config}

      {:error, _reason} = error ->
        error
    end
  end

  # Prefer the capability-gated arity-3 form (DSPy-faithful response_format
  # selection); fall back to arity-2 for adapters that predate it.
  defp call_adapter_lm_opts(adapter, signature, config, lm) do
    opts =
      if function_exported?(adapter, :lm_opts, 3) do
        adapter.lm_opts(signature, config, Imp.LM.response_format_capability(lm))
      else
        adapter.lm_opts(signature, config)
      end

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

  # DSPy `n=` multi-completion (Predict._forward_preprocess): with n > 1 and an
  # unset or near-zero temperature, the samples would collapse; upstream bumps
  # temperature to 0.7 and Imp matches. `:n` itself flows to the LM request.
  defp multi_completion_opts(opts) do
    case Keyword.get(opts, :n, 1) do
      1 ->
        {:ok, opts}

      n when is_integer(n) and n > 1 ->
        temperature = Keyword.get(opts, :temperature)

        if is_nil(temperature) or temperature <= 0.15 do
          {:ok, Keyword.put(opts, :temperature, 0.7)}
        else
          {:ok, opts}
        end

      other ->
        {:error, {:invalid_multi_completion_count, other}}
    end
  end

  # An LM asked for n > 1 completions must return a list of outputs. An LM
  # that ignores :n and returns a single output would silently produce one
  # completion for an n=K request — that is an error, never a quiet fallback.
  defp validate_completion_shape(opts, raw) do
    n = Keyword.get(opts, :n, 1)

    if n > 1 and not is_list(raw) do
      {:error,
       {:multi_completion_not_returned, n,
        "the LM returned a single output for an n=#{n} request; " <>
          "multi-completion LMs must return a list with one output per completion"}}
    else
      :ok
    end
  end

  # Multi-completion parse: the K completions parse independently; the first is
  # the primary prediction and `completions` holds all K in order (DSPy
  # `Prediction.from_completions` / `result.completions.field[i]`). A parse
  # failure on ANY completion fails the whole call loudly with the failing
  # index — matching upstream, where one bad completion raises for the call
  # (after the chat->JSON fallback, which Imp also applies to the whole call).
  defp parse_with_retry(adapter, signature, raw, messages, lm, opts, inputs, demos)
       when is_list(raw) do
    case parse_completions(adapter, signature, raw) do
      {:ok, prediction} ->
        {:ok, prediction, messages, raw, %{}}

      {:error, _reason} = error ->
        if chat_json_fallback?(adapter, opts) do
          retry_completions_with_json_adapter(
            error,
            signature,
            lm,
            opts,
            inputs,
            demos,
            messages,
            raw
          )
        else
          emit_parse_error(adapter, signature, error)
          parse_error(error, messages, raw)
        end
    end
  end

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

  # DSPy 3.2.1 ChatAdapter.__call__ retries any failure through JSONAdapter
  # unless the adapter IS a JSONAdapter or use_json_adapter_fallback is false
  # (dspy/adapters/chat_adapter.py). XMLAdapter subclasses ChatAdapter without
  # overriding __call__, so it inherits the same JSON fallback — byte-verified
  # by the xml_missing_output_error golden-trace case (dee-ovd3).
  defp chat_json_fallback?(adapter, opts) when adapter in [Imp.Adapter.Chat, Imp.Adapter.XML],
    do: Keyword.get(opts, :json_fallback, true)

  defp chat_json_fallback?(_adapter, _opts), do: false

  defp parse_completions(_adapter, _signature, []),
    do: {:error, {:empty_completions, "the LM returned an empty completion list"}}

  defp parse_completions(adapter, signature, raw_completions) do
    raw_completions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      with {:ok, output, _lm_metadata} <- Imp.LM.Result.split(raw),
           {:ok, prediction} <- adapter.parse(signature, output, []) do
        {:cont, {:ok, [prediction | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:completion_parse_failed, index, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} ->
        [first | _rest] = predictions = Enum.reverse(reversed)
        {:ok, %{first | completions: predictions}}

      {:error, _reason} = error ->
        error
    end
  end

  # Multi-completion twin of retry_with_json_adapter/8: the whole call is
  # retried through the JSON adapter (as upstream's ChatAdapter fallback
  # retries the whole call), and the retry must again return one output per
  # completion.
  defp retry_completions_with_json_adapter(
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
      |> Keyword.merge(
        Imp.Adapter.JSON.lm_opts(signature, opts, Imp.LM.response_format_capability(lm))
      )
      |> Keyword.put(:json_fallback, false)

    with {:ok, retry_raw} when is_list(retry_raw) <-
           Imp.LM.generate(lm, retry_messages, provider_lm_opts(retry_opts)),
         {:ok, prediction} <- parse_completions(Imp.Adapter.JSON, signature, retry_raw) do
      {:ok, prediction, retry_messages, retry_raw, %{}}
    else
      _retry_failure -> parse_error(error, original_messages, original_raw)
    end
  end

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
      |> Keyword.merge(
        Imp.Adapter.JSON.lm_opts(signature, opts, Imp.LM.response_format_capability(lm))
      )
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

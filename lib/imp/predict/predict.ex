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
    adapter_opts: [],
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
    # Options handed to the adapter's `format/3` on every call, beside
    # `:demos`: how a program passes rendering data, and how a host injects
    # renderers without writing a second adapter module.
    adapter_opts: [type: :keyword_list, default: []],
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
      adapter_opts: predict_opts[:adapter_opts],
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

  A completion that could not be read as the outputs, after the chat and XML
  adapters' JSON fallback, is `{:error, %Imp.AdapterParseError{}}` with its
  `:trace` set; see that module for the kinds. An LM request that failed,
  including the fallback's own request, is the LM's error (`Imp.LMError` for
  `Imp.Clients.ReqLLM`).
  """
  @impl true
  def call(%__MODULE__{} = predict, inputs) when is_list(inputs) or is_map(inputs) do
    if Map.get(Imp.Settings.get(), :track_usage, false) do
      # The call runs inside a usage tracker and the aggregate lands on the
      # prediction, readable with `Imp.Prediction.get_lm_usage/1`.
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
  invocation only; the program itself is not mutated. Every merged entry flows
  to the LM request, including a predicted-outputs `:prediction` map. Raises
  `ArgumentError` if `config` is not a keyword list.

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
         inputs = apply_input_defaults(predict.signature, inputs),
         :ok <- validate_inputs(predict.signature, inputs),
         {:ok, request_signature, request_config, reasoning_fields} <-
           prepare_native_reasoning(predict.signature, lm, predict.config),
         {:ok, messages} <-
           format_with_adapter(
             adapter,
             request_signature,
             inputs,
             Keyword.put(predict.adapter_opts, :demos, predict.demos)
           ),
         {:ok, lm_opts} <- adapter_lm_opts(adapter, request_signature, request_config, lm),
         {:ok, lm_opts} <- multi_completion_opts(lm_opts),
         {:ok, raw} <-
           Imp.Streaming.Execution.generate(
             predict,
             lm,
             messages,
             provider_lm_opts(lm_opts)
           ),
         :ok <- validate_completion_shape(lm_opts, raw),
         {:ok, prediction, trace_messages, trace_raw, trace_lm_metadata} <-
           parse_with_retry(
             adapter,
             request_signature,
             raw,
             messages,
             lm,
             lm_opts,
             inputs,
             predict.demos
           ),
         {:ok, prediction} <-
           restore_native_reasoning(prediction, reasoning_fields, trace_lm_metadata) do
      prediction = add_trace(prediction, trace_messages, trace_raw, trace_lm_metadata)
      Imp.Optimizer.Trace.capture(predict, inputs, prediction)
      {:ok, prediction}
    end
  end

  defp prepare_native_reasoning(signature, lm, config) do
    fields = Enum.filter(signature.outputs, &(&1.type in [:reasoning, "reasoning"]))

    if fields == [] do
      {:ok, signature, config, []}
    else
      configured_effort = Imp.LM.configured_option(lm, :reasoning_effort)

      effort =
        cond do
          Keyword.has_key?(config, :reasoning_effort) ->
            Keyword.fetch!(config, :reasoning_effort)

          match?({:ok, _}, configured_effort) ->
            elem(configured_effort, 1)

          true ->
            "low"
        end

      if Imp.LM.reasoning_capability(lm) and not is_nil(effort) do
        names = MapSet.new(Enum.map(fields, & &1.name))

        request_signature = %{
          signature
          | outputs: Enum.reject(signature.outputs, &MapSet.member?(names, &1.name))
        }

        {:ok, request_signature, Keyword.put(config, :reasoning_effort, effort), fields}
      else
        {:ok, signature, config, []}
      end
    end
  end

  defp restore_native_reasoning(prediction, [], _metadata), do: {:ok, prediction}

  defp restore_native_reasoning(%Imp.Prediction{} = prediction, fields, metadata) do
    case Map.get(metadata, :completion_metadata, Map.get(metadata, "completion_metadata")) do
      completion_metadata when is_list(completion_metadata) ->
        if length(completion_metadata) == length(prediction.completions) do
          with {:ok, completions} <-
                 restore_reasoning_completions(
                   prediction.completions,
                   completion_metadata,
                   fields
                 ) do
            [first | _rest] = completions
            {:ok, %{first | completions: completions}}
          end
        else
          {:error,
           {:native_reasoning_completion_count_mismatch, length(prediction.completions),
            length(completion_metadata)}}
        end

      _single ->
        restore_reasoning_value(prediction, fields, metadata)
    end
  end

  defp restore_reasoning_completions(predictions, metadata, fields) do
    predictions
    |> Enum.zip(metadata)
    |> Enum.reduce_while({:ok, []}, fn {prediction, item_metadata}, {:ok, acc} ->
      case restore_reasoning_value(prediction, fields, item_metadata) do
        {:ok, restored} -> {:cont, {:ok, [restored | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp restore_reasoning_value(prediction, fields, metadata) do
    case Map.get(metadata, :native_reasoning, Map.get(metadata, "native_reasoning")) do
      text when is_binary(text) and text != "" ->
        reasoning = Imp.Adapter.Types.Reasoning.new(text)
        {:ok, Enum.reduce(fields, prediction, &Imp.Prediction.put(&2, &1.name, reasoning))}

      _missing ->
        {:error, {:native_reasoning_missing, Enum.map(fields, & &1.name)}}
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

  # A program pinned to a non-portable LM fails loudly here rather than
  # persisting `dynamic_lm: false` with a nil LM, which would load as a dynamic
  # program answering with the global LM. Callers pin a portable ReqLLM client,
  # or build the program without `:lm` to resolve the LM at call time.
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
  # Input keys outside the signature warn once per call and are then ignored;
  # they are never fatal. Public so entry points that filter inputs before they
  # reach `Predict`, such as ReActV2, can warn at their own boundary.
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

  # An input field declared with a default fills in when the caller omits it,
  # before the extra-key, type and missing-field checks. A field without a
  # default is untouched, so a missing required field still fails.
  defp apply_input_defaults(signature, inputs) do
    Enum.reduce(signature.inputs, inputs, fn field, acc ->
      case Map.fetch(field.metadata, :default) do
        {:ok, default} ->
          if input_present?(acc, field.name), do: acc, else: Map.put(acc, field.name, default)

        :error ->
          case Map.fetch(field.metadata, "default") do
            {:ok, default} ->
              if input_present?(acc, field.name),
                do: acc,
                else: Map.put(acc, field.name, default)

            :error ->
              acc
          end
      end
    end)
  end

  # Inputs are soft-validated against the signature's declared types when the
  # `:warn_on_type_mismatch` setting is on (the default): a mismatch logs a
  # warning and the call proceeds, never an error. Two values are skipped:
  #   * nil;
  #   * a plain `:string` field with no enum constraint, because every untyped
  #     field defaults to `:string` and an implicit string cannot be told from
  #     a declared one.
  defp warn_type_mismatches(signature, inputs) do
    if Map.get(Imp.Settings.get(), :warn_on_type_mismatch, true) do
      Enum.each(signature.inputs, fn field ->
        value = fetch_input(inputs, field.name)

        unless is_nil(value) or skip_field?(field) or
                 input_type_compatible?(value, field_descriptor(field)) do
          require Logger

          Logger.warning(
            "Imp.Predict: type mismatch for field '#{field.name}': " <>
              "expected #{descriptor_label(field_descriptor(field))} based on the signature, " <>
              "but the provided value is incompatible: #{inspect(value)}."
          )
        end
      end)
    end

    :ok
  end

  # The implicit-string skip applies at field level only: a string element type
  # nested inside `array[...]` was declared explicitly and is checked strictly.
  defp skip_field?(field) do
    field.type == :string and not is_list(fetch_meta(field_descriptor(field), :enum))
  end

  # A flat type descriptor for a field: its type plus its inline constraint
  # keys (`enum`, `items`). This is the shape `Imp.Signature.Parser` stores for
  # array elements, so the compatibility walk recurses uniformly.
  defp field_descriptor(field) do
    constraints =
      case fetch_meta(field.metadata, :constraints) do
        constraints when is_map(constraints) -> constraints
        _other -> %{}
      end

    Map.merge(%{type: field.type}, constraints)
  end

  defp input_type_compatible?(value, descriptor) do
    case fetch_meta(descriptor, :enum) do
      allowed when is_list(allowed) ->
        value in allowed or (scalar?(value) and to_string(value) in allowed)

      _no_enum ->
        type_compatible?(value, fetch_meta(descriptor, :type), descriptor)
    end
  end

  defp type_compatible?(value, type, descriptor) do
    case type do
      :string ->
        is_binary(value)

      :integer ->
        is_integer(value)

      :float ->
        is_number(value)

      :number ->
        is_number(value)

      :boolean ->
        is_boolean(value)

      :object ->
        is_map(value) and not is_struct(value)

      :datetime ->
        match?(%DateTime{}, value) or match?(%NaiveDateTime{}, value)

      :code ->
        code_input?(value)

      "code" ->
        code_input?(value)

      :array ->
        case fetch_meta(descriptor, :items) do
          items when is_map(items) ->
            is_list(value) and Enum.all?(value, &input_type_compatible?(&1, items))

          _untyped_items ->
            is_list(value)
        end

      # Unknown/custom types are skipped (no type system to check against).
      _skip ->
        true
    end
  end

  defp code_input?(value) when is_binary(value), do: true
  defp code_input?(%Imp.Adapter.Types.Code{code: code}), do: is_binary(code)

  defp code_input?(%{} = value) do
    is_binary(Map.get(value, :code, Map.get(value, "code")))
  end

  defp code_input?(_value), do: false

  defp scalar?(value),
    do: is_binary(value) or is_atom(value) or is_number(value)

  # Human label for the warning, in Imp's type spellings: `integer`,
  # `array[integer]`, `enum[pending, approved]`.
  defp descriptor_label(descriptor) do
    case fetch_meta(descriptor, :enum) do
      allowed when is_list(allowed) ->
        "enum[#{Enum.join(allowed, ", ")}]"

      _no_enum ->
        case {fetch_meta(descriptor, :type), fetch_meta(descriptor, :items)} do
          {:array, items} when is_map(items) -> "array[#{descriptor_label(items)}]"
          {type, _items} -> to_string(type)
        end
    end
  end

  # Constraint maps may arrive with atom or string keys (loaded signatures).
  defp fetch_meta(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))

  defp fetch_meta(_map, _key), do: nil

  defp fetch_input(inputs, name) do
    string_name = to_string(name)

    cond do
      Map.has_key?(inputs, name) ->
        Map.fetch!(inputs, name)

      Map.has_key?(inputs, string_name) ->
        Map.fetch!(inputs, string_name)

      is_binary(name) ->
        case existing_atom(name) do
          atom when is_atom(atom) -> Map.get(inputs, atom)
          _string -> nil
        end

      true ->
        nil
    end
  end

  defp validate_inputs(signature, inputs) do
    :ok = warn_extra_inputs(signature, inputs)
    :ok = warn_type_mismatches(signature, inputs)

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
      {:error, {:adapter_format_failed, adapter, error}}
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

  # The arity-3 form lets the adapter choose a response format from the LM's
  # capability. An adapter that exports only `lm_opts/2` takes that instead.
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
      {:error, {:adapter_lm_opts_failed, adapter, error}}
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

  # With `n > 1` and an unset or near-zero temperature the samples would
  # collapse to the same completion, so the temperature is raised to 0.7. `:n`
  # itself flows to the LM request.
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

  # An LM asked for `n > 1` completions must return a list of outputs. An LM
  # that ignores `:n` and returns one output is an error, not a quiet fallback
  # to a single completion.
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

  # The K completions parse independently: the first is the primary prediction
  # and `completions` holds all K in order. A parse failure on any one of them
  # fails the whole call, reporting the failing index, after the chat-to-JSON
  # fallback has been tried for the call.
  defp parse_with_retry(adapter, signature, raw, messages, lm, opts, inputs, demos)
       when is_list(raw) do
    case parse_completions(adapter, signature, raw) do
      {:ok, prediction, completion_metadata} ->
        {:ok, prediction, messages, raw, %{completion_metadata: completion_metadata}}

      {:error, _reason} = error ->
        cond do
          lm_failure?(error) ->
            error

          chat_json_fallback?(adapter, opts) ->
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

          true ->
            emit_parse_error(adapter, signature, error)
            parse_error(error, messages, raw, signature)
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
      lm_failure?(error) ->
        error

      chat_json_fallback?(adapter, opts) ->
        retry_with_json_adapter(error, signature, lm, opts, inputs, demos, messages, raw)

      adapter_parse_error?(error) and Keyword.get(opts, :json_retries, 0) > 0 ->
        retry_with_feedback(error, adapter, signature, messages, lm, opts, raw)

      true ->
        emit_parse_error(adapter, signature, error)
        parse_error(error, messages, raw, signature)
    end
  end

  # The chat and XML adapters retry any parse failure through the JSON adapter
  # unless the caller sets `json_fallback: false`. No other adapter does: the
  # JSON adapter has nothing to fall back to.
  defp chat_json_fallback?(adapter, opts) when adapter in [Imp.Adapter.Chat, Imp.Adapter.XML],
    do: Keyword.get(opts, :json_fallback, true)

  defp chat_json_fallback?(_adapter, _opts), do: false

  defp parse_completions(_adapter, _signature, []) do
    {:error,
     %Imp.AdapterParseError{
       kind: :unsupported_output,
       message: "The LM returned an empty completion list.",
       reason: []
     }}
  end

  defp parse_completions(adapter, signature, raw_completions) do
    raw_completions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      with {:ok, output, lm_metadata} <- Imp.LM.Result.split(raw),
           {:ok, prediction} <- adapter.parse(signature, output, []) do
        {:cont, {:ok, [{prediction, lm_metadata} | acc]}}
      else
        {:error, reason} = error ->
          if lm_failure?(error),
            do: {:halt, error},
            else: {:halt, {:error, %{parse_failure(reason) | completion_index: index}}}
      end
    end)
    |> case do
      {:ok, reversed} ->
        pairs = Enum.reverse(reversed)
        [{first, _first_metadata} | _rest] = pairs
        predictions = Enum.map(pairs, &elem(&1, 0))
        metadata = Enum.map(pairs, &elem(&1, 1))
        {:ok, %{first | completions: predictions}, metadata}

      {:error, _reason} = error ->
        error
    end
  end

  # Multi-completion twin of the single-completion JSON retry: the whole call
  # is retried through the JSON adapter, and the retry must again return one
  # output per completion.
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

    # The retry's own LM failure is returned as it is, the way DSPy's JSON
    # fallback lets the LM's exception through: it is not a parse failure, and
    # whether it may be retried is the caller's to read.
    case Imp.LM.generate(lm, retry_messages, provider_lm_opts(retry_opts)) do
      {:ok, retry_raw} when is_list(retry_raw) ->
        case parse_completions(Imp.Adapter.JSON, signature, retry_raw) do
          {:ok, prediction, completion_metadata} ->
            {:ok, prediction, retry_messages, retry_raw,
             %{completion_metadata: completion_metadata}}

          {:error, _retry_reason} ->
            parse_error(error, original_messages, original_raw, signature)
        end

      {:ok, _single} ->
        parse_error(error, original_messages, original_raw, signature)

      {:error, _reason} = lm_error ->
        lm_error
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

    # As above: an LM failure on the retry is returned as it is.
    with {:ok, retry_raw} <- Imp.LM.generate(lm, retry_messages, provider_lm_opts(retry_opts)),
         {:ok, retry_raw, retry_lm_metadata} <- Imp.LM.Result.split(retry_raw) do
      case Imp.Adapter.JSON.parse(signature, retry_raw, []) do
        {:ok, prediction} -> {:ok, prediction, retry_messages, retry_raw, retry_lm_metadata}
        _retry_error -> parse_error(error, original_messages, original_raw, signature)
      end
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
        retry_error -> parse_error(retry_error, retry_messages, retry_raw, signature)
      end
    end
  end

  # An adapter that sends its own request, such as `Imp.Adapter.TwoStep`,
  # returns that request's failure as it is. It is not a parse failure: no
  # fallback is tried, and the caller reads it as the LM error it is.
  defp lm_failure?({:error, reason}), do: Imp.Errors.lm_failure?(reason)

  defp adapter_parse_error?({:error, %Imp.AdapterParseError{}}), do: true
  defp adapter_parse_error?(_error), do: false

  defp emit_parse_error(adapter, signature, error) do
    Imp.Telemetry.execute([:imp, :adapter, :parse, :error], %{count: 1}, %{
      adapter: adapter,
      signature: Imp.Signature.to_spec(signature),
      error: parse_error_message(error)
    })
  end

  defp parse_error_message({:error, reason}), do: parse_failure(reason).message

  defp provider_lm_opts(opts), do: Keyword.drop(opts, [:json_fallback, :json_retries])

  defp parse_error({:error, reason}, messages, raw, signature) do
    failure = parse_failure(reason)

    trace =
      Imp.Redaction.redact(%{
        messages: messages,
        raw: raw,
        format_progress: format_progress(failure, signature)
      })

    {:error, %{failure | trace: trace}}
  end

  # A custom adapter may return any term from `parse/3`; the caller still gets
  # one shape for a completion that could not be read.
  defp parse_failure(%Imp.AdapterParseError{} = error), do: error

  defp parse_failure(reason) do
    %Imp.AdapterParseError{
      kind: :other,
      message: "The adapter could not parse the completion: #{inspect(reason, limit: 20)}",
      reason: reason
    }
  end

  # Records which output fields were decoded before a typed adapter failure,
  # so an optimizer can tell a wholly malformed completion from one that
  # partly followed a multi-output signature. Field names only: values stay in
  # the redacted raw trace, and typed parsing still fails.
  defp format_progress(error, signature) do
    expected = Enum.map(signature.outputs, & &1.name)
    present = present_output_fields(error, expected)
    %{expected: expected, present: present}
  end

  defp present_output_fields(
         %Imp.AdapterParseError{kind: :missing_fields, reason: missing},
         expected
       )
       when is_list(missing),
       do: expected -- missing

  defp present_output_fields(%Imp.AdapterParseError{reason: fields}, expected)
       when is_map(fields) do
    Enum.filter(expected, fn name ->
      Map.has_key?(fields, name) or Map.has_key?(fields, to_string(name))
    end)
  end

  defp present_output_fields(_reason, _expected), do: []

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

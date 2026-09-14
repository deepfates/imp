defmodule Imp.Clients.ReqLLM do
  @moduledoc """
  Imp LM client backed by the Elixir `req_llm` ecosystem.

  Imp owns signatures, adapters, optimizers, traces, and evaluation. `req_llm`
  owns provider/model resolution, Req/Finch transport, streaming, provider
  option translation, and canonical response structs.

  `:input_envelope` is an Imp-owned safety option. It accepts a positive
  `:max_bytes` guard and an optional positive `:reservation_tokens` value. Imp
  measures the rendered message content before cache lookup or transport,
  raises `Imp.OperationalSafetyError` when the byte guard is exceeded, and
  removes the envelope before calling ReqLLM. The token value records a pricing
  or capacity reservation; without a model tokenizer it is not treated as an
  exact token counter.

  Non-streaming HTTP 400 errors with the structured code
  `error.code = "context_length_exceeded"` become
  `Imp.ContextWindowExceededError`. Other provider errors retain their original
  shape; prose and generic HTTP 400 responses do not trigger context recovery.

  `:openrouter_reasoning` is an Imp-owned OpenRouter wire option for the
  documented nested `reasoning` object. It currently accepts exactly an
  `:effort` value and is removed before ReqLLM option validation. This avoids
  relying on ReqLLM's legacy top-level `reasoning_effort` encoding.
  """

  @behaviour Imp.LM

  require Logger

  # ── Provider-era-pinned constants ─────────────────────────────────────────
  # Both values below encode provider behavior as of a specific date and WILL
  # rot as providers ship new betas and model families. They are collected
  # here so there is one place to update.
  #
  # To update:
  # - @anthropic_structured_outputs_beta: check Anthropic's structured-outputs
  #   beta header name (docs.anthropic.com, "structured outputs"); replace the
  #   dated string when the beta graduates or is renamed.
  # - @openai_reasoning_model_pattern: add new OpenAI reasoning-model family
  #   prefixes as they ship. A model this regex misses is silently treated as
  #   a NON-reasoning model (:max_tokens is not renamed to
  #   :max_completion_tokens), which the provider then rejects or req_llm
  #   papers over with a per-call warning.
  #
  # A registry-driven replacement (deriving both from ReqLLM's model registry
  # instead of pinning) is the real fix and is out of scope here; see ticket
  # de-4hmp.
  @anthropic_structured_outputs_beta "structured-outputs-2025-11-13"
  @openai_reasoning_model_pattern ~r/^(gpt-5|o[134])(?:[-_:.].*)?$/

  defstruct model: nil,
            opts: [],
            req_module: ReqLLM

  @type t :: %__MODULE__{
          model: ReqLLM.model_input(),
          opts: keyword(),
          req_module: module()
        }

  @new_option_schema [
    req_module: [type: {:custom, __MODULE__, :validate_req_module, []}, default: ReqLLM],
    opts: [type: :keyword_list, default: []]
  ]

  def new(model_spec, opts \\ []) do
    {req_module, nested_opts} = validate_new_opts!(opts)

    merged_opts =
      nested_opts
      |> Keyword.merge(Keyword.drop(opts, [:opts, :req_module]))
      |> normalize_openrouter_reasoning_option!("#{inspect(__MODULE__)}.new/2")

    validate_input_envelope_option!(merged_opts, "#{inspect(__MODULE__)}.new/2")

    %__MODULE__{
      model: model_spec,
      opts: merged_opts,
      req_module: req_module
    }
  end

  def validate_req_module(module) when is_atom(module), do: {:ok, module}

  def validate_req_module(module) do
    {:error, "expected a ReqLLM-compatible module atom, got: #{inspect(module)}"}
  end

  @doc false
  # Response-format capability for this LM (internal), read from the ReqLLM/LLMDB
  # model registry (`Imp.LM.Capability`). This is Imp's analog of DSPy's
  # `litellm.get_supported_openai_params` / `litellm.supports_response_schema`:
  # DSPy delegates to litellm's registry, Imp delegates to ReqLLM's.
  #
  # The mapping from LLMDB's `capabilities.json` descriptor:
  #
  #   * `response_schema` := `json.schema` (structured Structured-Outputs support).
  #   * `response_format` := `json.native or json.schema` (the model accepts a
  #     `response_format` request param at all — either json-object mode or
  #     json-schema mode implies the param is accepted).
  #
  # When the registry has no `json` capability for a model (unknown / sparse
  # entry), this normally returns `Imp.LM.Capability.none/0` — no
  # `response_format` is sent. The exception is a native provider whose pinned
  # public contract owns structured generation independently of model metadata:
  # ReqLLM's Ollama provider unconditionally exposes JSON-schema
  # `generate_object/4`. This keeps unknown providers loud-by-omission while
  # avoiding a false downgrade for ordinary local Ollama model names.
  @spec response_format_capability(t()) :: Imp.LM.Capability.t()
  def response_format_capability(%__MODULE__{model: model_spec}) do
    case resolve_model(model_spec) do
      {:ok, model} ->
        response_format_capability(model, model_spec)

      {:error, reason} ->
        Logger.warning(
          "Imp: model registry lookup failed for #{inspect(model_spec)} " <>
            "(#{inspect(reason)}); assuming no structured-output capability " <>
            "(Capability.none) — no response_format will be sent"
        )

        Imp.LM.Capability.none()
    end
  end

  # ReqLLM's native Ollama provider owns JSON-schema constrained generation at
  # the provider layer, independently of LLMDB's per-model catalog. Its pinned
  # public `generate_object/4` path unconditionally constructs a json_schema
  # response format for Ollama's OpenAI-compatible endpoint. Local model names
  # are commonly absent from LLMDB, so consulting only `model.capabilities`
  # incorrectly downgraded this supported provider path to Capability.none and
  # left small local models to follow a prompt-only JSON/value contract.
  defp response_format_capability(%{provider: provider}, _model_spec)
       when provider in [:ollama, "ollama"],
       do: Imp.LM.Capability.json_schema()

  defp response_format_capability(model, _model_spec) do
    case json_capability(model) do
      %{} = json ->
        schema? = truthy?(Map.get(json, :schema))
        native? = truthy?(Map.get(json, :native))
        %Imp.LM.Capability{response_format: native? or schema?, response_schema: schema?}

      _no_json_entry ->
        # Documented loud-by-omission: the registry resolved the model but
        # does not advertise a `json` capability, so no response_format is
        # sent. Provider-owned guarantees (currently native Ollama) are handled
        # above; all other unknown providers remain fail-closed.
        Imp.LM.Capability.none()
    end
  end

  defp resolve_model(%{capabilities: _} = model), do: {:ok, model}

  defp resolve_model(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> {:ok, model}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_registry_result, other}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp json_capability(%{capabilities: %{json: json}}) when is_map(json), do: json
  defp json_capability(_model), do: nil

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  @doc false
  def reasoning_capability(%__MODULE__{model: model_spec}) do
    case resolve_model(model_spec) do
      {:ok, model} ->
        capabilities = Map.get(model, :capabilities) || %{}
        reasoning = Map.get(capabilities, :reasoning) || %{}
        truthy?(Map.get(reasoning, :enabled, false))

      {:error, _reason} ->
        false
    end
  end

  @doc false
  def configured_option(%__MODULE__{opts: opts}, key), do: Keyword.fetch(opts, key)

  @impl true
  def request(%__MODULE__{} = lm, %Imp.Core.LMRequest{} = request) do
    {messages, opts} = Imp.Core.request_parts(request)

    with {:ok, raw} <- generate(lm, messages, opts),
         {:ok, response} <- Imp.Core.response(raw) do
      {:ok, response}
    end
  end

  @impl true
  def generate(messages, opts) do
    opts = validate_call_opts!(opts, "#{inspect(__MODULE__)}.generate/2")

    case Keyword.fetch(opts, :model) do
      {:ok, model} -> generate(new(model, opts), messages, opts)
      :error -> {:error, :req_llm_model_required}
    end
  end

  def generate(%__MODULE__{} = lm, messages, opts) do
    opts = validate_call_opts!(opts, "#{inspect(__MODULE__)}.generate/3")

    {rollout_id, opts} =
      lm.opts
      |> Keyword.merge(opts)
      |> normalize_openrouter_reasoning_option!("#{inspect(__MODULE__)}.generate/3")
      |> Keyword.pop(:rollout_id)

    {input_envelope, opts} = Keyword.pop(opts, :input_envelope)
    enforce_input_envelope!(messages, input_envelope)

    opts =
      opts
      |> normalize_opts()
      |> normalize_provider_profile_opts(lm.model)

    cache? = Keyword.get(opts, :cache, true)
    opts = Keyword.delete(opts, :cache)
    cache_key = cache_key(lm, messages, maybe_put_rollout_id(opts, rollout_id))

    case Keyword.get(opts, :n, 1) do
      n when is_integer(n) and n > 1 ->
        # LOUD by design: req_llm's canonical ReqLLM.Response surfaces only the
        # first choice (its decoders drop `choices[1..]` and strip "choices"
        # from provider_meta), so a single n=K request cannot return K
        # completions here. Passing :n through and returning one completion
        # would be a silent 1-of-K fallback. Multi-completion works with LMs
        # that honor the list contract (for example Imp.LM.Static).
        {:error,
         {:multi_completion_unsupported, __MODULE__,
          "n=#{n} multi-completion is not supported over the req_llm client: " <>
            "ReqLLM.Response carries only the first choice, so the other " <>
            "#{n - 1} completions would be silently dropped"}}

      _single ->
        if cache? do
          generate_cached(lm, messages, opts, cache_key)
        else
          generate_uncached(lm, messages, opts)
        end
    end
  end

  defp generate_cached(lm, messages, opts, cache_key) do
    case Imp.Cache.get(cache_key, :__missing__) do
      :__missing__ ->
        Imp.Telemetry.execute([:imp, :cache, :miss], %{count: 1}, %{key: cache_key})

        case generate_uncached(lm, messages, opts) do
          {:ok, _value} = success ->
            Imp.Cache.put(cache_key, success)
            success

          {:error, _reason} = error ->
            error
        end

      value ->
        Imp.Telemetry.execute([:imp, :cache, :hit], %{count: 1}, %{key: cache_key})
        cache_hit_result(value)
    end
  end

  defp cache_hit_result(
         {:ok,
          %{
            __imp_lm_output__: output,
            __imp_lm_metadata__: metadata
          }}
       ) do
    {:ok,
     %{
       __imp_lm_output__: output,
       __imp_lm_metadata__: mark_cache_hit(metadata)
     }}
  end

  defp cache_hit_result(
         {:ok,
          %{
            "__imp_lm_output__" => output,
            "__imp_lm_metadata__" => metadata
          }}
       ) do
    {:ok,
     %{
       "__imp_lm_output__" => output,
       "__imp_lm_metadata__" => mark_cache_hit(metadata)
     }}
  end

  defp cache_hit_result(value), do: value

  defp mark_cache_hit(%{req_llm: provider_meta} = metadata) when is_map(provider_meta) do
    provider_meta = provider_meta |> Map.put(:usage, %{}) |> Map.put(:cache_hit, true)
    Map.put(metadata, :req_llm, provider_meta)
  end

  defp mark_cache_hit(%{"req_llm" => provider_meta} = metadata) when is_map(provider_meta) do
    provider_meta = provider_meta |> Map.put("usage", %{}) |> Map.put("cache_hit", true)
    Map.put(metadata, "req_llm", provider_meta)
  end

  defp mark_cache_hit(metadata), do: Map.put(metadata, :cache_hit, true)

  defp generate_uncached(lm, messages, opts) do
    Imp.Telemetry.span([:imp, :lm], %{lm: redact_lm(lm)}, fn ->
      do_generate_uncached(lm, messages, opts)
    end)
  end

  defp do_generate_uncached(lm, messages, opts) do
    opts =
      opts
      |> prepare_openrouter_reasoning!(lm.model)
      |> cap_transport_timeouts()
      |> enforce_explicit_no_retry()

    case lm.req_module.generate_text(lm.model, to_req_messages(messages), opts) do
      {:ok, response} ->
        {:ok, from_response(response, lm.model)}

      {:error, reason} ->
        {:error, normalize_context_refusal(reason)}

      other ->
        {:error, {:invalid_req_llm_response, inspect(other)}}
    end
  rescue
    error -> {:error, {:req_llm_generate_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:req_llm_generate_failed, error_message({kind, reason})}}
  end

  # OpenAI-compatible providers name this refusal in the structured error code.
  # General HTTP 400s and prose mentioning context are not safe retry signals.
  defp normalize_context_refusal(
         %ReqLLM.Error.API.Request{status: 400, response_body: body} = error
       ) do
    body =
      if is_binary(body) do
        case Jason.decode(body) do
          {:ok, decoded} -> decoded
          _ -> nil
        end
      else
        body
      end

    case body do
      %{"error" => %{"code" => "context_length_exceeded"}} ->
        %Imp.ContextWindowExceededError{
          message: "Provider refused the input context length",
          reason: %{status: 400, code: "context_length_exceeded"}
        }

      _ ->
        error
    end
  end

  defp normalize_context_refusal(error), do: error

  def cache_key(%__MODULE__{} = lm, messages, opts) do
    opts = validate_call_opts!(opts, "#{inspect(__MODULE__)}.cache_key/3")

    identity = {
      lm.req_module,
      cache_identity_value(lm.model),
      to_req_messages(messages),
      cache_identity_options(opts)
    }

    {:lm_response,
     :crypto.hash(
       :sha256,
       :erlang.term_to_binary(identity, [:deterministic])
     )
     |> Base.encode16(case: :lower)}
  end

  defp cache_identity_options(opts) do
    Enum.map(opts, fn {key, value} ->
      {key, cache_identity_field(key, value)}
    end)
  end

  defp cache_identity_field(key, value) do
    if Imp.Redaction.credential_entry?(key, value) do
      credential_cache_discriminator(value)
    else
      cache_identity_value(value)
    end
  end

  # Credentials never enter cache identity as raw values, but they must still
  # discriminate: two callers with different API keys must not share cached
  # responses (cross-account aliasing). A one-way fingerprint keeps the secret
  # out of key material while scoping the cache per credential.
  defp credential_cache_discriminator(value) do
    fingerprint =
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

    {:imp_cache_identity, :credential, fingerprint}
  end

  defp cache_identity_value(%_{} = struct) do
    {:struct, struct.__struct__, struct |> Map.from_struct() |> cache_identity_value()}
  end

  defp cache_identity_value(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, cache_identity_field(key, value)} end)
  end

  defp cache_identity_value([key, value]) when is_atom(key) or is_binary(key) or is_map(key) do
    [key, cache_identity_field(key, value)]
  end

  defp cache_identity_value(list) when is_list(list) do
    if Keyword.keyword?(list) do
      cache_identity_options(list)
    else
      Enum.map(list, &cache_identity_value/1)
    end
  end

  defp cache_identity_value({key, value})
       when is_atom(key) or is_binary(key) or is_map(key) do
    {key, cache_identity_field(key, value)}
  end

  defp cache_identity_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&cache_identity_value/1)
    |> List.to_tuple()
  end

  defp cache_identity_value(value), do: value

  def generate_async(%__MODULE__{} = lm, messages, opts \\ []) do
    opts = validate_call_opts!(opts, "#{inspect(__MODULE__)}.generate_async/3")

    Imp.Tasks.async(fn -> generate(lm, messages, opts) end)
  end

  @impl true
  def stream(%__MODULE__{} = lm, messages, opts \\ []) do
    opts = validate_call_opts!(opts, "#{inspect(__MODULE__)}.stream/3")

    {_rollout_id, opts} =
      lm.opts
      |> Keyword.merge(opts)
      |> normalize_openrouter_reasoning_option!("#{inspect(__MODULE__)}.stream/3")
      |> Keyword.pop(:rollout_id)

    {input_envelope, opts} = Keyword.pop(opts, :input_envelope)
    enforce_input_envelope!(messages, input_envelope)

    opts =
      opts
      |> normalize_opts()
      |> normalize_stream_cache()
      |> normalize_provider_profile_opts(lm.model)

    normalize_stream(lm, messages, opts)
  end

  # Imp's public boolean controls the Imp response cache. ReqLLM's :cache
  # option instead expects a backend module. Streaming cannot replay Imp cache
  # entries incrementally, so remove only the booleans and preserve an explicit
  # ReqLLM backend when a caller supplies one.
  defp normalize_stream_cache(opts) do
    case Keyword.fetch(opts, :cache) do
      {:ok, value} when is_boolean(value) -> Keyword.delete(opts, :cache)
      _other -> opts
    end
  end

  defp safe_stream(lm, messages, opts) do
    opts =
      opts
      |> prepare_openrouter_reasoning!(lm.model)
      |> cap_transport_timeouts()
      |> enforce_explicit_no_retry()

    case lm.req_module.stream_text(lm.model, to_req_messages(messages), opts) do
      {:ok, %ReqLLM.StreamResponse{} = response} -> {:ok, response}
      {:ok, other} -> {:error, {:invalid_req_llm_stream, inspect(other)}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_req_llm_stream, inspect(other)}}
    end
  rescue
    error -> {:error, {:req_llm_stream_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:req_llm_stream_failed, error_message({kind, reason})}}
  end

  def dump(%__MODULE__{} = lm) do
    model = lm.model |> encode_model() |> Imp.Redaction.drop_credentials()
    opts = Imp.Redaction.drop_credentials(lm.opts)

    %{
      provider: :req_llm,
      model: model,
      opts: Enum.map(opts, fn {key, value} -> [Atom.to_string(key), value] end)
    }
  end

  defp validate_new_opts!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.new/2 expects keyword options, got: #{inspect(opts)}"
    end

    owned_opts =
      opts
      |> Keyword.take([:req_module, :opts])
      |> Imp.Options.validate!(@new_option_schema, "#{inspect(__MODULE__)}.new/2")

    {Keyword.fetch!(owned_opts, :req_module), Keyword.fetch!(owned_opts, :opts)}
  end

  defp validate_new_opts!(opts) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.new/2 expects keyword options, got: #{inspect(opts)}"
  end

  defp validate_call_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      validate_input_envelope_option!(opts, context)
      normalize_openrouter_reasoning_option!(opts, context)
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_call_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end

  defp validate_input_envelope_option!(opts, context) do
    case Keyword.fetch(opts, :input_envelope) do
      :error -> :ok
      {:ok, value} -> validate_input_envelope!(value, context)
    end
  end

  defp normalize_openrouter_reasoning_option!(opts, context) do
    case Keyword.get_values(opts, :openrouter_reasoning) do
      [] ->
        opts

      [reasoning] ->
        normalized = normalize_openrouter_reasoning!(reasoning, context)

        if Keyword.has_key?(opts, :reasoning_effort) do
          raise ArgumentError,
                "#{context}: :openrouter_reasoning cannot be combined with :reasoning_effort"
        end

        Keyword.put(opts, :openrouter_reasoning, normalized)

      _values ->
        raise ArgumentError, "#{context}: duplicate :openrouter_reasoning options"
    end
  end

  defp normalize_openrouter_reasoning!(reasoning, context) when is_list(reasoning) do
    if Keyword.keyword?(reasoning) do
      keys = Keyword.keys(reasoning)

      if length(keys) != length(Enum.uniq(keys)) do
        raise ArgumentError, "#{context}: :openrouter_reasoning contains duplicate keys"
      end

      normalize_openrouter_reasoning!(Map.new(reasoning), context)
    else
      raise ArgumentError,
            "#{context}: :openrouter_reasoning must be a map or keyword list"
    end
  end

  defp normalize_openrouter_reasoning!(reasoning, context) when is_map(reasoning) do
    entries = Enum.map(reasoning, fn {key, value} -> {to_string(key), value} end)

    if length(entries) != length(Enum.uniq_by(entries, &elem(&1, 0))) do
      raise ArgumentError, "#{context}: :openrouter_reasoning contains duplicate keys"
    end

    reasoning = Map.new(entries)

    case reasoning do
      %{"effort" => effort} when map_size(reasoning) == 1 ->
        effort = to_string(effort)

        if effort in ~w(none minimal low medium high xhigh max) do
          %{"effort" => effort}
        else
          raise ArgumentError,
                "#{context}: :openrouter_reasoning :effort is unsupported: #{inspect(effort)}"
        end

      _ ->
        raise ArgumentError,
              "#{context}: :openrouter_reasoning requires exactly :effort"
    end
  end

  defp normalize_openrouter_reasoning!(reasoning, context) do
    raise ArgumentError,
          "#{context}: :openrouter_reasoning must be a map or keyword list, got: #{inspect(reasoning)}"
  end

  defp prepare_openrouter_reasoning!(opts, model_spec) do
    case Keyword.pop(opts, :openrouter_reasoning) do
      {nil, opts} ->
        opts

      {reasoning, opts} ->
        reasoning = normalize_openrouter_reasoning!(reasoning, "Imp OpenRouter request")

        unless openrouter_model?(model_spec) do
          raise ArgumentError,
                ":openrouter_reasoning is supported only for an OpenRouter model"
        end

        http_opts = Keyword.get(opts, :req_http_options, [])
        plugins = Keyword.get(http_opts, :plugins, [])

        plugin = fn request ->
          Req.Request.append_request_steps(
            request,
            imp_openrouter_reasoning_wire: {
              __MODULE__,
              :prepare_openrouter_reasoning_wire,
              [reasoning]
            }
          )
        end

        Keyword.put(
          opts,
          :req_http_options,
          Keyword.put(http_opts, :plugins, plugins ++ [plugin])
        )
    end
  end

  defp openrouter_model?(%{provider: provider}) when provider in [:openrouter, "openrouter"],
    do: true

  defp openrouter_model?(model) when is_binary(model),
    do: String.starts_with?(model, "openrouter:")

  defp openrouter_model?(_model), do: false

  @doc false
  def prepare_openrouter_reasoning_wire(%Req.Request{} = request, reasoning) do
    body = request.body |> IO.iodata_to_binary() |> Jason.decode!()

    if Map.has_key?(body, "reasoning_effort") or Map.has_key?(body, "reasoning") do
      raise ArgumentError, "OpenRouter reasoning wire field is ambiguous"
    end

    %{request | body: Jason.encode!(Map.put(body, "reasoning", reasoning))}
  end

  defp validate_input_envelope!(envelope, context) when is_list(envelope) do
    unless Keyword.keyword?(envelope) do
      raise ArgumentError,
            "#{context}: :input_envelope must be a keyword list, got: #{inspect(envelope)}"
    end

    keys = Keyword.keys(envelope)
    unknown = keys -- [:max_bytes, :reservation_tokens]

    cond do
      length(keys) != length(Enum.uniq(keys)) ->
        raise ArgumentError, "#{context}: :input_envelope contains duplicate keys"

      unknown != [] ->
        raise ArgumentError,
              "#{context}: :input_envelope has unsupported keys: #{inspect(unknown)}"

      not Keyword.has_key?(envelope, :max_bytes) ->
        raise ArgumentError, "#{context}: :input_envelope requires :max_bytes"

      not positive_integer?(envelope[:max_bytes]) ->
        raise ArgumentError,
              "#{context}: :input_envelope :max_bytes must be a positive integer"

      Keyword.has_key?(envelope, :reservation_tokens) and
          not positive_integer?(envelope[:reservation_tokens]) ->
        raise ArgumentError,
              "#{context}: :input_envelope :reservation_tokens must be a positive integer"

      true ->
        :ok
    end
  end

  defp validate_input_envelope!(value, context) do
    raise ArgumentError,
          "#{context}: :input_envelope must be a keyword list, got: #{inspect(value)}"
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp enforce_input_envelope!(_messages, nil), do: :ok

  defp enforce_input_envelope!(messages, envelope) do
    actual_bytes = rendered_message_bytes(messages)
    max_bytes = Keyword.fetch!(envelope, :max_bytes)

    if actual_bytes > max_bytes do
      raise Imp.OperationalSafetyError,
        kind: :budget,
        reason: %{
          boundary: :req_llm_input_envelope,
          actual_bytes: actual_bytes,
          max_bytes: max_bytes,
          reservation_tokens: Keyword.get(envelope, :reservation_tokens)
        },
        message:
          "ReqLLM input envelope exceeded before transport: rendered message content " <>
            "was #{actual_bytes} bytes, limit is #{max_bytes} bytes"
    end

    :ok
  end

  defp rendered_message_bytes(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + rendered_value_bytes(message) end)
  end

  defp rendered_message_bytes(value), do: rendered_value_bytes(value)

  defp rendered_value_bytes(value) when is_binary(value), do: byte_size(value)

  defp rendered_value_bytes(%_{} = struct) do
    struct |> Map.from_struct() |> rendered_value_bytes()
  end

  defp rendered_value_bytes(value) when is_map(value) do
    Enum.reduce(value, 0, fn {_key, nested}, total ->
      total + rendered_value_bytes(nested)
    end)
  end

  defp rendered_value_bytes(value) when is_list(value) do
    Enum.reduce(value, 0, fn nested, total -> total + rendered_value_bytes(nested) end)
  end

  defp rendered_value_bytes(value) when is_tuple(value) do
    value |> Tuple.to_list() |> rendered_value_bytes()
  end

  defp rendered_value_bytes(_value), do: 0

  defp maybe_put_rollout_id(opts, nil), do: opts
  defp maybe_put_rollout_id(opts, rollout_id), do: Keyword.put(opts, :rollout_id, rollout_id)

  defp to_req_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} = message ->
        build_message(
          role,
          content,
          Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
        )

      # Messages that went through a JSON round trip (ReqLLMBatch checkpoints,
      # anything decoded from disk or the wire) arrive with string keys and
      # string roles. Normalize the known message keys explicitly; unknown keys
      # are never atomized.
      %{"role" => role, "content" => content} = message ->
        build_message(
          role,
          content,
          Map.get(message, "tool_calls") || Map.get(message, :tool_calls)
        )

      other ->
        ReqLLM.Context.user(inspect(other))
    end)
  end

  defp build_message(role, content, tool_calls) do
    case normalize_role(role) do
      :system ->
        ReqLLM.Context.system(content_to_req(content))

      :assistant ->
        ReqLLM.Context.assistant(content_to_req(content),
          tool_calls: normalize_tool_calls(tool_calls)
        )

      :tool ->
        ReqLLM.Context.tool_result(tool_call_id(tool_calls), content_to_text(content))

      :user ->
        ReqLLM.Context.user(content_to_req(content))

      other ->
        # The coercion to :user is kept (DSPy does the same), but it must be
        # visible: an unknown role means the caller built a message we do not
        # understand. Warn once per distinct role, not per message.
        warn_unknown_role_once(other)
        ReqLLM.Context.user(content_to_req(content))
    end
  end

  defp normalize_role(role) when is_atom(role), do: role

  defp normalize_role(role) when is_binary(role) do
    String.to_existing_atom(role)
  rescue
    # Unknown string role (no such atom): return it as-is so the catch-all
    # branch above warns and coerces to :user. Never atomizes unknown input.
    ArgumentError -> role
  end

  defp normalize_role(role), do: role

  defp warn_unknown_role_once(role) do
    key = {__MODULE__, :unknown_role_warned, role}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "Imp: unknown message role #{inspect(role)} coerced to :user " <>
          "(known roles: :system, :assistant, :tool, :user); " <>
          "warning once per distinct role"
      )
    end
  end

  defp content_to_req(content) when is_binary(content), do: content

  defp content_to_req(content) when is_list(content) do
    content
    |> Enum.flat_map(&content_part/1)
  end

  defp content_to_req(content), do: content_to_text(content)

  defp content_part(%Imp.Adapter.Types.Image{url: url, metadata: metadata}) when is_binary(url),
    do: [ReqLLM.Message.ContentPart.image_url(url, metadata)]

  defp content_part(%Imp.Adapter.Types.Image{
         data: data,
         mime_type: mime_type,
         metadata: metadata
       })
       when is_binary(data),
       do: [
         ReqLLM.Message.ContentPart.image(
           Imp.Adapter.Types.decode_data!(data, "image"),
           mime_type || "image/png",
           metadata
         )
       ]

  defp content_part(%Imp.Adapter.Types.File{
         data: data,
         filename: filename,
         mime_type: mime_type,
         metadata: metadata
       })
       when is_binary(data),
       do: [
         data
         |> Imp.Adapter.Types.decode_data!("file")
         |> ReqLLM.Message.ContentPart.file(
           filename || "attachment",
           mime_type || "application/octet-stream"
         )
         |> Map.put(:metadata, metadata)
       ]

  defp content_part(%Imp.Adapter.Types.File{file_id: file_id} = file)
       when is_binary(file_id) do
    [
      file_id
      |> ReqLLM.Message.ContentPart.file_id(file.mime_type || "application/pdf", file.metadata)
      |> Map.put(:filename, file.filename)
    ]
  end

  defp content_part(%Imp.Adapter.Types.File{path: path}) when is_binary(path) do
    raise ArgumentError,
          "Imp.Adapter.Types.File does not read deferred paths; use Imp.Adapter.Types.File.from_path/2"
  end

  defp content_part(%Imp.Adapter.Types.File{url: url}) when is_binary(url) do
    raise ArgumentError,
          "ReqLLM file URL attachments are not portable; load trusted bytes explicitly or use File.from_file_id/2: #{inspect(url)}"
  end

  defp content_part(%Imp.Adapter.Types.Audio{data: data, mime_type: mime_type})
       when is_binary(data),
       do: [
         ReqLLM.Message.ContentPart.file(
           Imp.Adapter.Types.decode_data!(data, "audio"),
           audio_filename(mime_type || "audio/wav"),
           mime_type || "audio/wav"
         )
       ]

  defp content_part(%Imp.Adapter.Types.Document{text: text}),
    do: [ReqLLM.Message.ContentPart.text(to_string(text))]

  defp content_part(%Imp.Adapter.Types.Code{code: code, language: language}),
    do: [ReqLLM.Message.ContentPart.text("```#{language || ""}\n#{code}\n```")]

  defp content_part(%Imp.Adapter.Types.Reasoning{text: text}),
    do: [ReqLLM.Message.ContentPart.thinking(to_string(text))]

  defp content_part(value) when is_binary(value), do: [ReqLLM.Message.ContentPart.text(value)]
  defp content_part(value), do: [ReqLLM.Message.ContentPart.text(inspect(value))]

  defp content_to_text(content) when is_binary(content), do: content

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      value when is_binary(value) -> value
      %Imp.Adapter.Types.Document{text: text} -> to_string(text)
      %Imp.Adapter.Types.Code{code: code} -> to_string(code)
      %Imp.Adapter.Types.Reasoning{text: text} -> to_string(text)
      value -> inspect(value)
    end)
  end

  defp content_to_text(content), do: inspect(content)

  defp audio_filename(mime_type) do
    format =
      mime_type
      |> String.split("/", parts: 2)
      |> List.last()
      |> String.split(";", parts: 2)
      |> hd()
      |> String.replace_prefix("x-", "")

    "audio.#{format}"
  end

  defp normalize_tool_calls(nil), do: nil

  defp normalize_tool_calls(%Imp.Adapter.Types.ToolCalls{tool_calls: tool_calls}),
    do: normalize_tool_calls(tool_calls)

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &normalize_tool_call/1)
  end

  defp normalize_tool_calls(other), do: other

  defp normalize_tool_call(%ReqLLM.ToolCall{} = call), do: call

  defp normalize_tool_call(%Imp.Adapter.Types.ToolCall{} = call) do
    ReqLLM.ToolCall.new(
      tool_call_id(call),
      to_string(call.name),
      Jason.encode!(call.arguments || %{})
    )
  end

  defp normalize_tool_call(%{function: _function} = call),
    do: call |> Imp.Adapter.Types.ToolCall.from_map() |> normalize_tool_call()

  defp normalize_tool_call(%{"function" => _function} = call),
    do: call |> Imp.Adapter.Types.ToolCall.from_map() |> normalize_tool_call()

  defp normalize_tool_call(%{id: id, name: name, arguments: arguments}) do
    ReqLLM.ToolCall.new(
      id || tool_call_id(name),
      to_string(name),
      Jason.encode!(arguments || %{})
    )
  end

  defp normalize_tool_call(%{"id" => id, "name" => name, "arguments" => arguments}) do
    ReqLLM.ToolCall.new(
      id || tool_call_id(name),
      to_string(name),
      Jason.encode!(arguments || %{})
    )
  end

  defp normalize_tool_call(%{id: id, name: name, args: arguments}) do
    ReqLLM.ToolCall.new(
      id || tool_call_id(name),
      to_string(name),
      Jason.encode!(arguments || %{})
    )
  end

  defp normalize_tool_call(%{"id" => id, "name" => name, "args" => arguments}) do
    ReqLLM.ToolCall.new(
      id || tool_call_id(name),
      to_string(name),
      Jason.encode!(arguments || %{})
    )
  end

  defp normalize_tool_call(other), do: other

  defp tool_call_id([%{id: id} | _]), do: id
  defp tool_call_id([%{"id" => id} | _]), do: id
  defp tool_call_id(%Imp.Adapter.Types.ToolCall{id: id}) when not is_nil(id), do: id
  defp tool_call_id(name) when is_atom(name) or is_binary(name), do: "call_#{name}"
  defp tool_call_id(_), do: "tool_result"

  defp normalize_opts(opts) do
    opts
    |> Keyword.drop([
      :model,
      :req_module,
      :json_retries,
      :native_json_schema
    ])
    |> rename_timeout()
    |> normalize_numeric_opts()
    |> normalize_tools()
  end

  defp rename_timeout(opts) do
    case Keyword.pop(opts, :timeout) do
      {nil, opts} -> opts
      {timeout, opts} -> Keyword.put_new(opts, :receive_timeout, timeout)
    end
  end

  defp cap_transport_timeouts(opts) do
    case Imp.Deadline.current() do
      :infinity ->
        opts

      deadline ->
        remaining = Imp.Deadline.remaining(deadline)

        # Cap :connect_options only when the caller supplied it — ReqLLM's
        # option schema rejects the key, so fabricating it here made every
        # deadline-bearing call fail validation (GEPA reflection was the
        # only such caller and was undrivable live). The :receive_timeout
        # cap alone bounds the call end to end.
        opts
        |> cap_timeout(:receive_timeout, remaining)
        |> then(fn capped ->
          if Keyword.has_key?(capped, :connect_options) do
            Keyword.update!(capped, :connect_options, &cap_timeout(&1, :timeout, remaining))
          else
            capped
          end
        end)
    end
  end

  # ReqLLM 1.17.1 attaches its retry step after constructing the Req request and
  # resets `max_retries` to 3. Re-apply an explicit caller no-retry policy in a
  # final request step, at the adapter boundary, where it cannot be overwritten.
  # The attempt event is emitted immediately before the actual Req adapter call,
  # so it counts transports rather than Imp calls or ReqLLM lifecycle contexts.
  defp enforce_explicit_no_retry(opts) do
    http_opts = Keyword.get(opts, :req_http_options, [])

    explicit? =
      Keyword.get(opts, :max_retries) == 0 or
        (Keyword.keyword?(http_opts) and
           (Keyword.get(http_opts, :retry) == false or
              Keyword.get(http_opts, :max_retries) == 0))

    if explicit? do
      unless Keyword.keyword?(http_opts) do
        raise ArgumentError, "ReqLLM :req_http_options must be a keyword list"
      end

      plugins = Keyword.get(http_opts, :plugins, [])

      unless is_list(plugins) do
        raise ArgumentError, "ReqLLM :req_http_options :plugins must be a list"
      end

      plugin = &__MODULE__.install_explicit_no_retry/1
      guarded_http_opts = Keyword.put(http_opts, :plugins, plugins ++ [plugin])
      Keyword.put(opts, :req_http_options, guarded_http_opts)
    else
      opts
    end
  end

  @doc false
  def install_explicit_no_retry(%Req.Request{} = request) do
    Req.Request.append_request_steps(request,
      imp_explicit_no_retry: &__MODULE__.enforce_explicit_no_retry_request/1
    )
  end

  @doc false
  def enforce_explicit_no_retry_request(%Req.Request{} = request) do
    adapter = request.adapter

    guarded_adapter = fn guarded_request ->
      Imp.Telemetry.execute(
        [:imp, :lm, :transport, :attempt],
        %{count: 1, system_time: System.system_time()},
        %{method: guarded_request.method, retry: false}
      )

      case adapter do
        adapter when is_function(adapter, 1) ->
          adapter.(guarded_request)

        adapter when is_atom(adapter) ->
          adapter.run(guarded_request)

        {module, function, args}
        when is_atom(module) and is_atom(function) and is_list(args) ->
          apply(module, function, [guarded_request | args])
      end
    end

    request
    |> Req.Request.merge_options(retry: false, max_retries: 0)
    |> Map.put(:adapter, guarded_adapter)
  end

  defp cap_timeout(opts, key, remaining) do
    Keyword.update(opts, key, remaining, fn
      timeout when is_integer(timeout) -> min(timeout, remaining)
      :infinity -> remaining
      other -> other
    end)
  end

  defp normalize_numeric_opts(opts) do
    Enum.reduce([:temperature, :top_p, :frequency_penalty, :presence_penalty], opts, fn key,
                                                                                        acc ->
      Keyword.update(acc, key, nil, fn
        value when is_integer(value) -> value / 1
        value -> value
      end)
    end)
    |> Enum.reject(&match?({_key, nil}, &1))
  end

  defp normalize_response_format(opts, model) do
    case Keyword.pop(opts, :response_format) do
      {nil, opts} ->
        opts

      {format, opts} ->
        put_response_format(opts, model, format)
    end
  end

  defp put_response_format(opts, model, format) do
    cond do
      anthropic_model?(model) ->
        put_anthropic_response_format(opts, format)

      true ->
        Keyword.update(opts, :provider_options, [response_format: format], fn provider_opts ->
          Keyword.put(provider_opts, :response_format, format)
        end)
    end
  end

  defp put_anthropic_response_format(opts, %{type: "json_schema", json_schema: json_schema}) do
    schema = json_schema[:schema] || json_schema["schema"] || json_schema

    Keyword.update(
      opts,
      :provider_options,
      [
        anthropic_beta: [@anthropic_structured_outputs_beta],
        output_format: %{type: "json_schema", schema: schema}
      ],
      fn provider_opts ->
        provider_opts
        |> Keyword.update(:anthropic_beta, [@anthropic_structured_outputs_beta], fn betas ->
          [@anthropic_structured_outputs_beta | List.wrap(betas)]
        end)
        |> Keyword.put(:output_format, %{type: "json_schema", schema: schema})
        |> Keyword.delete(:response_format)
      end
    )
  end

  defp put_anthropic_response_format(opts, _format) do
    Keyword.update(opts, :provider_options, [], &Keyword.delete(&1, :response_format))
  end

  defp normalize_tools(opts) do
    Keyword.update(opts, :tools, [], fn tools ->
      Enum.map(tools, &normalize_tool/1)
    end)
  end

  defp normalize_provider_profile_opts(opts, model) do
    opts = normalize_response_format(opts, model)

    if openai_reasoning_model?(model) do
      opts
      |> rename_max_tokens_for_reasoning(model)
      |> Keyword.drop([:temperature, :top_p, :frequency_penalty, :presence_penalty])
    else
      opts
    end
  end

  # Reasoning models use `:max_completion_tokens`, not `:max_tokens`. If we hand
  # `:max_tokens` (or no token limit at all) to req_llm, it injects/renames the
  # option itself and logs a `[warning] Renamed :max_tokens ...` line on every
  # request — twice, once per prepare pass. We pre-normalize here so req_llm never
  # sees `:max_tokens` for these models and stays quiet.
  #
  # Wire-neutrality is load-bearing: we must send the SAME request req_llm would.
  # On the text/stream path req_llm resolves its own default with
  # `put_model_max_tokens_default(opts, model)` — NO fallback (see
  # `ReqLLM.Provider.Options.maybe_extract_max_tokens/2`): it seeds the model's
  # output limit when one exists and otherwise leaves the request uncapped. We call
  # the exact same helper with the exact same (fallback-free) semantics, differing
  # only in the target key — which is precisely what req_llm's rename step would
  # have produced. A `fallback:` here would silently cap models that req_llm leaves
  # uncapped, so it is deliberately omitted.
  defp rename_max_tokens_for_reasoning(opts, model) do
    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)

    cond do
      Keyword.has_key?(opts, :max_completion_tokens) ->
        opts

      not is_nil(max_tokens) ->
        Logger.debug(fn ->
          "Imp: renamed :max_tokens to :max_completion_tokens for reasoning model " <>
            inspect(model_id(model))
        end)

        Keyword.put(opts, :max_completion_tokens, max_tokens)

      true ->
        ReqLLM.Provider.Options.put_model_max_tokens_default(opts, model,
          key: :max_completion_tokens
        )
    end
  end

  defp openai_reasoning_model?(model) do
    id = model |> model_id() |> String.downcase()

    model_provider(model) == :openai and
      (String.match?(id, @openai_reasoning_model_pattern) or
         String.contains?(id, "reasoning"))
  end

  defp anthropic_model?(model) do
    model_provider(model) == :anthropic
  end

  defp model_provider(%{provider: provider}), do: normalize_provider(provider)
  defp model_provider(%{"provider" => provider}), do: normalize_provider(provider)
  defp model_provider({provider, _model}) when is_atom(provider), do: provider
  defp model_provider({provider, _model, _opts}) when is_atom(provider), do: provider

  defp model_provider(model) when is_binary(model) do
    model
    |> String.split(":", parts: 2)
    |> List.first()
    |> normalize_provider()
  end

  defp model_provider(_model), do: nil

  defp model_id(%{provider_model_id: id}) when is_binary(id), do: id
  defp model_id(%{"provider_model_id" => id}) when is_binary(id), do: id
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(%{model: id}) when is_binary(id), do: id
  defp model_id(%{"model" => id}) when is_binary(id), do: id
  defp model_id({_provider, id}) when is_binary(id), do: id
  defp model_id({_provider, id, _opts}) when is_binary(id), do: id

  defp model_id(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, id] -> id
      [id] -> id
    end
  end

  defp model_id(_model), do: ""

  defp normalize_provider(provider) when is_atom(provider), do: provider

  defp normalize_provider(provider) when is_binary(provider) do
    case String.downcase(provider) do
      "openai" -> :openai
      "anthropic" -> :anthropic
      _other -> nil
    end
  end

  defp normalize_provider(_provider), do: nil

  defp normalize_tool(%ReqLLM.Tool{} = tool), do: tool

  defp normalize_tool(%{function: function}), do: tool_from_openai_function(function)
  defp normalize_tool(%{"function" => function}), do: tool_from_openai_function(function)
  defp normalize_tool(other), do: other

  defp tool_from_openai_function(function) do
    ReqLLM.Tool.new!(
      name: function[:name] || function["name"],
      description: function[:description] || function["description"] || "",
      parameter_schema: function[:parameters] || function["parameters"] || %{"type" => "object"},
      callback: fn _args -> {:ok, "tool result is handled by Imp"} end
    )
  end

  defp from_response(%ReqLLM.Response{} = response, model_spec) do
    raw =
      case ReqLLM.Response.tool_calls(response) do
        [] ->
          response.object || ReqLLM.Response.text(response) || ""

        tool_calls ->
          %{tool_calls: Enum.map(tool_calls, &ReqLLM.ToolCall.from_map/1)}
      end

    metadata =
      response
      |> native_reasoning_metadata()
      |> Map.put(:req_llm, response_metadata(response, model_spec))

    if Enum.empty?(metadata) do
      raw
    else
      %{__imp_lm_output__: raw, __imp_lm_metadata__: metadata}
    end
  end

  defp from_response(other, _model_spec), do: other

  defp response_metadata(%ReqLLM.Response{} = response, model_spec) do
    provider_meta = response.provider_meta || %{}
    logprobs = sanitize_logprobs(map_value(provider_meta, :logprobs))

    %{
      provider: provider_name(model_spec),
      model: response.model,
      api: map_value(provider_meta, :api_type),
      finish_reason: response.finish_reason,
      usage: sanitize_usage(response.usage),
      content: ReqLLM.Response.text(response) || "",
      logprobs: logprobs,
      provider_meta: sanitize_provider_meta(provider_meta, logprobs)
    }
  end

  defp provider_name(%{provider: provider}), do: to_string(provider)

  defp provider_name(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, _model] -> provider
      _other -> nil
    end
  end

  defp provider_name(_model_spec), do: nil

  defp sanitize_usage(nil), do: nil
  defp sanitize_usage(usage) when is_map(usage), do: sanitize_usage_value(usage)
  defp sanitize_usage(_usage), do: nil

  defp sanitize_provider_meta(provider_meta, logprobs) do
    provider_meta
    |> sanitize_usage_value()
    |> Map.drop([:logprobs, "logprobs"])
    |> Map.put(:logprobs, logprobs)
  end

  defp sanitize_usage_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if Imp.Redaction.credential_entry?(key, nested),
        do: {key, "[REDACTED]"},
        else: {key, sanitize_usage_value(nested)}
    end)
  end

  defp sanitize_usage_value([key, nested])
       when is_atom(key) or is_binary(key) or is_map(key) do
    if Imp.Redaction.credential_entry?(key, nested),
      do: [key, "[REDACTED]"],
      else: [key, sanitize_usage_value(nested)]
  end

  defp sanitize_usage_value([]), do: []

  defp sanitize_usage_value([head | tail]),
    do: [sanitize_usage_value(head) | sanitize_usage_value(tail)]

  defp sanitize_usage_value({key, nested}) when is_atom(key) or is_binary(key) do
    if Imp.Redaction.credential_entry?(key, nested),
      do: {key, "[REDACTED]"},
      else: {key, sanitize_usage_value(nested)}
  end

  defp sanitize_usage_value(value) when is_binary(value), do: Imp.Redaction.redact(value)
  defp sanitize_usage_value(value), do: value

  defp sanitize_logprobs(logprobs) when is_list(logprobs) do
    logprobs
    |> Enum.flat_map(fn token ->
      with true <- is_map(token),
           token_text when is_binary(token_text) <- map_value(token, :token),
           logprob when is_number(logprob) <- map_value(token, :logprob) do
        top_logprobs =
          token
          |> map_value(:top_logprobs)
          |> sanitize_top_logprobs()

        [
          %{
            token: Imp.Redaction.redact(token_text),
            logprob: logprob,
            top_logprobs: top_logprobs
          }
        ]
      else
        _invalid -> []
      end
    end)
  end

  defp sanitize_logprobs(_logprobs), do: []

  defp sanitize_top_logprobs(top_logprobs) when is_list(top_logprobs) do
    Enum.flat_map(top_logprobs, fn alternative ->
      with true <- is_map(alternative),
           token when is_binary(token) <- map_value(alternative, :token),
           logprob when is_number(logprob) <- map_value(alternative, :logprob) do
        [%{token: Imp.Redaction.redact(token), logprob: logprob}]
      else
        _invalid -> []
      end
    end)
  end

  defp sanitize_top_logprobs(_top_logprobs), do: []

  defp map_value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp native_reasoning_metadata(%ReqLLM.Response{} = response) do
    thinking = ReqLLM.Response.thinking(response)
    details = reasoning_details(response)

    %{}
    |> maybe_put(:native_reasoning, blank_to_nil(thinking))
    |> maybe_put(:reasoning_details, empty_to_nil(details))
  end

  defp reasoning_details(%ReqLLM.Response{message: %{reasoning_details: details}})
       when is_list(details),
       do: details

  defp reasoning_details(_response), do: []

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :content, text: text}) when is_binary(text) do
    emit_stream_chunk(text)
    [%Imp.Streaming.Messages.StreamResponse{chunk: text}]
  end

  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :thinking, text: text, metadata: metadata})
       when is_binary(text) do
    payload = %{reasoning: text}
    emit_stream_chunk(payload)

    [
      %Imp.Streaming.Messages.StreamResponse{
        chunk: payload,
        metadata: Map.put(metadata, :type, :reasoning)
      }
    ]
  end

  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :tool_call} = chunk) do
    payload = %{
      tool_calls: [
        %{id: chunk.metadata[:id], name: chunk.name, arguments: chunk.arguments || %{}}
      ]
    }

    emit_stream_chunk(payload)
    [%Imp.Streaming.Messages.StreamResponse{chunk: payload}]
  end

  # Metadata can arrive in several provider chunks (usage, model, finish
  # reason, reasoning details). `next_stream_chunk/1` accumulates it and emits
  # exactly one terminal event after the provider enumerable is exhausted, so
  # callers never mistake an early finish-reason chunk for complete accounting.
  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :meta}), do: []

  defp from_stream_chunk(_chunk), do: []

  defp normalize_stream(lm, messages, opts) do
    Stream.resource(
      fn -> open_stream(lm, messages, opts) end,
      &next_stream_chunk/1,
      &cleanup_stream(&1, lm)
    )
  end

  defp open_stream(lm, messages, opts) do
    Imp.Telemetry.execute([:imp, :lm, :stream, :start], %{system_time: System.system_time()}, %{
      lm: redact_lm(lm)
    })

    case safe_stream(lm, messages, opts) do
      {:ok, %ReqLLM.StreamResponse{} = response} ->
        %{
          response: response,
          resume: fn -> suspend_stream(response.stream) end,
          continuation: nil,
          started?: false,
          completed?: false,
          failed?: false,
          terminal_error: nil,
          metadata: %{}
        }

      {:error, reason} ->
        %{
          response: nil,
          resume: nil,
          continuation: nil,
          started?: false,
          completed?: false,
          failed?: true,
          terminal_error: reason,
          metadata: %{}
        }
    end
  end

  defp next_stream_chunk(%{completed?: true} = state), do: {:halt, state}

  defp next_stream_chunk(%{terminal_error: reason} = state) when not is_nil(reason) do
    {[%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}],
     %{state | completed?: true, terminal_error: nil}}
  end

  defp next_stream_chunk(state) do
    case state.resume.() do
      {:suspended, chunk, continuation} ->
        chunks = from_stream_chunk(chunk)
        metadata = accumulate_stream_metadata(state.metadata, chunk)

        {chunks,
         %{
           state
           | resume: fn -> continuation.({:cont, nil}) end,
             continuation: continuation,
             started?: true,
             metadata: metadata
         }}

      {:done, _acc} ->
        {[
           %Imp.Streaming.Messages.StreamResponse{
             done: true,
             metadata: state.metadata
           }
         ], %{state | continuation: nil, started?: true, completed?: true}}

      {:halted, _acc} ->
        {:halt, %{state | continuation: nil, started?: true, completed?: true}}
    end
  rescue
    error -> stream_failure(state, error)
  catch
    kind, reason -> stream_failure(state, {kind, reason})
  end

  defp suspend_stream(stream) do
    Enumerable.reduce(stream, {:cont, nil}, fn chunk, _acc -> {:suspend, chunk} end)
  end

  defp accumulate_stream_metadata(metadata, %ReqLLM.StreamChunk{
         type: :meta,
         metadata: incoming
       })
       when is_map(incoming),
       do: Map.merge(metadata, incoming)

  defp accumulate_stream_metadata(metadata, _chunk), do: metadata

  defp stream_failure(state, error) do
    reason = {:req_llm_stream_failed, error_message(error)}

    {[%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}],
     %{state | completed?: true, failed?: true}}
  end

  defp cleanup_stream(state, lm) do
    try do
      if state.response do
        halt_provider_stream(state)

        if not state.completed? or state.failed? do
          cancel_provider_stream(state.response.cancel)
        end
      end
    after
      emit_stream_stop(lm)
    end
  end

  defp halt_provider_stream(%{started?: true, completed?: false, continuation: continuation})
       when is_function(continuation, 1) do
    safely(fn -> continuation.({:halt, nil}) end)
  end

  defp halt_provider_stream(_state), do: :ok

  defp cancel_provider_stream(cancel) when is_function(cancel, 0), do: safely(cancel)
  defp cancel_provider_stream(_cancel), do: :ok

  defp safely(fun) do
    fun.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_stream_stop(lm) do
    Imp.Telemetry.execute([:imp, :lm, :stream, :stop], %{count: 1}, %{lm: redact_lm(lm)})
  end

  defp emit_stream_chunk(chunk) do
    Imp.Telemetry.execute([:imp, :lm, :stream, :chunk], %{count: 1}, %{chunk: chunk})
  end

  defp encode_model(model) when is_binary(model), do: model
  defp encode_model(model), do: model

  defp redact_lm(%__MODULE__{model: model}),
    do: %{provider: :req_llm, model: Imp.Redaction.redact(model)}

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

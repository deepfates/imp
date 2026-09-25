defmodule Imp.LM do
  @moduledoc """
  Behaviour for language model clients.

  Inside an `Imp.Run` context, `request/2` emits one `:model_request` and one
  `:model_response` event per call. The request event carries the messages as
  its input and the rest of the request in its metadata: `:options`, the
  request options with the tool definitions removed, and `:tools_hash`, the
  SHA-256 of the canonical JSON of those definitions, or `nil` when the request
  sent no tools. The definitions themselves are emitted once per run per
  distinct hash, as a `:tools_sent` event whose input is the tool list as
  sent. Between the two, a recorded request can be reproduced without repeating
  a roster on every call. Both are redacted like every other event. A request
  made with `generate/3`'s `:purpose` carries it in the request event's
  metadata as `:purpose`; it is never part of what is sent.

  The response event's metadata carries the
  money for that call in `:cost`: the provider's reported total in USD as a
  non-negative float, or `nil` when the provider reported nothing Imp can read
  as a number. A host summing spend reads that number and nothing else.
  `:cached` is true when the answer came from Imp's response cache (on by
  default for `Imp.req_llm/2`): no request was made, the cost is `0.0` and the
  usage is empty, which is how a free answer differs from an unpriced one.

  Providers report the total as a bare number, a string, a `Decimal` or a cost
  breakdown map, and Imp reads the number out of all four. When the provider
  reported a breakdown, that map is also on the event as `:billing`, unchanged;
  when it reported none, there is no `:billing` key. A breakdown's shape is the
  provider's, so treat it as evidence to inspect, not as a contract.
  """

  @callback generate(messages :: list(map()), opts :: keyword()) ::
              {:ok, map() | binary() | Imp.Prediction.t() | list()} | {:error, term()}
  @callback request(lm :: term(), request :: Imp.Core.LMRequest.t()) ::
              {:ok, Imp.Core.LMResponse.t()} | {:error, term()}
  @callback stream(lm :: term(), messages :: list(map()), opts :: keyword()) :: Enumerable.t()
  @optional_callbacks request: 2, stream: 3

  @doc false
  # The LM's response-format capability, the analog of DSPy's
  # `lm.supported_params` / `lm.supports_response_schema`. The JSON adapter
  # gates `response_format` on it, as DSPy's `JSONAdapter` gates on those two
  # properties. Resolution:
  #
  #   * a struct whose module exports `response_format_capability/1` -> ask it,
  #     so fixtures and custom clients can declare their own tier.
  #   * anything else (a bare arity-2 callback, a plain module, a configured
  #     `%{module:, opts:}` map) -> `Imp.LM.Capability.none/0`, the DSPy
  #     `BaseLM` default, so no `response_format` is sent.
  @spec response_format_capability(term()) :: Imp.LM.Capability.t()
  def response_format_capability(%module{} = lm) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :response_format_capability, 1) ->
        module.response_format_capability(lm)

      true ->
        Imp.LM.Capability.none()
    end
  end

  def response_format_capability(_lm), do: Imp.LM.Capability.none()

  @doc false
  # Native-reasoning support is a capability separate from JSON response
  # formatting, so a client declares it rather than the predictor matching on
  # model names.
  def reasoning_capability(%module{} = lm) do
    Code.ensure_loaded?(module) and function_exported?(module, :reasoning_capability, 1) and
      module.reasoning_capability(lm) == true
  end

  def reasoning_capability(_lm), do: false

  @doc false
  # A configured client option ranks below a per-call or program override,
  # matching DSPy's `lm_kwargs` > `lm.kwargs` precedence.
  def configured_option(%module{} = lm, key) do
    if Code.ensure_loaded?(module) and function_exported?(module, :configured_option, 2),
      do: module.configured_option(lm, key),
      else: :error
  end

  def configured_option(_lm, _key), do: :error

  @doc """
  Sends one request to `lm` and returns its output.

  `:purpose` names what kind of call this is, for a caller that makes more than
  one kind -- a program's own loop and a second model that writes its replies,
  say. It is recorded on the `:model_request` event's metadata as `:purpose`
  and is never sent to the provider: it is the record's, so a reader can tell
  the calls apart without guessing from their options. A request without it
  has no `:purpose` key.
  """
  def generate(lm, messages, opts \\ [])

  def generate(lm, messages, opts) do
    opts = validate_opts!(opts, "Imp.LM.generate/3")
    {purpose, opts} = Keyword.pop(opts, :purpose)
    request = Imp.Core.request(messages, opts, lm)

    request =
      if is_nil(purpose),
        do: request,
        else: %{request | metadata: Map.put(request.metadata, :purpose, purpose)}

    case request(lm, request) do
      {:ok, %Imp.Core.LMResponse{} = response} ->
        {:ok, Imp.Core.legacy_response(response)}

      other ->
        other
    end
  end

  @doc "Executes one provider-neutral LM request and returns a normalized response."
  def request(lm, %Imp.Core.LMRequest{} = request) do
    if Imp.Run.context() do
      call_id = Imp.Run.new_event_id("model")
      {messages, options} = Imp.Core.request_parts(request)
      tools = List.wrap(Keyword.get(options, :tools, []))
      hash = tools_hash(tools)

      # The definitions are the largest and least variable part of a request, so
      # they are recorded once per roster rather than once per call, and every
      # request names the roster it was sent by its hash.
      if hash && Imp.Run.first_seen?({:tools_sent, hash}) do
        Imp.Run.emit(:tools_sent,
          component: lm_name(lm),
          input: tools,
          metadata: %{tools_hash: hash}
        )
      end

      Imp.Run.emit(:model_request,
        component: lm_name(lm),
        input: messages,
        metadata:
          maybe_put_purpose(
            %{
              model_call_id: call_id,
              model: request.config.model,
              options: Keyword.delete(options, :tools),
              tools_hash: hash
            },
            request.metadata
          )
      )

      result = perform_request(lm, request)

      case result do
        {:ok, response} ->
          Imp.Run.emit(:model_response,
            output: response.outputs,
            metadata:
              maybe_put_billing(
                %{
                  model_call_id: call_id,
                  model: request.config.model,
                  usage: response.usage,
                  cost: response.cost,
                  cached: response.cached,
                  response: response.metadata
                },
                response.billing
              )
          )

        {:error, error} ->
          Imp.Run.emit(:model_response, error: error, metadata: %{model_call_id: call_id})
      end

      result
    else
      perform_request(lm, request)
    end
  end

  def request(_lm, request) do
    {:error, {:invalid_lm_request, request}}
  end

  # A stable name for one tool roster: the SHA-256 of its canonical JSON, with
  # object keys sorted, so two requests offering the same definitions hash the
  # same however the terms were built. A request offering no tools has no hash.
  defp tools_hash([]), do: nil

  defp tools_hash(tools) do
    :sha256
    |> :crypto.hash(canonical_json(Imp.Observability.Inspection.json_safe(tools)))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, nested} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(nested)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp maybe_put_purpose(metadata, %{purpose: purpose}), do: Map.put(metadata, :purpose, purpose)
  defp maybe_put_purpose(metadata, _request_metadata), do: metadata

  defp maybe_put_billing(metadata, nil), do: metadata
  defp maybe_put_billing(metadata, billing), do: Map.put(metadata, :billing, billing)

  defp perform_request(lm, request) do
    with {:ok, response} <- dispatch_request(lm, request) do
      Imp.Usage.maybe_record(Imp.Core.legacy_response(response))
      {:ok, response}
    end
  end

  def validate_lm(nil), do: {:ok, nil}

  def validate_lm(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) do
      {:ok, module}
    else
      {:error, "expected an LM module exporting generate/2"}
    end
  end

  def validate_lm(fun) when is_function(fun, 2) do
    warn_deprecated_shape(:bare_fun)
    {:ok, fun}
  end

  def validate_lm(%module{} = lm) do
    if Code.ensure_loaded?(module) and
         (function_exported?(module, :generate, 3) or function_exported?(module, :generate, 2)) do
      {:ok, lm}
    else
      {:error, "expected an LM struct whose module exports generate/3 or generate/2"}
    end
  end

  def validate_lm(%{module: module, opts: opts} = lm) when is_atom(module) do
    warn_deprecated_shape(:module_opts_map)

    cond do
      not Keyword.keyword?(opts) ->
        {:error, "expected configured LM :opts to be a keyword list"}

      Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) ->
        {:ok, lm}

      true ->
        {:error, "expected configured LM :module to export generate/2"}
    end
  end

  def validate_lm(_lm) do
    {:error, "expected nil, an LM module, or an LM struct"}
  end

  @deprecated_shape_messages %{
    module_opts_map:
      "the %{module: module, opts: keyword} LM shape is deprecated; " <>
        "use an LM struct instead (for example Imp.LM.Static.new(opts) or Imp.req_llm/2). " <>
        "Support will be removed in a future release.",
    bare_fun:
      "passing a bare arity-2 function as an LM is deprecated; " <>
        "use an LM struct instead (for example Imp.LM.Static.new(handler: fun)). " <>
        "Support will be removed in a future release."
  }

  @doc false
  # Warns once per VM for an LM shape kept only for compatibility.
  # `reset_deprecation_warnings/0` re-arms it, for tests.
  def warn_deprecated_shape(shape) do
    key = {__MODULE__, :deprecated_shape_warned, shape}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      require Logger
      Logger.warning("Imp.LM: " <> Map.fetch!(@deprecated_shape_messages, shape))
    end

    :ok
  end

  @doc false
  def reset_deprecation_warnings do
    for shape <- Map.keys(@deprecated_shape_messages) do
      :persistent_term.erase({__MODULE__, :deprecated_shape_warned, shape})
    end

    :ok
  end

  defp dispatch_generate(module, messages, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) do
      call_lm(fn -> module.generate(messages, opts) end, module)
    else
      {:error, {:not_an_lm, module}}
    end
  end

  defp dispatch_generate(%module{} = lm, messages, opts) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :generate, 3) ->
        call_lm(fn -> module.generate(lm, messages, opts) end, module)

      Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) ->
        call_lm(fn -> module.generate(messages, opts) end, module)

      true ->
        {:error, {:not_an_lm, module}}
    end
  end

  defp dispatch_generate(%{module: module, opts: client_opts}, messages, opts) do
    warn_deprecated_shape(:module_opts_map)
    client_opts = validate_opts!(client_opts, "Imp.LM.generate/3 client :opts")
    dispatch_generate(module, messages, Keyword.merge(client_opts, opts))
  end

  defp dispatch_generate(fun, messages, opts) when is_function(fun, 2) do
    warn_deprecated_shape(:bare_fun)
    call_lm(fn -> fun.(messages, opts) end, fun)
  end

  defp dispatch_generate(lm, _messages, _opts), do: {:error, {:not_an_lm, lm}}

  defp dispatch_request(%module{} = lm, %Imp.Core.LMRequest{} = request) do
    if Code.ensure_loaded?(module) and function_exported?(module, :request, 2) do
      call_request(fn -> module.request(lm, request) end, module)
    else
      fallback_request(lm, request)
    end
  end

  defp dispatch_request(lm, %Imp.Core.LMRequest{} = request), do: fallback_request(lm, request)

  defp fallback_request(lm, request) do
    {messages, opts} = Imp.Core.request_parts(request)

    with {:ok, raw} <- dispatch_generate(lm, messages, opts),
         {:ok, response} <- Imp.Core.response(raw) do
      {:ok, response}
    end
  end

  defp call_request(fun, lm) do
    case fun.() do
      {:ok, %Imp.Core.LMResponse{} = response} -> {:ok, response}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_lm_response, lm_name(lm), other}}
    end
  rescue
    safety in Imp.OperationalSafetyError -> {:error, safety}
    error -> {:error, {:lm_failed, lm_name(lm), error}}
  catch
    kind, reason -> {:error, {:lm_failed, lm_name(lm), {kind, reason}}}
  end

  defp call_lm(fun, lm) do
    case fun.() do
      {:ok, %Imp.Prediction{}} = success -> success
      {:ok, value} when is_binary(value) or is_map(value) -> {:ok, value}
      # Multi-completion contract: an LM asked for n > 1 completions returns
      # a list of outputs, one per completion (DSPy: n choices on one request).
      {:ok, completions} when is_list(completions) -> {:ok, completions}
      {:error, _reason} = error -> error
      {:ok, other} -> {:error, {:invalid_lm_result, other}}
      other -> {:error, {:invalid_lm_result, other}}
    end
  rescue
    safety in Imp.OperationalSafetyError -> {:error, safety}
    error -> {:error, {:lm_failed, lm_name(lm), error}}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety -> {:error, safety}
        nil -> {:error, {:lm_failed, lm_name(lm), {kind, reason}}}
      end
  end

  defp lm_name(lm) when is_atom(lm), do: lm
  defp lm_name(fun) when is_function(fun), do: :anonymous_lm
  defp lm_name(%module{}), do: module
  defp lm_name(other), do: other

  defp validate_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end
end

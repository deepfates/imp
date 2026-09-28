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
  metadata as `:purpose`; it is never part of what is sent. A request streamed
  through the client's `stream/3` (`Imp.stream/3` with `provider_stream: true`)
  is recorded the same way, with the usage the provider reported at the end of
  the stream.

  The response event's metadata carries the money for that call as two
  numbers, each a non-negative float in USD or `nil`, as on
  `Imp.Core.LMResponse`. `:cost` is what the provider reported charging, and
  `nil` when it reported no charge, which means the charge is unknown rather
  than zero. `:estimated_cost` is ReqLLM's catalog price for the reported
  tokens, and `nil` when the catalog has no price for the model. A host summing
  money spent sums `:cost`; one that falls back on `:estimated_cost` for calls
  with no reported charge is counting an estimate, and should know it.

  When ReqLLM priced the call, the breakdown behind `:estimated_cost` is also
  on the event as `:billing`, unchanged; otherwise there is no `:billing` key.
  A breakdown's shape is ReqLLM's, so treat it as evidence to inspect, not as
  a contract.
  """

  @typedoc """
  An LM: a struct whose module implements this behaviour, or such a module
  itself for a client that holds no configuration. Every callback receives the
  LM as its first argument, the struct or the module as it was given.
  """
  @type t :: struct() | module()

  @doc """
  Sends `messages` and returns the model's output: a map of fields, a string,
  an `Imp.Prediction`, or, when `opts` asks for several completions (`:n`), a
  list of them.
  """
  @callback generate(lm :: t(), messages :: [map()], opts :: keyword()) ::
              {:ok, map() | binary() | Imp.Prediction.t() | list()} | {:error, term()}

  @doc """
  Executes one provider-neutral request. A client that implements it gets
  the request's configuration and metadata whole; one that does not is called
  through `c:generate/3`.
  """
  @callback request(lm :: t(), request :: Imp.Core.LMRequest.t()) ::
              {:ok, Imp.Core.LMResponse.t()} | {:error, term()}

  @doc "Streams the output of one request, for `Imp.stream/3`."
  @callback stream(lm :: t(), messages :: [map()], opts :: keyword()) :: Enumerable.t()

  @optional_callbacks request: 2, stream: 3

  @doc false
  # The LM's response-format capability, the analog of DSPy's
  # `lm.supported_params` / `lm.supports_response_schema`. The JSON adapter
  # gates `response_format` on it, as DSPy's `JSONAdapter` gates on those two
  # properties. Resolution:
  #
  #   * a struct whose module exports `response_format_capability/1` -> ask it,
  #     so fixtures and custom clients can declare their own tier.
  #   * anything else (a module, or a struct whose module does not declare
  #     one) -> `Imp.LM.Capability.none/0`, the DSPy
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
  # Whether the LM answers a request's `:tools` with native tool calls, the
  # analog of DSPy's `lm.supports_function_calling`. `Imp.Predict.ReActV2`
  # sends every step's roster natively and reads this to decide whether the
  # step's prompt also describes a written `tool_calls` field. A client that
  # knows it cannot call tools declares `tool_calling_capability/1` returning
  # false; one that declares nothing is taken to answer the request it is sent.
  def tool_calling_capability(%module{} = lm) do
    not (Code.ensure_loaded?(module) and function_exported?(module, :tool_calling_capability, 1) and
           module.tool_calling_capability(lm) == false)
  end

  def tool_calling_capability(_lm), do: true

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
    lm
    |> request(new_request(lm, messages, opts, "Imp.LM.generate/3"))
    |> legacy_result()
  end

  @doc false
  # The request `generate/3` sends: `:purpose` moves from the options, where
  # it would reach the provider, to the request's metadata, where `record/3`
  # puts it on the record.
  def new_request(lm, messages, opts, context) do
    opts = validate_opts!(opts, context)
    {purpose, opts} = Keyword.pop(opts, :purpose)
    request = Imp.Core.request(messages, opts, lm)

    if is_nil(purpose),
      do: request,
      else: %{request | metadata: Map.put(request.metadata, :purpose, purpose)}
  end

  @doc false
  # The output `generate/3` returns for a request's result.
  def legacy_result({:ok, %Imp.Core.LMResponse{} = response}),
    do: {:ok, Imp.Core.legacy_response(response)}

  def legacy_result({:error, _reason} = error), do: error

  @doc "Executes one provider-neutral LM request and returns a normalized response."
  def request(lm, %Imp.Core.LMRequest{} = request),
    do: record(lm, request, &dispatch_request(lm, &1))

  def request(_lm, request) do
    {:error, {:invalid_lm_request, request}}
  end

  @doc false
  # Performs `request` with `dispatch`, a function from the request to
  # `{:ok, %Imp.Core.LMResponse{}}` or `{:error, reason}`, and records it:
  # usage in `Imp.Usage`, and inside an `Imp.Run` the `:tools_sent`,
  # `:model_request` and `:model_response` events. `request/2` dispatches to
  # the client's `request/2` or `generate/3`; a provider stream dispatches to
  # its `stream/3`. How the answer arrives does not change what is recorded.
  @spec record(t(), Imp.Core.LMRequest.t(), (Imp.Core.LMRequest.t() -> result)) :: result
        when result: {:ok, Imp.Core.LMResponse.t()} | {:error, term()}
  def record(lm, %Imp.Core.LMRequest{} = request, dispatch) when is_function(dispatch, 1) do
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

      result = perform_request(lm, request, dispatch)

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
                  estimated_cost: response.estimated_cost,
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
      perform_request(lm, request, dispatch)
    end
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

  # A dispatch that raises or throws, a client's `stream/3` failing before it
  # returns a stream say, fails as `{:lm_failed, lm, reason}` like a raising
  # `generate/3`, and its `:model_response` is still recorded.
  defp perform_request(lm, request, dispatch) do
    with {:ok, response} <- call_request(fn -> dispatch.(request) end, lm) do
      Imp.Usage.maybe_record(Imp.Core.legacy_response(response))
      {:ok, response}
    end
  end

  @doc false
  def validate_lm(nil), do: {:ok, nil}

  def validate_lm(lm) do
    if lm?(lm),
      do: {:ok, lm},
      else: {:error, "expected nil, or an LM struct or module implementing Imp.LM generate/3"}
  end

  defp lm?(%module{}), do: implements_generate?(module)
  defp lm?(module) when is_atom(module), do: implements_generate?(module)
  defp lm?(_lm), do: false

  defp implements_generate?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :generate, 3)

  defp dispatch_generate(lm, messages, opts) do
    module = lm_module(lm)

    if lm?(lm),
      do: call_lm(fn -> module.generate(lm, messages, opts) end, module),
      else: {:error, {:not_an_lm, lm}}
  end

  defp lm_module(%module{}), do: module
  defp lm_module(module), do: module

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
  defp lm_name(%module{}), do: module
  defp lm_name(other), do: other

  # Options can hold a key, so an error names their shape, never their value.
  defp validate_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got #{Imp.Options.shape(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got #{Imp.Options.shape(opts)}"
  end
end

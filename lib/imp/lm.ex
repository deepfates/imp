defmodule Imp.LM do
  @moduledoc """
  Behaviour for language model clients.
  """

  @callback generate(messages :: list(map()), opts :: keyword()) ::
              {:ok, map() | binary() | Imp.Prediction.t() | list()} | {:error, term()}
  @callback request(lm :: term(), request :: Imp.Core.LMRequest.t()) ::
              {:ok, Imp.Core.LMResponse.t()} | {:error, term()}
  @callback stream(lm :: term(), messages :: list(map()), opts :: keyword()) :: Enumerable.t()
  @optional_callbacks request: 2, stream: 3

  @doc false
  # The LM's response-format capability (internal), the Imp analog of DSPy's
  # `lm.supported_params` / `lm.supports_response_schema` (see
  # `Imp.LM.Capability`). The JSON adapter gates `response_format` on this
  # exactly as DSPy's `JSONAdapter` gates on those two properties.
  #
  # Resolution mirrors DSPy: a client that carries a real model registry
  # introspects it; anything that cannot be introspected (a bare arity-2
  # callback, a plain module, a configured `%{module:, opts:}` map) resolves to
  # the DSPy `BaseLM` default — no declared capability — so no `response_format`
  # is sent. This is deliberate and NOT silent: it is the same contract DSPy
  # gives an LM that does not declare `supported_params`.
  #
  #   * `%Imp.Clients.ReqLLM{}` -> introspect the ReqLLM/LLMDB model registry.
  #   * a struct whose module exports `response_format_capability/1` -> ask it
  #     (lets fixtures and custom clients declare their tier).
  #   * anything else -> `Imp.LM.Capability.none/0`.
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
  # Native-reasoning support is deliberately a separate capability from JSON
  # response formatting. Registry-backed clients can declare it, and custom
  # clients/fixtures can do the same without teaching Predict model names.
  def reasoning_capability(%module{} = lm) do
    Code.ensure_loaded?(module) and function_exported?(module, :reasoning_capability, 1) and
      module.reasoning_capability(lm) == true
  end

  def reasoning_capability(_lm), do: false

  @doc false
  # A configured client option participates below a per-call/program override,
  # matching DSPy's `lm_kwargs` > `lm.kwargs` precedence.
  def configured_option(%module{} = lm, key) do
    if Code.ensure_loaded?(module) and function_exported?(module, :configured_option, 2),
      do: module.configured_option(lm, key),
      else: :error
  end

  def configured_option(_lm, _key), do: :error

  def generate(lm, messages, opts \\ [])

  def generate(lm, messages, opts) do
    opts = validate_opts!(opts, "Imp.LM.generate/3")
    request = Imp.Core.request(messages, opts, lm)

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

      Imp.Run.emit(:model_request,
        component: lm_name(lm),
        input: elem(Imp.Core.request_parts(request), 0),
        metadata: %{model_call_id: call_id, model: request.config.model}
      )

      result = perform_request(lm, request)

      case result do
        {:ok, response} ->
          Imp.Run.emit(:model_response,
            output: response.outputs,
            metadata: %{
              model_call_id: call_id,
              model: request.config.model,
              usage: response.usage,
              cost: response.cost,
              response: response.metadata
            }
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
  # Loud, once-per-VM deprecation warning for LM shapes kept only for
  # compatibility. `reset_deprecation_warnings/0` re-arms it (tests).
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
    error -> {:error, {:lm_failed, lm_name(lm), error_message(error)}}
  catch
    kind, reason -> {:error, {:lm_failed, lm_name(lm), error_message({kind, reason})}}
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
    error -> {:error, {:lm_failed, lm_name(lm), error_message(error)}}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety -> {:error, safety}
        nil -> {:error, {:lm_failed, lm_name(lm), error_message({kind, reason})}}
      end
  end

  defp lm_name(lm) when is_atom(lm), do: lm
  defp lm_name(fun) when is_function(fun), do: :anonymous_lm
  defp lm_name(%module{}), do: module
  defp lm_name(other), do: other

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)

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

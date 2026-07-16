defmodule Imp.Clients.ReqLLM do
  @moduledoc """
  Imp LM client backed by the Elixir `req_llm` ecosystem.

  Imp owns signatures, adapters, optimizers, traces, and evaluation. `req_llm`
  owns provider/model resolution, Req/Finch transport, streaming, provider
  option translation, and canonical response structs.
  """

  @behaviour Imp.LM

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

  @cache_credential_marker {:imp_cache_identity, :credential}

  def new(model_spec, opts \\ []) do
    {req_module, nested_opts} = validate_new_opts!(opts)

    %__MODULE__{
      model: model_spec,
      opts: Keyword.merge(nested_opts, Keyword.drop(opts, [:opts, :req_module])),
      req_module: req_module
    }
  end

  def validate_req_module(module) when is_atom(module), do: {:ok, module}

  def validate_req_module(module) do
    {:error, "expected a ReqLLM-compatible module atom, got: #{inspect(module)}"}
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
      |> Keyword.pop(:rollout_id)

    opts =
      opts
      |> normalize_opts()
      |> normalize_provider_profile_opts(lm.model)

    cache? = Keyword.get(opts, :cache, true)
    opts = Keyword.delete(opts, :cache)
    cache_key = cache_key(lm, messages, maybe_put_rollout_id(opts, rollout_id))

    if cache? do
      generate_cached(lm, messages, opts, cache_key)
    else
      generate_uncached(lm, messages, opts)
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
        value
    end
  end

  defp generate_uncached(lm, messages, opts) do
    started = System.monotonic_time()

    Imp.Telemetry.execute([:imp, :lm, :start], %{system_time: System.system_time()}, %{
      lm: redact_lm(lm)
    })

    result = do_generate_uncached(lm, messages, opts)

    Imp.Telemetry.execute([:imp, :lm, :stop], %{duration: System.monotonic_time() - started}, %{
      lm: redact_lm(lm),
      result: elem(result, 0)
    })

    result
  end

  defp do_generate_uncached(lm, messages, opts) do
    opts = cap_transport_timeouts(opts)

    case lm.req_module.generate_text(lm.model, to_req_messages(messages), opts) do
      {:ok, response} ->
        {:ok, from_response(response, lm.model)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_req_llm_response, inspect(other)}}
    end
  rescue
    error -> {:error, {:req_llm_generate_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:req_llm_generate_failed, error_message({kind, reason})}}
  end

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
      @cache_credential_marker
    else
      cache_identity_value(value)
    end
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
      |> Keyword.pop(:rollout_id)

    opts =
      opts
      |> normalize_opts()
      |> normalize_provider_profile_opts(lm.model)

    normalize_stream(lm, messages, opts)
  end

  defp safe_stream(lm, messages, opts) do
    opts = cap_transport_timeouts(opts)

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
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_call_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end

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

      other ->
        ReqLLM.Context.user(inspect(other))
    end)
  end

  defp build_message(role, content, tool_calls) do
    role = role |> to_string() |> String.to_existing_atom()

    case role do
      :system ->
        ReqLLM.Context.system(content_to_req(content))

      :assistant ->
        ReqLLM.Context.assistant(content_to_req(content),
          tool_calls: normalize_tool_calls(tool_calls)
        )

      :tool ->
        ReqLLM.Context.tool_result(tool_call_id(tool_calls), content_to_text(content))

      _ ->
        ReqLLM.Context.user(content_to_req(content))
    end
  rescue
    ArgumentError -> ReqLLM.Context.user(content_to_text(content))
  end

  defp content_to_req(content) when is_binary(content), do: content

  defp content_to_req(content) when is_list(content) do
    content
    |> Enum.flat_map(&content_part/1)
  end

  defp content_to_req(content), do: content_to_text(content)

  defp content_part(%Imp.Adapters.Types.Image{url: url, metadata: metadata}) when is_binary(url),
    do: [ReqLLM.Message.ContentPart.image_url(url, metadata)]

  defp content_part(%Imp.Adapters.Types.Image{
         data: data,
         mime_type: mime_type,
         metadata: metadata
       })
       when is_binary(data),
       do: [ReqLLM.Message.ContentPart.image(data, mime_type || "image/png", metadata)]

  defp content_part(%Imp.Adapters.Types.File{data: data, mime_type: mime_type})
       when is_binary(data),
       do: [
         ReqLLM.Message.ContentPart.file(
           data,
           "attachment",
           mime_type || "application/octet-stream"
         )
       ]

  defp content_part(%Imp.Adapters.Types.File{path: path, mime_type: mime_type})
       when is_binary(path) do
    [
      ReqLLM.Message.ContentPart.file(
        read_file_attachment!(path),
        Path.basename(path),
        mime_type || mime_type_from_path(path)
      )
    ]
  end

  defp content_part(%Imp.Adapters.Types.Document{text: text}),
    do: [ReqLLM.Message.ContentPart.text(to_string(text))]

  defp content_part(%Imp.Adapters.Types.Code{code: code, language: language}),
    do: [ReqLLM.Message.ContentPart.text("```#{language || ""}\n#{code}\n```")]

  defp content_part(%Imp.Adapters.Types.Reasoning{text: text}),
    do: [ReqLLM.Message.ContentPart.thinking(to_string(text))]

  defp content_part(value) when is_binary(value), do: [ReqLLM.Message.ContentPart.text(value)]
  defp content_part(value), do: [ReqLLM.Message.ContentPart.text(inspect(value))]

  defp content_to_text(content) when is_binary(content), do: content

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      value when is_binary(value) -> value
      %Imp.Adapters.Types.Document{text: text} -> to_string(text)
      %Imp.Adapters.Types.Code{code: code} -> to_string(code)
      %Imp.Adapters.Types.Reasoning{text: text} -> to_string(text)
      value -> inspect(value)
    end)
  end

  defp content_to_text(content), do: inspect(content)

  defp read_file_attachment!(path) do
    case File.read(path) do
      {:ok, data} ->
        data

      {:error, reason} ->
        raise ArgumentError,
              "could not read Imp file attachment #{inspect(path)}: #{:file.format_error(reason)}"
    end
  end

  defp mime_type_from_path(path) do
    case path |> Path.extname() |> String.downcase() do
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".csv" -> "text/csv"
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".wav" -> "audio/wav"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      _ -> "application/octet-stream"
    end
  end

  defp normalize_tool_calls(nil), do: nil

  defp normalize_tool_calls(%Imp.Adapters.Types.ToolCalls{tool_calls: tool_calls}),
    do: normalize_tool_calls(tool_calls)

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &normalize_tool_call/1)
  end

  defp normalize_tool_calls(other), do: other

  defp normalize_tool_call(%ReqLLM.ToolCall{} = call), do: call

  defp normalize_tool_call(%Imp.Adapters.Types.ToolCall{} = call) do
    ReqLLM.ToolCall.new(
      tool_call_id(call),
      to_string(call.name),
      Jason.encode!(call.arguments || %{})
    )
  end

  defp normalize_tool_call(%{function: _function} = call),
    do: call |> Imp.Adapters.Types.ToolCall.from_map() |> normalize_tool_call()

  defp normalize_tool_call(%{"function" => _function} = call),
    do: call |> Imp.Adapters.Types.ToolCall.from_map() |> normalize_tool_call()

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
  defp tool_call_id(%Imp.Adapters.Types.ToolCall{id: id}) when not is_nil(id), do: id
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
    case Imp.Optimizer.GEPA.Coordinator.current_deadline() do
      :infinity ->
        opts

      deadline ->
        remaining = Imp.Optimizer.GEPA.Coordinator.remaining(deadline)

        opts
        |> cap_timeout(:receive_timeout, remaining)
        |> Keyword.update(:connect_options, [timeout: remaining], fn connect_options ->
          cap_timeout(connect_options, :timeout, remaining)
        end)
    end
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
        anthropic_beta: ["structured-outputs-2025-11-13"],
        output_format: %{type: "json_schema", schema: schema}
      ],
      fn provider_opts ->
        provider_opts
        |> Keyword.update(:anthropic_beta, ["structured-outputs-2025-11-13"], fn betas ->
          ["structured-outputs-2025-11-13" | List.wrap(betas)]
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
      |> rename_max_tokens_for_reasoning()
      |> Keyword.drop([:temperature, :top_p, :frequency_penalty, :presence_penalty])
    else
      opts
    end
  end

  defp rename_max_tokens_for_reasoning(opts) do
    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)

    cond do
      Keyword.has_key?(opts, :max_completion_tokens) ->
        opts

      is_nil(max_tokens) ->
        opts

      true ->
        Keyword.put(opts, :max_completion_tokens, max_tokens)
    end
  end

  defp openai_reasoning_model?(model) do
    id = model |> model_id() |> String.downcase()

    model_provider(model) == :openai and
      (String.match?(id, ~r/^(gpt-5|o[134])(?:[-_:.].*)?$/) or
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

    if metadata == %{} do
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

  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :meta, metadata: metadata}) do
    if metadata[:finish_reason] || metadata["finish_reason"] do
      [%Imp.Streaming.Messages.StreamResponse{done: true, metadata: metadata}]
    else
      []
    end
  end

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
          terminal_error: nil
        }

      {:error, reason} ->
        %{
          response: nil,
          resume: nil,
          continuation: nil,
          started?: false,
          completed?: false,
          failed?: true,
          terminal_error: reason
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

        {chunks,
         %{
           state
           | resume: fn -> continuation.({:cont, nil}) end,
             continuation: continuation,
             started?: true
         }}

      {:done, _acc} ->
        {:halt, %{state | continuation: nil, started?: true, completed?: true}}

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

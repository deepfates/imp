defmodule DSEx.Clients.ReqLLM do
  @moduledoc """
  DSEx LM client backed by the Elixir `req_llm` ecosystem.

  DSEx owns signatures, adapters, optimizers, traces, and evaluation. `req_llm`
  owns provider/model resolution, Req/Finch transport, streaming, provider
  option translation, and canonical response structs.
  """

  @behaviour DSEx.LM

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

    opts =
      lm.opts
      |> Keyword.merge(opts)
      |> normalize_opts()
      |> normalize_provider_profile_opts(lm.model)

    cache? = Keyword.get(opts, :cache, false)
    opts = Keyword.delete(opts, :cache)
    cache_key = cache_key(lm, messages, opts)

    if cache? do
      generate_cached(lm, messages, opts, cache_key)
    else
      generate_uncached(lm, messages, opts)
    end
  end

  defp generate_cached(lm, messages, opts, cache_key) do
    case DSEx.Cache.get(cache_key, :__missing__) do
      :__missing__ ->
        DSEx.Telemetry.execute([:dsex, :cache, :miss], %{count: 1}, %{key: cache_key})

        case generate_uncached(lm, messages, opts) do
          {:ok, _value} = success ->
            DSEx.Cache.put(cache_key, success)
            success

          {:error, _reason} = error ->
            error
        end

      value ->
        DSEx.Telemetry.execute([:dsex, :cache, :hit], %{count: 1}, %{key: cache_key})
        value
    end
  end

  defp generate_uncached(lm, messages, opts) do
    started = System.monotonic_time()

    DSEx.Telemetry.execute([:dsex, :lm, :start], %{system_time: System.system_time()}, %{
      lm: redact_lm(lm)
    })

    result = do_generate_uncached(lm, messages, opts)

    DSEx.Telemetry.execute([:dsex, :lm, :stop], %{duration: System.monotonic_time() - started}, %{
      lm: redact_lm(lm),
      result: elem(result, 0)
    })

    result
  end

  defp do_generate_uncached(lm, messages, opts) do
    case lm.req_module.generate_text(lm.model, to_req_messages(messages), opts) do
      {:ok, response} ->
        {:ok, from_response(response)}

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

    opts =
      opts
      |> Keyword.drop([:api_key, :headers, :req_module])
      |> Enum.sort()

    {:lm_response,
     :crypto.hash(
       :sha256,
       :erlang.term_to_binary({lm.model, to_req_messages(messages), opts})
     )
     |> Base.encode16(case: :lower)}
  end

  def generate_async(%__MODULE__{} = lm, messages, opts \\ []) do
    opts = validate_call_opts!(opts, "#{inspect(__MODULE__)}.generate_async/3")

    DSEx.Tasks.async(fn -> generate(lm, messages, opts) end)
  end

  @impl true
  def stream(%__MODULE__{} = lm, messages, opts \\ []) do
    opts = validate_call_opts!(opts, "#{inspect(__MODULE__)}.stream/3")

    opts =
      lm.opts
      |> Keyword.merge(opts)
      |> normalize_opts()
      |> normalize_provider_profile_opts(lm.model)

    DSEx.Telemetry.execute([:dsex, :lm, :stream, :start], %{system_time: System.system_time()}, %{
      lm: redact_lm(lm)
    })

    case safe_stream(lm, messages, opts) do
      {:ok, %ReqLLM.StreamResponse{} = response} ->
        response.stream
        |> Stream.flat_map(&from_stream_chunk/1)
        |> Stream.concat(stream_stop(lm))

      {:error, reason} ->
        [
          %DSEx.Streaming.Messages.StreamResponse{
            chunk: {:error, reason},
            done: true
          }
        ]
    end
  end

  defp safe_stream(lm, messages, opts) do
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
    %{
      provider: :req_llm,
      model: encode_model(lm.model),
      opts:
        lm.opts
        |> Keyword.drop([:api_key, :authorization, :headers])
        |> Enum.map(fn {k, v} -> [Atom.to_string(k), v] end)
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
      |> DSEx.Options.validate!(@new_option_schema, "#{inspect(__MODULE__)}.new/2")

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

  defp content_part(%DSEx.Adapters.Types.Image{url: url}) when is_binary(url),
    do: [ReqLLM.Message.ContentPart.image_url(url)]

  defp content_part(%DSEx.Adapters.Types.Image{data: data, mime_type: mime_type})
       when is_binary(data),
       do: [ReqLLM.Message.ContentPart.image(data, mime_type || "image/png")]

  defp content_part(%DSEx.Adapters.Types.File{data: data, mime_type: mime_type})
       when is_binary(data),
       do: [
         ReqLLM.Message.ContentPart.file(
           data,
           "attachment",
           mime_type || "application/octet-stream"
         )
       ]

  defp content_part(%DSEx.Adapters.Types.File{path: path, mime_type: mime_type})
       when is_binary(path) do
    [
      ReqLLM.Message.ContentPart.file(
        read_file_attachment!(path),
        Path.basename(path),
        mime_type || mime_type_from_path(path)
      )
    ]
  end

  defp content_part(%DSEx.Adapters.Types.Document{text: text}),
    do: [ReqLLM.Message.ContentPart.text(to_string(text))]

  defp content_part(%DSEx.Adapters.Types.Code{code: code, language: language}),
    do: [ReqLLM.Message.ContentPart.text("```#{language || ""}\n#{code}\n```")]

  defp content_part(%DSEx.Adapters.Types.Reasoning{text: text}),
    do: [ReqLLM.Message.ContentPart.thinking(to_string(text))]

  defp content_part(value) when is_binary(value), do: [ReqLLM.Message.ContentPart.text(value)]
  defp content_part(value), do: [ReqLLM.Message.ContentPart.text(inspect(value))]

  defp content_to_text(content) when is_binary(content), do: content

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      value when is_binary(value) -> value
      %DSEx.Adapters.Types.Document{text: text} -> to_string(text)
      %DSEx.Adapters.Types.Code{code: code} -> to_string(code)
      %DSEx.Adapters.Types.Reasoning{text: text} -> to_string(text)
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
              "could not read DSEx file attachment #{inspect(path)}: #{:file.format_error(reason)}"
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

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %{id: id, name: name, arguments: arguments} ->
        ReqLLM.ToolCall.new(id, to_string(name), Jason.encode!(arguments || %{}))

      %{"id" => id, "name" => name, "arguments" => arguments} ->
        ReqLLM.ToolCall.new(id, to_string(name), Jason.encode!(arguments || %{}))

      other ->
        other
    end)
  end

  defp tool_call_id([%{id: id} | _]), do: id
  defp tool_call_id([%{"id" => id} | _]), do: id
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
    model
    |> to_string()
    |> String.downcase()
    |> String.replace_prefix("openai:", "")
    |> then(fn model ->
      String.match?(model, ~r/^(gpt-5|o[134])(?:[-_:.].*)?$/) or
        String.contains?(model, "reasoning")
    end)
  end

  defp anthropic_model?(model) do
    model
    |> to_string()
    |> String.downcase()
    |> String.starts_with?("anthropic:")
  end

  defp normalize_tool(%ReqLLM.Tool{} = tool), do: tool

  defp normalize_tool(%{function: function}), do: tool_from_openai_function(function)
  defp normalize_tool(%{"function" => function}), do: tool_from_openai_function(function)
  defp normalize_tool(other), do: other

  defp tool_from_openai_function(function) do
    ReqLLM.Tool.new!(
      name: function[:name] || function["name"],
      description: function[:description] || function["description"] || "",
      parameter_schema: function[:parameters] || function["parameters"] || %{"type" => "object"},
      callback: fn _args -> {:ok, "tool result is handled by DSEx"} end
    )
  end

  defp from_response(%ReqLLM.Response{} = response) do
    case ReqLLM.Response.tool_calls(response) do
      [] ->
        response.object || ReqLLM.Response.text(response) || ""

      tool_calls ->
        %{tool_calls: Enum.map(tool_calls, &ReqLLM.ToolCall.from_map/1)}
    end
  end

  defp from_response(other), do: other

  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :content, text: text}) when is_binary(text) do
    emit_stream_chunk(text)
    [%DSEx.Streaming.Messages.StreamResponse{chunk: text}]
  end

  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :tool_call} = chunk) do
    payload = %{
      tool_calls: [
        %{id: chunk.metadata[:id], name: chunk.name, arguments: chunk.arguments || %{}}
      ]
    }

    emit_stream_chunk(payload)
    [%DSEx.Streaming.Messages.StreamResponse{chunk: payload}]
  end

  defp from_stream_chunk(%ReqLLM.StreamChunk{type: :meta, metadata: metadata}) do
    if metadata[:finish_reason] || metadata["finish_reason"] do
      [%DSEx.Streaming.Messages.StreamResponse{done: true, metadata: metadata}]
    else
      []
    end
  end

  defp from_stream_chunk(_chunk), do: []

  defp stream_stop(lm) do
    Stream.resource(
      fn -> :emit end,
      fn
        :emit ->
          DSEx.Telemetry.execute([:dsex, :lm, :stream, :stop], %{count: 1}, %{lm: redact_lm(lm)})
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp emit_stream_chunk(chunk) do
    DSEx.Telemetry.execute([:dsex, :lm, :stream, :chunk], %{count: 1}, %{chunk: chunk})
  end

  defp encode_model(model) when is_binary(model), do: model
  defp encode_model(model), do: model

  defp redact_lm(%__MODULE__{model: model}), do: %{provider: :req_llm, model: model}

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

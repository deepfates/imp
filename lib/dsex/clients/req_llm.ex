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

  def new(model_spec, opts \\ []) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "#{inspect(__MODULE__)}.new/2 expects keyword options"
    end

    req_module = Keyword.get(opts, :req_module, ReqLLM)
    nested_opts = Keyword.get(opts, :opts, [])

    unless is_atom(req_module) and Keyword.keyword?(nested_opts) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.new/2 expects :req_module atom and :opts keyword list"
    end

    %__MODULE__{
      model: model_spec,
      opts: Keyword.merge(nested_opts, Keyword.drop(opts, [:opts, :req_module])),
      req_module: req_module
    }
  end

  @impl true
  def generate(messages, opts),
    do: generate(new(Keyword.fetch!(opts, :model), opts), messages, opts)

  def generate(%__MODULE__{} = lm, messages, opts) do
    opts = lm.opts |> Keyword.merge(opts) |> normalize_opts()

    started = System.monotonic_time()

    DSEx.Telemetry.execute([:dsex, :lm, :start], %{system_time: System.system_time()}, %{
      lm: redact_lm(lm)
    })

    result =
      with {:ok, response} <-
             lm.req_module.generate_text(lm.model, to_req_messages(messages), opts) do
        {:ok, from_response(response)}
      end

    DSEx.Telemetry.execute([:dsex, :lm, :stop], %{duration: System.monotonic_time() - started}, %{
      lm: redact_lm(lm),
      result: elem(result, 0)
    })

    result
  end

  def generate_async(%__MODULE__{} = lm, messages, opts \\ []) do
    Task.async(fn -> generate(lm, messages, opts) end)
  end

  def stream(%__MODULE__{} = lm, messages, opts \\ []) do
    opts = lm.opts |> Keyword.merge(opts) |> normalize_opts()

    DSEx.Telemetry.execute([:dsex, :lm, :stream, :start], %{system_time: System.system_time()}, %{
      lm: redact_lm(lm)
    })

    case lm.req_module.stream_text(lm.model, to_req_messages(messages), opts) do
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

  def dump(%__MODULE__{} = lm) do
    %{
      provider: :req_llm,
      model: encode_model(lm.model),
      opts: Enum.map(lm.opts, fn {k, v} -> [Atom.to_string(k), v] end)
    }
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
    |> Keyword.drop([:model, :req_module, :json_retries, :test_mode, :mock_response])
    |> rename_timeout()
    |> normalize_numeric_opts()
    |> normalize_response_format()
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

  defp normalize_response_format(opts) do
    case Keyword.pop(opts, :response_format) do
      {nil, opts} ->
        opts

      {format, opts} ->
        Keyword.update(opts, :provider_options, [response_format: format], fn provider_opts ->
          Keyword.put(provider_opts, :response_format, format)
        end)
    end
  end

  defp normalize_tools(opts) do
    Keyword.update(opts, :tools, [], fn tools ->
      Enum.map(tools, &normalize_tool/1)
    end)
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
end

defmodule DSPy.Clients.HTTPLM do
  @moduledoc "OpenAI-compatible chat-completions client used by OpenAI, LiteLLM, local, and Databricks wrappers."

  @behaviour DSPy.LM

  defstruct [
    :model,
    :api_key,
    :base_url,
    provider: :openai,
    path: "/chat/completions",
    transport: DSPy.HTTP.Hackneyless,
    headers: [],
    opts: []
  ]

  @type t :: %__MODULE__{}

  def new(model, opts \\ []) do
    %__MODULE__{
      model: model,
      api_key: Keyword.get(opts, :api_key) || env_key(Keyword.get(opts, :provider, :openai)),
      base_url:
        Keyword.get(opts, :base_url, default_base_url(Keyword.get(opts, :provider, :openai))),
      provider: Keyword.get(opts, :provider, :openai),
      path: Keyword.get(opts, :path, "/chat/completions"),
      transport: Keyword.get(opts, :transport, DSPy.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      opts: Keyword.get(opts, :opts, [])
    }
  end

  @impl true
  def generate(messages, opts),
    do: generate(new(Keyword.fetch!(opts, :model), opts), messages, opts)

  def generate(%__MODULE__{} = lm, messages, opts) do
    {body, headers} = request(lm, messages, opts)

    request_opts = Keyword.take(opts, [:timeout, :http_opts, :request_opts])

    with {:ok, %{status: status, body: response}} when status in 200..299 <-
           post_with_retries(lm, headers, body, request_opts, retry_config(opts)),
         {:ok, decoded} <- Jason.decode(response) do
      {:ok, extract_content(decoded)}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def stream(%__MODULE__{} = lm, messages, opts \\ []) do
    {body, headers} = request(lm, messages, Keyword.put(opts, :stream, true))
    request_opts = Keyword.take(opts, [:timeout, :http_opts, :request_opts])

    lm.transport
    |> DSPy.HTTP.stream(endpoint(lm), headers, body, request_opts)
    |> Stream.flat_map(&parse_stream_chunk/1)
  end

  defp request(%__MODULE__{} = lm, messages, opts) do
    payload =
      lm.opts
      |> Keyword.merge(opts)
      |> Keyword.drop([:api_key, :base_url, :transport, :headers, :provider, :path])
      |> Map.new()
      |> Map.merge(%{model: lm.model, messages: Enum.map(messages, &encode_message/1)})

    body = Jason.encode!(payload)

    headers =
      [{"content-type", "application/json"}] ++
        auth_headers(lm) ++
        Enum.map(lm.headers, fn {k, v} -> {to_string(k), to_string(v)} end)

    {body, headers}
  end

  defp retry_config(opts) do
    %{
      attempts: Keyword.get(opts, :num_retries, Keyword.get(opts, :retries, 2)) + 1,
      backoff_ms: Keyword.get(opts, :retry_backoff_ms, 25)
    }
  end

  defp post_with_retries(lm, headers, body, request_opts, %{
         attempts: attempts,
         backoff_ms: backoff_ms
       }) do
    Enum.reduce_while(1..attempts, nil, fn attempt, _last ->
      case DSPy.HTTP.post(lm.transport, endpoint(lm), headers, body, request_opts) do
        {:ok, %{status: status}} = response when status in 200..299 ->
          {:halt, response}

        {:ok, %{status: status}} = response
        when status in [408, 409, 429, 500, 502, 503, 504] and attempt < attempts ->
          sleep(backoff_ms, attempt)
          {:cont, response}

        {:error, _reason} = error when attempt < attempts ->
          sleep(backoff_ms, attempt)
          {:cont, error}

        other ->
          {:halt, other}
      end
    end)
  end

  defp sleep(0, _attempt), do: :ok
  defp sleep(backoff_ms, attempt), do: Process.sleep(backoff_ms * attempt)

  def dump(%__MODULE__{} = lm) do
    %{
      provider: lm.provider,
      model: lm.model,
      base_url: lm.base_url,
      path: lm.path,
      opts: Enum.map(lm.opts, fn {k, v} -> [Atom.to_string(k), v] end)
    }
  end

  defp endpoint(%__MODULE__{} = lm), do: String.trim_trailing(lm.base_url, "/") <> lm.path

  defp encode_message(%{role: role, content: content}) when is_list(content),
    do: %{role: role_name(role), content: DSPy.Adapters.Types.content_to_openai(content)}

  defp encode_message(%{role: role, content: %_struct{} = content}),
    do: %{role: role_name(role), content: DSPy.Adapters.Types.content_to_openai(content)}

  defp encode_message(%{role: role, content: content}),
    do: %{role: role_name(role), content: content}

  defp role_name(role) when is_atom(role), do: Atom.to_string(role)
  defp role_name(role), do: to_string(role)

  defp extract_content(%{"choices" => [%{"message" => message} | _]}) do
    cond do
      is_list(message["tool_calls"]) ->
        %{tool_calls: Enum.map(message["tool_calls"], &normalize_tool_call/1)}

      Map.has_key?(message, "content") ->
        message["content"]

      true ->
        message
    end
  end

  defp extract_content(%{"choices" => [%{"text" => text} | _]}), do: text
  defp extract_content(%{"output" => output}), do: output
  defp extract_content(other), do: other

  defp parse_stream_chunk({:error, reason}),
    do: [%DSPy.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]

  defp parse_stream_chunk(chunk) when is_binary(chunk) do
    chunk
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.flat_map(&parse_sse_line/1)
  end

  defp parse_stream_chunk(%{} = event), do: parse_stream_event(event)

  defp parse_sse_line("data: [DONE]"), do: [%DSPy.Streaming.Messages.StreamResponse{done: true}]

  defp parse_sse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, event} -> parse_stream_event(event)
      {:error, _} -> []
    end
  end

  defp parse_sse_line(_line), do: []

  defp parse_stream_event(%{"choices" => choices}) do
    Enum.flat_map(choices, fn choice ->
      delta = choice["delta"] || choice["message"] || %{}
      finish = choice["finish_reason"]

      chunks =
        cond do
          is_binary(delta["content"]) ->
            [%DSPy.Streaming.Messages.StreamResponse{chunk: delta["content"]}]

          is_list(delta["tool_calls"]) ->
            [
              %DSPy.Streaming.Messages.StreamResponse{
                chunk: %{tool_calls: Enum.map(delta["tool_calls"], &normalize_tool_call/1)}
              }
            ]

          true ->
            []
        end

      if finish,
        do:
          chunks ++
            [
              %DSPy.Streaming.Messages.StreamResponse{
                done: true,
                metadata: %{finish_reason: finish}
              }
            ],
        else: chunks
    end)
  end

  defp parse_stream_event(%{"output_text" => text}),
    do: [%DSPy.Streaming.Messages.StreamResponse{chunk: text}]

  defp parse_stream_event(_event), do: []

  defp normalize_tool_call(%{"function" => %{"name" => name, "arguments" => args}} = call) do
    %{
      id: call["id"],
      name: name,
      arguments: decode_arguments(args)
    }
  end

  defp normalize_tool_call(%{"name" => name, "arguments" => args} = call) do
    %{
      id: call["id"],
      name: name,
      arguments: decode_arguments(args)
    }
  end

  defp normalize_tool_call(call), do: call

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> args
    end
  end

  defp decode_arguments(args), do: args

  defp auth_headers(%__MODULE__{api_key: nil}), do: []
  defp auth_headers(%__MODULE__{api_key: key}), do: [{"authorization", "Bearer #{key}"}]

  defp default_base_url(:openai),
    do: System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"

  defp default_base_url(:litellm),
    do: System.get_env("LITELLM_BASE_URL") || "http://localhost:4000/v1"

  defp default_base_url(:local),
    do: System.get_env("LOCAL_LM_BASE_URL") || "http://localhost:8000/v1"

  defp default_base_url(:databricks),
    do:
      System.get_env("DATABRICKS_BASE_URL") ||
        "https://example.cloud.databricks.com/serving-endpoints"

  defp default_base_url(_provider), do: "http://localhost:8000/v1"

  defp env_key(:openai), do: System.get_env("OPENAI_API_KEY")
  defp env_key(:databricks), do: System.get_env("DATABRICKS_TOKEN")
  defp env_key(_provider), do: nil
end

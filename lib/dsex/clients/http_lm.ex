defmodule DSEx.Clients.HTTPLM do
  @moduledoc "OpenAI-compatible chat-completions client used by OpenAI, LiteLLM, local, and Databricks wrappers."

  @behaviour DSEx.LM

  defstruct [
    :model,
    :api_key,
    :base_url,
    provider: :openai,
    path: "/chat/completions",
    transport: DSEx.HTTP.Hackneyless,
    headers: [],
    opts: [],
    test_mode: nil
  ]

  @type t :: %__MODULE__{}

  def new(model, opts \\ []) do
    provider = Keyword.get(opts, :provider, :openai)

    %__MODULE__{
      model: model,
      api_key: api_key(provider, opts),
      base_url: Keyword.get(opts, :base_url, default_base_url(provider)),
      provider: provider,
      path: Keyword.get(opts, :path, "/chat/completions"),
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      opts: Keyword.get(opts, :opts, []),
      test_mode: Keyword.get(opts, :test_mode)
    }
  end

  @impl true
  def generate(messages, opts),
    do: generate(new(Keyword.fetch!(opts, :model), opts), messages, opts)

  def generate(%__MODULE__{} = lm, messages, opts) do
    opts = maybe_put_test_mode(lm, opts)

    case test_mode_action(lm, messages, opts) do
      {:mock, content} -> {:ok, content}
      :real -> generate_live(lm, messages, opts)
    end
  end

  defp generate_live(%__MODULE__{} = lm, messages, opts) do
    opts = Keyword.merge(lm.opts, opts)
    cache_key = cache_key(lm, messages, opts)

    if Keyword.get(opts, :cache, false) do
      DSEx.Cache.fetch_or_store(cache_key, fn -> generate_uncached(lm, messages, opts) end)
    else
      generate_uncached(lm, messages, opts)
    end
  end

  def generate_async(%__MODULE__{} = lm, messages, opts \\ []) do
    Task.async(fn -> generate(lm, messages, opts) end)
  end

  def cache_key(%__MODULE__{} = lm, messages, opts) do
    opts =
      opts
      |> Keyword.drop([:api_key, :headers, :transport, :http_opts, :request_opts])
      |> Enum.sort()

    {:lm_response,
     :crypto.hash(
       :sha256,
       :erlang.term_to_binary({lm.provider, lm.model, lm.base_url, lm.path, messages, opts})
     )
     |> Base.encode16(case: :lower)}
  end

  defp generate_uncached(%__MODULE__{} = lm, messages, opts) do
    started = System.monotonic_time()

    DSEx.Telemetry.execute([:dsex, :lm, :start], %{system_time: System.system_time()}, %{
      lm: redact_lm(lm)
    })

    {body, headers} = request(lm, messages, opts)

    request_opts = Keyword.take(opts, [:timeout, :http_opts, :request_opts])

    result =
      with {:ok, %{status: status, body: response}} when status in 200..299 <-
             post_with_retries(lm, headers, body, request_opts, retry_config(opts)),
           {:ok, decoded} <- Jason.decode(response) do
        {:ok, extract_content(decoded)}
      else
        {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
        {:error, reason} -> {:error, reason}
      end

    duration = System.monotonic_time() - started
    metadata = %{lm: redact_lm(lm), result: elem(result, 0)}
    DSEx.Telemetry.execute([:dsex, :lm, :stop], %{duration: duration}, metadata)
    result
  end

  defp test_mode_action(%__MODULE__{} = lm, messages, opts) do
    case DSEx.TestMode.mode(opts) do
      :mock ->
        if test_mode_transport?(lm),
          do: {:mock, DSEx.TestMode.mock_content(lm, messages, opts)},
          else: :real

      :fallback ->
        if test_mode_transport?(lm) and missing_required_credential?(lm),
          do: {:mock, DSEx.TestMode.mock_content(lm, messages, opts)},
          else: :real

      :live ->
        :real
    end
  end

  defp maybe_put_test_mode(%__MODULE__{test_mode: nil}, opts), do: opts

  defp maybe_put_test_mode(%__MODULE__{test_mode: mode}, opts),
    do: Keyword.put_new(opts, :test_mode, mode)

  defp test_mode_transport?(%__MODULE__{transport: DSEx.HTTP.Hackneyless}), do: true
  defp test_mode_transport?(_lm), do: false

  defp missing_required_credential?(%__MODULE__{provider: provider, api_key: nil})
       when provider in [:openai, :databricks],
       do: true

  defp missing_required_credential?(_lm), do: false

  defp api_key(provider, opts) do
    cond do
      Keyword.has_key?(opts, :api_key) -> Keyword.get(opts, :api_key)
      Keyword.has_key?(opts, :base_url) -> nil
      true -> env_key(provider)
    end
  end

  def stream(%__MODULE__{} = lm, messages, opts \\ []) do
    {body, headers} = request(lm, messages, Keyword.put(opts, :stream, true))
    request_opts = Keyword.take(opts, [:timeout, :http_opts, :request_opts])

    lm.transport
    |> DSEx.HTTP.stream(endpoint(lm), headers, body, request_opts)
    |> Stream.flat_map(&parse_stream_chunk/1)
  end

  defp request(%__MODULE__{} = lm, messages, opts) do
    payload =
      lm.opts
      |> Keyword.merge(opts)
      |> Keyword.drop([
        :api_key,
        :base_url,
        :transport,
        :headers,
        :provider,
        :path,
        :cache,
        :json_retries,
        :mock_response,
        :test_mode,
        :native_json_schema,
        :http_opts,
        :request_opts
      ])
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
      case DSEx.HTTP.post(lm.transport, endpoint(lm), headers, body, request_opts) do
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
    do: %{role: role_name(role), content: DSEx.Adapters.Types.content_to_openai(content)}

  defp encode_message(%{role: role, content: %_struct{} = content}),
    do: %{role: role_name(role), content: DSEx.Adapters.Types.content_to_openai(content)}

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
    do: [%DSEx.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]

  defp parse_stream_chunk(chunk) when is_binary(chunk) do
    chunk
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.flat_map(&parse_sse_line/1)
  end

  defp parse_stream_chunk(%{} = event), do: parse_stream_event(event)

  defp parse_sse_line("data: [DONE]"),
    do: [%DSEx.Streaming.Messages.StreamResponse{done: true}]

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
            [%DSEx.Streaming.Messages.StreamResponse{chunk: delta["content"]}]

          is_list(delta["tool_calls"]) ->
            [
              %DSEx.Streaming.Messages.StreamResponse{
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
              %DSEx.Streaming.Messages.StreamResponse{
                done: true,
                metadata: %{finish_reason: finish}
              }
            ],
        else: chunks
    end)
  end

  defp parse_stream_event(%{"output_text" => text}),
    do: [%DSEx.Streaming.Messages.StreamResponse{chunk: text}]

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

  defp redact_lm(%__MODULE__{} = lm),
    do: %{provider: lm.provider, model: lm.model, base_url: lm.base_url, path: lm.path}

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

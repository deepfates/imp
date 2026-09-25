defmodule Imp.Retrievers.Limit do
  @moduledoc false

  def retrieve_limit(opts, default) do
    opts
    |> Keyword.get(:k, default)
    |> validate_limit!()
  end

  defp validate_limit!(value) when is_integer(value) and value >= 0, do: value

  defp validate_limit!(value) do
    raise ArgumentError,
          "retriever :k must be a non-negative integer; got: #{inspect(value)}"
  end
end

defmodule Imp.Retrievers.HTTP do
  @moduledoc "Generic HTTP retriever with injectable transport and response mapping."

  @behaviour Imp.Retrieve

  defstruct [
    :url,
    transport: Imp.HTTP.Hackneyless,
    headers: [],
    body_builder: nil,
    response_mapper: nil,
    method: :post,
    max_attempts: 3,
    attempt_timeout: 15_000,
    total_timeout: 45_000,
    retry_statuses: [429, 500, 502, 503, 504],
    retry_backoff_ms: 100,
    max_retry_delay_ms: 5_000,
    sleep_fun: nil
  ]

  @default_retry_statuses [429, 500, 502, 503, 504]

  @option_schema [
    transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    body_builder: [type: {:fun, 2}],
    response_mapper: [type: {:fun, 1}],
    method: [type: :atom],
    max_attempts: [type: :pos_integer],
    attempt_timeout: [type: :pos_integer],
    total_timeout: [type: :pos_integer],
    retry_statuses: [type: {:custom, __MODULE__, :validate_retry_statuses, []}],
    retry_backoff_ms: [type: {:custom, __MODULE__, :validate_retry_backoff, []}],
    max_retry_delay_ms: [type: :non_neg_integer],
    sleep_fun: [type: {:fun, 1}]
  ]

  def new(url, opts \\ []) do
    validate_url!(url, "#{inspect(__MODULE__)}.new/2")
    opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

    %__MODULE__{
      url: url,
      transport: Keyword.get(opts, :transport, Imp.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      body_builder: Keyword.get(opts, :body_builder, &default_body/2),
      response_mapper: Keyword.get(opts, :response_mapper, &default_mapper/1),
      method: Keyword.get(opts, :method, :post),
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      attempt_timeout: Keyword.get(opts, :attempt_timeout, 15_000),
      total_timeout: Keyword.get(opts, :total_timeout, 45_000),
      retry_statuses: Keyword.get(opts, :retry_statuses, @default_retry_statuses),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 100),
      max_retry_delay_ms: Keyword.get(opts, :max_retry_delay_ms, 5_000),
      sleep_fun: Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    }
  end

  @doc false
  def validate_retry_statuses(statuses) when is_list(statuses) do
    if Enum.all?(statuses, &(&1 in [429, 500, 502, 503, 504])) do
      {:ok, Enum.uniq(statuses)}
    else
      {:error, "expected a list containing only 429, 500, 502, 503, or 504"}
    end
  end

  def validate_retry_statuses(_statuses),
    do: {:error, "expected a list containing only 429, 500, 502, 503, or 504"}

  @doc false
  def validate_retry_backoff(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def validate_retry_backoff(value) when is_function(value, 1), do: {:ok, value}

  def validate_retry_backoff(_value),
    do: {:error, "expected a non-negative integer or an arity-1 function"}

  @impl true
  def retrieve(retriever, query, opts \\ [])

  def retrieve(%__MODULE__{method: method}, _query, _opts) when method != :post do
    {:error, {:http_method_not_supported, __MODULE__, method}}
  end

  def retrieve(%__MODULE__{} = retriever, query, opts) do
    Imp.Telemetry.span(
      [:imp, :retriever],
      %{retriever: __MODULE__, method: retriever.method},
      fn ->
        submit_retrieval(retriever, query, opts)
      end
    )
  end

  defp submit_retrieval(%__MODULE__{} = retriever, query, opts) do
    with {:ok, body} <- build_body(retriever, query, opts),
         headers <- request_headers(retriever),
         {:ok, response} <- post_retrieval(retriever, headers, body, opts),
         {:ok, decoded} <- decode_response(response) do
      map_response(retriever, decoded)
    end
  end

  defp build_body(retriever, query, opts) do
    payload = retriever.body_builder.(query, opts)
    {:ok, Jason.encode!(payload)}
  rescue
    error -> {:error, {:invalid_retriever_request, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:invalid_retriever_request, inspect({kind, reason})}}
  end

  defp post_retrieval(retriever, headers, body, opts) do
    deadline = now_ms() + retriever.total_timeout
    do_post_retrieval(retriever, headers, body, opts, deadline, 1)
  end

  defp do_post_retrieval(retriever, headers, body, opts, deadline, attempt) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {:error, {:retriever_http_failed, :total_timeout, attempt - 1}}
    else
      timeout = min(effective_attempt_timeout(retriever, opts), remaining)
      attempt_opts = Keyword.put(opts, :timeout, timeout)
      started = System.monotonic_time()

      result =
        run_attempt(timeout, fn ->
          Imp.HTTP.post(retriever.transport, retriever.url, headers, body, attempt_opts)
        end)

      outcome = classify_attempt(result, retriever.retry_statuses)
      emit_attempt(retriever, attempt, started, outcome)

      case outcome do
        {:ok, response} ->
          {:ok, response.body}

        {:error, reason, false, _headers} ->
          {:error, {:retriever_http_failed, reason, attempt}}

        {:error, _reason, true, response_headers} when attempt < retriever.max_attempts ->
          delay = retry_delay(retriever, attempt, response_headers)
          sleep = min(delay, max(deadline - now_ms(), 0))
          retriever.sleep_fun.(sleep)
          do_post_retrieval(retriever, headers, body, opts, deadline, attempt + 1)

        {:error, reason, true, _headers} ->
          {:error, {:retriever_http_failed, reason, attempt}}
      end
    end
  end

  defp run_attempt(timeout, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:attempt_exit, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :attempt_timeout}
    end
  end

  defp classify_attempt({:ok, %{status: status, body: body} = response}, _retry_statuses)
       when status in 200..299 and is_binary(body),
       do: {:ok, response}

  defp classify_attempt({:ok, %{status: status} = response}, retry_statuses)
       when is_integer(status),
       do: {:error, {:status, status}, status in retry_statuses, Map.get(response, :headers, [])}

  defp classify_attempt({:error, :attempt_timeout}, _retry_statuses),
    do: {:error, :attempt_timeout, true, []}

  defp classify_attempt(
         {:error, {:http_transport_failed, _transport, reason}},
         _retry_statuses
       ),
       do: {:error, {:transport, reason}, retryable_transport?(reason), []}

  defp classify_attempt({:error, reason}, _retry_statuses),
    do: {:error, {:transport, reason}, retryable_transport?(reason), []}

  defp classify_attempt(other, _retry_statuses),
    do: {:error, {:invalid_transport_response, other}, false, []}

  defp emit_attempt(retriever, attempt, started, outcome) do
    {outcome_name, status} = telemetry_outcome(outcome)

    metadata = %{
      attempt: attempt,
      max_attempts: retriever.max_attempts,
      outcome: outcome_name
    }

    metadata = if status, do: Map.put(metadata, :status, status), else: metadata

    Imp.Telemetry.execute(
      [:imp, :retriever, :http, :attempt],
      %{duration: System.monotonic_time() - started},
      metadata
    )
  end

  defp telemetry_outcome({:ok, _response}), do: {:ok, nil}
  defp telemetry_outcome({:error, {:status, status}, true, _}), do: {:retryable_status, status}
  defp telemetry_outcome({:error, {:status, status}, false, _}), do: {:status_error, status}
  defp telemetry_outcome({:error, :attempt_timeout, _, _}), do: {:timeout, nil}
  defp telemetry_outcome({:error, {:transport, _}, _, _}), do: {:transport_error, nil}
  defp telemetry_outcome({:error, _, _, _}), do: {:invalid_response, nil}

  defp retryable_transport?(reason)
       when reason in [
              :timeout,
              :connect_timeout,
              :closed,
              :socket_closed_remotely,
              :econnrefused,
              :enetunreach,
              :ehostunreach,
              :nxdomain
            ],
       do: true

  defp retryable_transport?({:failed_connect, _details}), do: true
  defp retryable_transport?({:shutdown, _reason}), do: true
  defp retryable_transport?(_reason), do: false

  defp retry_delay(retriever, attempt, headers) do
    backoff = retry_backoff(retriever.retry_backoff_ms, attempt)
    retry_after = retry_after_ms(headers)

    max(backoff, retry_after)
    |> min(retriever.max_retry_delay_ms)
  end

  defp retry_backoff(backoff, attempt) when is_function(backoff, 1) do
    case backoff.(attempt) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, "retry backoff function returned invalid delay: #{inspect(value)}"
    end
  end

  defp retry_backoff(backoff, attempt), do: backoff * Integer.pow(2, attempt - 1)

  defp retry_after_ms(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} ->
        if String.downcase(to_string(key)) == "retry-after", do: to_string(value)

      _other ->
        nil
    end)
    |> parse_retry_after()
  end

  defp parse_retry_after(nil), do: 0

  defp parse_retry_after(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _other -> retry_after_date_ms(value)
    end
  end

  defp retry_after_date_ms(value) do
    target = value |> String.to_charlist() |> :httpd_util.convert_request_date()
    target_seconds = :calendar.datetime_to_gregorian_seconds(target)
    now_seconds = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    max(target_seconds - now_seconds, 0) * 1_000
  rescue
    _error -> 0
  catch
    _kind, _reason -> 0
  end

  defp request_headers(retriever) do
    headers = [{"content-type", "application/json"} | retriever.headers]

    if retriever.max_attempts > 1 and not header?(headers, "idempotency-key") do
      [{"idempotency-key", request_id()} | headers]
    else
      headers
    end
  end

  defp header?(headers, expected) do
    Enum.any?(headers, fn
      {key, _value} -> String.downcase(to_string(key)) == expected
      _other -> false
    end)
  end

  defp request_id do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "imp-retrieval-#{suffix}"
  end

  defp effective_attempt_timeout(retriever, opts) do
    case Keyword.get(opts, :timeout, retriever.attempt_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, retriever.attempt_timeout)
      _invalid -> retriever.attempt_timeout
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp decode_response(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_retriever_response, Exception.message(reason)}}
    end
  end

  defp map_response(retriever, decoded) do
    case retriever.response_mapper.(decoded) do
      docs when is_list(docs) -> {:ok, docs}
      other -> {:error, {:invalid_retriever_result, other}}
    end
  rescue
    error -> {:error, {:invalid_retriever_result, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:invalid_retriever_result, inspect({kind, reason})}}
  end

  defp default_body(query, opts),
    do: %{query: query, k: Imp.Retrievers.Limit.retrieve_limit(opts, 3)}

  defp default_mapper(%{"documents" => docs}), do: Enum.map(docs, &normalize_doc/1)
  defp default_mapper(%{"results" => docs}), do: Enum.map(docs, &normalize_doc/1)
  defp default_mapper(docs) when is_list(docs), do: Enum.map(docs, &normalize_doc/1)
  defp default_mapper(other), do: [%{text: inspect(other), score: nil, metadata: %{raw: other}}]

  def normalize_doc(%{"text" => text} = doc),
    do: %{text: text, score: doc["score"], metadata: Map.drop(doc, ["text", "score"])}

  def normalize_doc(%{text: text} = doc),
    do: %{text: text, score: Map.get(doc, :score), metadata: Map.drop(doc, [:text, :score])}

  def normalize_doc(text) when is_binary(text), do: %{text: text, score: nil, metadata: %{}}
  def normalize_doc(doc), do: %{text: inspect(doc), score: nil, metadata: %{raw: doc}}

  defp validate_url!(url, _context) when is_binary(url), do: :ok

  defp validate_url!(url, context) do
    raise ArgumentError, "#{context} expects url to be a binary; got: #{inspect(url)}"
  end
end

defmodule Imp.Retrievers.Weaviate do
  @moduledoc "Weaviate GraphQL retriever."

  @option_schema [
    transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    k: [type: :pos_integer],
    field: [type: :string]
  ]

  def new(base_url, class_name, opts \\ []) do
    validate_binary!(base_url, "base_url")
    validate_binary!(class_name, "class_name")
    opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/3")
    endpoint = String.trim_trailing(base_url, "/") <> "/v1/graphql"

    Imp.Retrievers.HTTP.new(endpoint,
      transport: Keyword.get(opts, :transport, Imp.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      body_builder: fn query, call_opts ->
        limit = Imp.Retrievers.Limit.retrieve_limit(call_opts, Keyword.get(opts, :k, 3))
        field = Keyword.get(opts, :field, "text")

        %{
          query: """
          {
            Get {
              #{class_name}(nearText: {concepts: [#{Jason.encode!(query)}]}, limit: #{limit}) {
                #{field}
                _additional { score id }
              }
            }
          }
          """
        }
      end,
      response_mapper: fn decoded ->
        decoded
        |> get_in(["data", "Get", class_name])
        |> List.wrap()
        |> Enum.map(fn item ->
          additional = item["_additional"] || %{}

          %{
            text: item[Keyword.get(opts, :field, "text")],
            score: additional["score"],
            metadata: Map.put(additional, "raw", item)
          }
        end)
      end
    )
  end

  defp validate_binary!(value, _name) when is_binary(value), do: :ok

  defp validate_binary!(value, name) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.new/3 expects #{name} to be a binary; got: #{inspect(value)}"
  end
end

defmodule Imp.Retrievers.Databricks do
  @moduledoc "Databricks Vector Search retriever."

  @option_schema [
    transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    token: [type: {:or, [:string, nil]}],
    k: [type: :pos_integer],
    columns: [type: {:list, :string}]
  ]

  def new(endpoint_url, opts \\ []) do
    validate_endpoint_url!(endpoint_url)
    opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

    Imp.Retrievers.HTTP.new(endpoint_url,
      transport: Keyword.get(opts, :transport, Imp.HTTP.Hackneyless),
      headers: auth_headers(opts) ++ Keyword.get(opts, :headers, []),
      body_builder: fn query, call_opts ->
        %{
          query_text: query,
          num_results: Imp.Retrievers.Limit.retrieve_limit(call_opts, Keyword.get(opts, :k, 3)),
          columns: Keyword.get(opts, :columns, ["text"])
        }
      end,
      response_mapper: fn decoded ->
        rows = get_in(decoded, ["result", "data_array"]) || decoded["data_array"] || []
        columns = get_in(decoded, ["manifest", "columns"]) || []
        names = Enum.map(columns, &(&1["name"] || &1[:name]))

        Enum.map(rows, fn row ->
          mapped = names |> Enum.zip(row) |> Map.new()

          %{
            text: mapped["text"] || mapped[:text] || inspect(mapped),
            score: mapped["score"] || mapped[:score],
            metadata: mapped
          }
        end)
      end
    )
  end

  defp auth_headers(opts) do
    token = Keyword.get(opts, :token)
    if token, do: [{"authorization", "Bearer #{token}"}], else: []
  end

  defp validate_endpoint_url!(endpoint_url) when is_binary(endpoint_url), do: :ok

  defp validate_endpoint_url!(endpoint_url) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.new/2 expects endpoint_url to be a binary; got: #{inspect(endpoint_url)}"
  end
end

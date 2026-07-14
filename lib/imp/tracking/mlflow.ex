defmodule Imp.Tracking.MLflow do
  @moduledoc "MLflow tracking backend implemented over the official HTTP API."

  @behaviour Imp.Tracking.Backend

  alias Imp.Optimizer.Report
  alias Imp.Tracking.Transport

  @api_prefix "/api/2.0/mlflow"
  @artifact_prefix "/api/2.0/mlflow-artifacts/artifacts"
  @logged_artifacts_tag "mlflow.loggedArtifacts"

  @enforce_keys [
    :tracking_uri,
    :transport,
    :transport_opts,
    :headers,
    :run_id,
    :experiment_id,
    :artifact_uri,
    :owned_run,
    :finish_adopted_run
  ]
  defstruct [
    :tracking_uri,
    :transport,
    :transport_opts,
    :headers,
    :run_id,
    :experiment_id,
    :artifact_uri,
    :owned_run,
    :finish_adopted_run
  ]

  @type t :: %__MODULE__{
          tracking_uri: String.t(),
          transport: module(),
          transport_opts: keyword(),
          headers: Transport.headers(),
          run_id: String.t(),
          experiment_id: String.t(),
          artifact_uri: String.t() | nil,
          owned_run: boolean(),
          finish_adopted_run: boolean()
        }

  @impl true
  def start(opts) when is_list(opts) do
    with {:ok, tracking_uri} <- tracking_uri(opts),
         {:ok, transport} <- transport(opts),
         {:ok, headers} <- auth_headers(opts),
         {:ok, base} <- base_state(opts, tracking_uri, transport, headers) do
      case Keyword.get(opts, :run_id) do
        nil -> create_owned_run(base, opts)
        run_id when is_binary(run_id) and run_id != "" -> adopt_run(base, run_id)
        run_id -> {:error, {:invalid_run_id, run_id}}
      end
    end
  end

  @impl true
  def log(%__MODULE__{} = state, {:config, config}), do: log_config(state, config)

  def log(%__MODULE__{} = state, {:metrics, metrics}),
    do: log_metrics(state, metrics)

  def log(%__MODULE__{} = state, {:metrics, metrics, opts}),
    do: log_metrics(state, metrics, opts)

  def log(%__MODULE__{} = state, {:summary, summary}), do: log_summary(state, summary)

  def log(%__MODULE__{} = state, {:artifact, path, body}),
    do: log_artifact(state, path, body)

  def log(%__MODULE__{} = state, {:artifact, path, body, content_type}),
    do: log_artifact(state, path, body, content_type)

  def log(%__MODULE__{} = state, {:table, path, data}), do: log_table(state, path, data)
  def log(%__MODULE__{}, event), do: {:error, {:unsupported_tracking_event, event}}

  @impl true
  def finish(%__MODULE__{owned_run: false, finish_adopted_run: false}, _status), do: :ok

  def finish(%__MODULE__{} = state, status) do
    with {:ok, mlflow_status} <- finish_status(status),
         {:ok, _body} <-
           api_request(state, :post, "/runs/update", %{
             "run_id" => state.run_id,
             "status" => mlflow_status,
             "end_time" => now_ms()
           }) do
      :ok
    end
  end

  @doc "Logs configuration values as MLflow parameters in one log-batch request."
  @spec log_config(t(), map() | keyword()) :: :ok | {:error, term()}
  def log_config(%__MODULE__{} = state, config) do
    with {:ok, entries} <- key_value_entries(config),
         params <-
           Enum.map(entries, fn {key, value} -> %{"key" => key, "value" => stringify(value)} end),
         {:ok, _body} <- log_batch(state, [], params, []) do
      :ok
    end
  end

  @doc "Logs numeric metrics in one log-batch request."
  @spec log_metrics(t(), map() | keyword(), keyword()) :: :ok | {:error, term()}
  def log_metrics(%__MODULE__{} = state, metrics, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, now_ms())
    step = Keyword.get(opts, :step, 0)

    with true <- is_integer(timestamp) or {:error, {:invalid_metric_timestamp, timestamp}},
         true <- is_integer(step) or {:error, {:invalid_metric_step, step}},
         {:ok, entries} <- key_value_entries(metrics),
         {:ok, payload} <- metric_payload(entries, timestamp, step),
         {:ok, _body} <- log_batch(state, payload, [], []) do
      :ok
    end
  end

  @doc "Logs summary values as `imp.summary.*` run tags in one log-batch request."
  @spec log_summary(t(), map() | keyword()) :: :ok | {:error, term()}
  def log_summary(%__MODULE__{} = state, summary) do
    with {:ok, entries} <- key_value_entries(summary),
         tags <-
           Enum.map(entries, fn {key, value} ->
             %{"key" => "imp.summary.#{key}", "value" => stringify(value)}
           end),
         {:ok, _body} <- log_batch(state, [], [], tags) do
      :ok
    end
  end

  @doc "Uploads a raw artifact through an `mlflow-artifacts` proxy URI."
  @spec log_artifact(t(), String.t(), iodata(), String.t()) :: :ok | {:error, term()}
  def log_artifact(%__MODULE__{} = state, path, body, content_type \\ "application/octet-stream") do
    with {:ok, url} <- artifact_url(state, path),
         {:ok, response} <-
           raw_request(
             state,
             :put,
             url,
             [{"content-type", content_type} | state.headers],
             body
           ) do
      expect_success(response)
    end
  end

  @doc "Appends rows to an MLflow split-orient JSON table and records its table tag."
  @spec log_table(t(), String.t(), [map()] | map()) :: :ok | {:error, term()}
  def log_table(%__MODULE__{} = state, path, data) do
    with :ok <- require_json_path(path),
         {:ok, incoming} <- normalize_table(data),
         {:ok, existing} <- fetch_table(state, path),
         table <- append_table(existing, incoming),
         {:ok, encoded} <- Jason.encode(table),
         :ok <- log_artifact(state, path, encoded, "application/json") do
      tag_table(state, path)
    end
  end

  defp create_owned_run(state, opts) do
    experiment_name = Keyword.get(opts, :experiment_name, "Default")

    with true <-
           (is_binary(experiment_name) and experiment_name != "") or
             {:error, {:invalid_experiment_name, experiment_name}},
         {:ok, experiment_id} <- get_or_create_experiment(state, experiment_name),
         {:ok, tags} <- run_tags(Keyword.get(opts, :tags, %{})),
         payload <-
           compact(%{
             "experiment_id" => experiment_id,
             "run_name" => Keyword.get(opts, :run_name),
             "start_time" => Keyword.get(opts, :start_time, now_ms()),
             "tags" => tags
           }),
         {:ok, body} <- api_request(state, :post, "/runs/create", payload),
         {:ok, run} <- fetch_map(body, "run"),
         {:ok, info} <- fetch_map(run, "info"),
         {:ok, run_id} <- fetch_id(info, ["run_id", "run_uuid"]),
         {:ok, artifact_uri} <- fetch_optional_string(info, "artifact_uri") do
      {:ok,
       %{
         state
         | run_id: run_id,
           experiment_id: experiment_id,
           artifact_uri: artifact_uri,
           owned_run: true
       }}
    end
  end

  defp adopt_run(state, run_id) do
    with {:ok, body} <- api_request(state, :get, "/runs/get", %{"run_id" => run_id}),
         {:ok, run} <- fetch_map(body, "run"),
         {:ok, info} <- fetch_map(run, "info"),
         {:ok, experiment_id} <- fetch_id(info, ["experiment_id"]),
         {:ok, artifact_uri} <- fetch_optional_string(info, "artifact_uri") do
      {:ok,
       %{
         state
         | run_id: run_id,
           experiment_id: experiment_id,
           artifact_uri: artifact_uri,
           owned_run: false
       }}
    end
  end

  defp get_or_create_experiment(state, name) do
    case get_experiment(state, name) do
      {:ok, id} ->
        {:ok, id}

      {:error, error} ->
        if missing?(error), do: create_experiment(state, name), else: {:error, error}
    end
  end

  defp get_experiment(state, name) do
    with {:ok, body} <-
           api_request(state, :get, "/experiments/get-by-name", %{"experiment_name" => name}),
         {:ok, experiment} <- fetch_map(body, "experiment") do
      fetch_id(experiment, ["experiment_id"])
    end
  end

  defp create_experiment(state, name) do
    case api_request(state, :post, "/experiments/create", %{"name" => name}) do
      {:ok, body} ->
        fetch_id(body, ["experiment_id"])

      {:error, error} ->
        if already_exists?(error), do: get_experiment(state, name), else: {:error, error}
    end
  end

  defp log_batch(state, metrics, params, tags) do
    api_request(state, :post, "/runs/log-batch", %{
      "run_id" => state.run_id,
      "metrics" => metrics,
      "params" => params,
      "tags" => tags
    })
  end

  defp fetch_table(state, path) do
    with {:ok, url} <- artifact_url(state, path),
         {:ok, response} <- raw_request(state, :get, url, state.headers, "") do
      cond do
        response.status in 200..299 -> decode_table(response.body)
        response.status == 404 -> {:ok, %{"columns" => [], "data" => []}}
        true -> {:error, http_error(response)}
      end
    end
  end

  defp tag_table(state, path) do
    with {:ok, body} <- api_request(state, :get, "/runs/get", %{"run_id" => state.run_id}),
         {:ok, artifacts} <- logged_artifacts(body) do
      maybe_tag_table(state, artifacts, %{"path" => path, "type" => "table"})
    end
  end

  defp maybe_tag_table(state, artifacts, entry) do
    if entry in artifacts, do: :ok, else: add_table_tag(state, artifacts, entry)
  end

  defp add_table_tag(state, artifacts, entry) do
    with {:ok, encoded} <- Jason.encode(artifacts ++ [entry]),
         {:ok, _body} <-
           log_batch(state, [], [], [
             %{"key" => @logged_artifacts_tag, "value" => encoded}
           ]) do
      :ok
    end
  end

  defp logged_artifacts(body) do
    value =
      get_in(body, ["run", "data", "tags"])
      |> List.wrap()
      |> Enum.find_value("[]", fn
        %{"key" => @logged_artifacts_tag, "value" => value} -> value
        _tag -> nil
      end)

    case Jason.decode(value) do
      {:ok, artifacts} when is_list(artifacts) -> {:ok, artifacts}
      _error -> {:error, {:invalid_logged_artifacts_tag, value}}
    end
  end

  defp normalize_table(rows) when is_list(rows) do
    if Enum.all?(rows, &is_map/1),
      do: normalize_table_rows(rows),
      else: {:error, {:invalid_table_rows, rows}}
  end

  defp normalize_table(%{} = table) do
    columns = Map.get(table, "columns", Map.get(table, :columns))
    data = Map.get(table, "data", Map.get(table, :data))

    if is_list(columns) and is_list(data) and
         Enum.all?(data, &(is_list(&1) and length(&1) == length(columns))) do
      {:ok, %{"columns" => Enum.map(columns, &to_string/1), "data" => data}}
    else
      {:error, {:invalid_split_table, table}}
    end
  end

  defp normalize_table(data), do: {:error, {:invalid_table, data}}

  defp normalize_table_rows(rows) do
    columns =
      rows |> Enum.flat_map(&Map.keys/1) |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

    data =
      Enum.map(rows, fn row ->
        normalized = Map.new(row, fn {key, value} -> {to_string(key), value} end)
        Enum.map(columns, &Map.get(normalized, &1))
      end)

    {:ok, %{"columns" => columns, "data" => data}}
  end

  defp decode_table(body) do
    with {:ok, decoded} <- decode_json(body), do: normalize_table(decoded)
  end

  defp append_table(existing, incoming) do
    columns = Enum.uniq(existing["columns"] ++ incoming["columns"])
    existing_rows = remap_rows(existing, columns)
    incoming_rows = remap_rows(incoming, columns)
    %{"columns" => columns, "data" => existing_rows ++ incoming_rows}
  end

  defp remap_rows(table, columns) do
    Enum.map(table["data"], fn values ->
      row = table["columns"] |> Enum.zip(values) |> Map.new()
      Enum.map(columns, &Map.get(row, &1))
    end)
  end

  defp artifact_url(%__MODULE__{artifact_uri: nil}, _path),
    do: {:error, :run_has_no_artifact_uri}

  defp artifact_url(%__MODULE__{} = state, path) do
    artifact = URI.parse(state.artifact_uri)
    tracking = URI.parse(state.tracking_uri)

    with :ok <- supported_artifact_scheme(artifact.scheme),
         {:ok, artifact_root} <- safe_artifact_path(artifact.path),
         {:ok, safe_path} <- safe_artifact_path(path) do
      root_path = join_url_paths(tracking.path, @artifact_prefix, artifact_root, safe_path)

      {:ok,
       %URI{
         scheme: tracking.scheme,
         host: tracking.host,
         port: tracking.port,
         path: root_path
       }
       |> URI.to_string()}
    end
  end

  defp supported_artifact_scheme("mlflow-artifacts"), do: :ok

  defp supported_artifact_scheme(scheme),
    do: {:error, {:unsupported_artifact_uri_scheme, scheme}}

  defp safe_artifact_path(path) when is_binary(path) and path != "" do
    segments = String.split(path, "/", trim: true)

    cond do
      segments == [] ->
        {:error, {:invalid_artifact_path, path}}

      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, {:invalid_artifact_path, path}}

      true ->
        {:ok,
         Enum.map_join(segments, "/", fn segment ->
           URI.encode(segment, &URI.char_unreserved?/1)
         end)}
    end
  end

  defp safe_artifact_path(path), do: {:error, {:invalid_artifact_path, path}}

  defp require_json_path(path) when is_binary(path) do
    if String.ends_with?(path, ".json"),
      do: :ok,
      else: {:error, {:table_requires_json_artifact, path}}
  end

  defp require_json_path(path), do: {:error, {:invalid_artifact_path, path}}

  defp api_request(state, method, endpoint, payload) do
    {url, body} =
      if method == :get do
        {state.tracking_uri <> @api_prefix <> endpoint <> "?" <> URI.encode_query(payload), ""}
      else
        {state.tracking_uri <> @api_prefix <> endpoint, Jason.encode!(payload)}
      end

    headers = [{"content-type", "application/json"} | state.headers]

    with {:ok, response} <- raw_request(state, method, url, headers, body),
         :ok <- expect_success(response) do
      decode_json(response.body)
    end
  end

  defp raw_request(state, method, url, headers, body) do
    state.transport.request(method, url, headers, body, state.transport_opts)
  rescue
    error -> {:error, {:transport_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:transport_failure, kind, reason}}
  end

  defp expect_success(%{status: status}) when status in 200..299, do: :ok
  defp expect_success(response), do: {:error, http_error(response)}

  defp http_error(%{status: status, body: body}) do
    decoded =
      case decode_json(body) do
        {:ok, value} -> value
        _error -> body
      end

    {:http_error, status, decoded}
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}
  defp decode_json(""), do: {:ok, %{}}
  defp decode_json(body) when is_binary(body), do: Jason.decode(body)
  defp decode_json(body), do: {:error, {:invalid_json_body, body}}

  defp missing?({:http_error, 404, _body}), do: true
  defp missing?({:http_error, _status, %{"error_code" => "RESOURCE_DOES_NOT_EXIST"}}), do: true
  defp missing?(_error), do: false

  defp already_exists?({:http_error, 409, _body}), do: true

  defp already_exists?({:http_error, _status, %{"error_code" => "RESOURCE_ALREADY_EXISTS"}}),
    do: true

  defp already_exists?(_error), do: false

  defp tracking_uri(opts) do
    case Keyword.fetch(opts, :tracking_uri) do
      {:ok, uri} when is_binary(uri) ->
        parsed = URI.parse(uri)

        if parsed.scheme in ["http", "https"] and is_binary(parsed.host) do
          {:ok, String.trim_trailing(uri, "/")}
        else
          {:error, {:unsupported_tracking_uri, uri}}
        end

      {:ok, uri} ->
        {:error, {:unsupported_tracking_uri, uri}}

      :error ->
        {:error, :tracking_uri_required}
    end
  end

  defp transport(opts) do
    transport = Keyword.get(opts, :transport, Imp.Tracking.Transport.Req)

    if is_atom(transport) and Code.ensure_loaded?(transport) and
         function_exported?(transport, :request, 5) do
      {:ok, transport}
    else
      {:error, {:invalid_transport, transport}}
    end
  end

  defp auth_headers(opts) do
    auth_headers(
      Keyword.get(opts, :token),
      Keyword.get(opts, :username),
      Keyword.get(opts, :password)
    )
  end

  defp auth_headers(token, nil, nil) when is_binary(token) and token != "",
    do: {:ok, [{"authorization", "Bearer #{token}"}]}

  defp auth_headers(nil, username, password)
       when is_binary(username) and username != "" and is_binary(password) and password != "" do
    encoded = Base.encode64(username <> ":" <> password)
    {:ok, [{"authorization", "Basic #{encoded}"}]}
  end

  defp auth_headers(nil, nil, nil), do: {:ok, []}
  defp auth_headers(_token, _username, _password), do: {:error, :invalid_mlflow_auth}

  defp base_state(opts, tracking_uri, transport, headers) do
    transport_opts = Keyword.get(opts, :transport_opts, [])

    if is_list(transport_opts) and Keyword.keyword?(transport_opts) do
      {:ok,
       %__MODULE__{
         tracking_uri: tracking_uri,
         transport: transport,
         transport_opts: transport_opts,
         headers: headers,
         run_id: "",
         experiment_id: "",
         artifact_uri: nil,
         owned_run: false,
         finish_adopted_run: Keyword.get(opts, :finish_adopted_run, false)
       }}
    else
      {:error, {:invalid_transport_opts, transport_opts}}
    end
  end

  defp run_tags(tags) do
    with {:ok, entries} <- key_value_entries(tags) do
      {:ok,
       Enum.map(entries, fn {key, value} -> %{"key" => key, "value" => stringify(value)} end)}
    end
  end

  defp key_value_entries(map) when is_map(map) do
    {:ok, map |> Enum.map(fn {key, value} -> {to_string(key), value} end) |> Enum.sort()}
  end

  defp key_value_entries(list) when is_list(list) do
    if Keyword.keyword?(list),
      do: key_value_entries(Map.new(list)),
      else: {:error, {:expected_map, list}}
  end

  defp key_value_entries(value), do: {:error, {:expected_map, value}}

  defp metric_payload(entries, timestamp, step) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_number(value) ->
        metric = %{"key" => key, "value" => value, "timestamp" => timestamp, "step" => step}
        {:cont, {:ok, [metric | acc]}}

      {key, value}, _acc ->
        {:halt, {:error, {:non_numeric_metric, key, value}}}
    end)
    |> case do
      {:ok, metrics} -> {:ok, Enum.reverse(metrics)}
      error -> error
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value |> Report.json_safe() |> Jason.encode!()

  defp finish_status(:finished), do: {:ok, "FINISHED"}
  defp finish_status(:success), do: {:ok, "FINISHED"}
  defp finish_status(:ok), do: {:ok, "FINISHED"}
  defp finish_status(:failed), do: {:ok, "FAILED"}
  defp finish_status(:failure), do: {:ok, "FAILED"}
  defp finish_status(:error), do: {:ok, "FAILED"}
  defp finish_status(:killed), do: {:ok, "KILLED"}
  defp finish_status(:cancelled), do: {:ok, "KILLED"}
  defp finish_status(status), do: {:error, {:invalid_run_status, status}}

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _error -> {:error, {:invalid_mlflow_response, {:missing_map, key}, map}}
    end
  end

  defp fetch_id(map, keys) do
    case Enum.find_value(keys, &Map.get(map, &1)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) -> {:ok, Integer.to_string(value)}
      _value -> {:error, {:invalid_mlflow_response, {:missing_id, keys}, map}}
    end
  end

  defp fetch_optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_mlflow_response, {:invalid_string, key}, value}}
    end
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp join_url_paths(paths) do
    "/" <>
      (paths
       |> Enum.map(&to_string/1)
       |> Enum.flat_map(&String.split(&1, "/", trim: true))
       |> Enum.join("/"))
  end

  defp join_url_paths(a, b, c, d), do: join_url_paths([a, b, c, d])

  defp now_ms, do: System.system_time(:millisecond)
end

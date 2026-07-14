# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Imp.Tracking.WandB.V0_21_3 do
  @moduledoc false

  # This module intentionally pins undocumented wire details observed in the
  # official W&B SDK v0.21.3. Re-audit it before claiming compatibility with a
  # different W&B SDK or self-hosted server version.

  alias Imp.Tracking.WandB.Transport

  @user_agent "wandb-sdk-elixir/0.21.3"

  @viewer_query """
  query Viewer {
    viewer {
      id
      entity
    }
  }
  """

  @upsert_bucket_mutation """
  mutation UpsertBucket(
    $id: String,
    $name: String,
    $project: String,
    $entity: String,
    $groupName: String,
    $displayName: String,
    $notes: String,
    $jobType: String,
    $state: String,
    $tags: [String!]
  ) {
    upsertBucket(input: {
      id: $id,
      name: $name,
      modelName: $project,
      entityName: $entity,
      groupName: $groupName,
      displayName: $displayName,
      notes: $notes,
      jobType: $jobType,
      state: $state,
      tags: $tags
    }) {
      bucket {
        id
        name
        displayName
        historyLineCount
        project {
          name
          entity {
            name
          }
        }
      }
      inserted
    }
  }
  """

  @create_run_files_mutation """
  mutation CreateRunFiles(
    $entity: String!,
    $project: String!,
    $run: String!,
    $files: [String!]!
  ) {
    createRunFiles(input: {
      entityName: $entity,
      projectName: $project,
      runName: $run,
      files: $files
    }) {
      runID
      uploadHeaders
      files {
        name
        uploadUrl
      }
    }
  }
  """

  @spec verify(struct()) :: {:ok, map()} | {:error, term()}
  def verify(client), do: graphql(client, "Viewer", @viewer_query, %{}, ["viewer"])

  @spec upsert_bucket(struct(), map()) :: {:ok, map()} | {:error, term()}
  def upsert_bucket(client, variables) do
    graphql(
      client,
      "UpsertBucket",
      @upsert_bucket_mutation,
      variables,
      ["upsertBucket"]
    )
  end

  @spec stream(struct(), map()) :: :ok | {:error, term()}
  def stream(client, payload) do
    request_json(client, :post, file_stream_url(client), auth_headers(client), payload)
    |> expect_empty_success(:file_stream)
  end

  @spec history_payload(non_neg_integer(), map()) :: map()
  def history_payload(offset, row) do
    %{
      "files" => %{
        "wandb-history.jsonl" => %{
          "offset" => offset,
          "content" => [Jason.encode!(row)]
        }
      },
      "dropped" => 0
    }
  end

  @spec summary_payload(map()) :: map()
  def summary_payload(summary) do
    %{
      "files" => %{
        "wandb-summary.json" => %{
          "offset" => 0,
          "content" => [Jason.encode!(summary)]
        }
      },
      "dropped" => 0
    }
  end

  @spec uploaded_payload(String.t()) :: map()
  def uploaded_payload(path) do
    %{
      "complete" => false,
      "failed" => false,
      "dropped" => 0,
      "uploaded" => [path]
    }
  end

  @spec finish_payload(non_neg_integer()) :: map()
  def finish_payload(exit_code) do
    %{
      "complete" => true,
      "exitcode" => exit_code,
      "dropped" => 0,
      "uploaded" => []
    }
  end

  @spec upload_media(struct(), String.t(), binary()) :: :ok | {:error, term()}
  def upload_media(client, path, contents) do
    variables = %{
      "entity" => client.entity,
      "project" => client.project,
      "run" => client.id,
      "files" => [path]
    }

    with {:ok, prepared} <-
           graphql(
             client,
             "CreateRunFiles",
             @create_run_files_mutation,
             variables,
             ["createRunFiles"]
           ),
         :ok <- validate_prepared_run(prepared, client, path),
         {:ok, file} <- prepared_file(prepared, path),
         :ok <- put_signed_file(client, prepared, file, contents) do
      stream(client, uploaded_payload(path))
    end
  end

  @spec media_path(:table | :html, String.t(), non_neg_integer(), binary()) :: String.t()
  def media_path(kind, key, step, contents) do
    digest = sha256(contents)
    safe_key = String.replace(key, ~r/[^A-Za-z0-9_.-]/, "_")
    {directory, extension} = media_location(kind)
    "#{directory}/#{safe_key}_#{step}_#{String.slice(digest, 0, 20)}#{extension}"
  end

  @spec media_ref(:table | :html, String.t(), binary(), keyword()) :: map()
  def media_ref(kind, path, contents, metadata \\ []) do
    base = %{
      "_type" => media_type(kind),
      "path" => path,
      "sha256" => sha256(contents),
      "size" => byte_size(contents)
    }

    Enum.reduce(metadata, base, fn {key, value}, acc -> Map.put(acc, to_string(key), value) end)
  end

  defp graphql(client, operation, query, variables, path) do
    payload = %{"operationName" => operation, "query" => query, "variables" => variables}

    with {:ok, response} <-
           request_json(client, :post, graphql_url(client), auth_headers(client), payload),
         :ok <- successful_status(response.status, operation),
         {:ok, decoded} <- decode_json(response.body, operation),
         :ok <- reject_graphql_errors(decoded, operation) do
      fetch_path(decoded, ["data" | path], operation)
    end
  end

  defp request_json(client, method, url, headers, payload) do
    headers = [{"Content-Type", "application/json"} | headers]
    request(client, method, url, headers, Jason.encode!(payload))
  end

  defp request(client, method, url, headers, body) do
    Transport.request(client.transport, method, url, headers, body, client.request_opts)
  end

  defp put_signed_file(_client, _prepared, %{"uploadUrl" => nil}, _contents), do: :ok

  defp put_signed_file(client, prepared, %{"uploadUrl" => upload_url}, contents)
       when is_binary(upload_url) do
    headers = parse_upload_headers(Map.get(prepared, "uploadHeaders", []))
    url = absolute_upload_url(client.base_url, upload_url)

    case request(client, :put, url, headers, contents) do
      {:ok, response} -> expect_empty_success({:ok, response}, :signed_upload)
      {:error, _reason} = error -> error
    end
  end

  defp put_signed_file(_client, _prepared, file, _contents),
    do: {:error, {:wandb_protocol_error, :invalid_upload_url, file}}

  defp validate_prepared_run(%{"runID" => run_id}, client, _path)
       when run_id in [client.storage_id, client.id],
       do: :ok

  defp validate_prepared_run(%{"runID" => run_id}, _client, path),
    do: {:error, {:wandb_protocol_error, :unexpected_run_id, path, run_id}}

  defp validate_prepared_run(prepared, _client, _path),
    do: {:error, {:wandb_protocol_error, :missing_run_id, prepared}}

  defp prepared_file(%{"files" => files}, path) when is_list(files) do
    case Enum.find(files, &(Map.get(&1, "name") == path)) do
      nil -> {:error, {:wandb_protocol_error, :missing_prepared_file, path}}
      file -> {:ok, file}
    end
  end

  defp prepared_file(prepared, path),
    do: {:error, {:wandb_protocol_error, :invalid_prepared_files, path, prepared}}

  defp auth_headers(client) do
    [{"User-Agent", @user_agent}, {"Authorization", client.authorization}]
  end

  defp graphql_url(client), do: client.base_url <> "/graphql"

  defp file_stream_url(client) do
    client.base_url <>
      "/files/#{uri_segment(client.entity)}/#{uri_segment(client.project)}/" <>
      "#{uri_segment(client.id)}/file_stream"
  end

  defp uri_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp successful_status(status, _operation) when status in 200..299, do: :ok

  defp successful_status(status, operation),
    do: {:error, {:wandb_http_error, operation, status}}

  defp decode_json("", _operation), do: {:ok, %{}}

  defp decode_json(body, operation) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:wandb_protocol_error, operation, error}}
    end
  end

  defp reject_graphql_errors(%{"errors" => errors}, operation)
       when is_list(errors) and errors != [],
       do: {:error, {:wandb_graphql_error, operation, errors}}

  defp reject_graphql_errors(_decoded, _operation), do: :ok

  defp fetch_path(value, [], _operation), do: {:ok, value}

  defp fetch_path(map, [key | rest], operation) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest, operation)
      :error -> {:error, {:wandb_protocol_error, operation, {:missing_key, key}}}
    end
  end

  defp fetch_path(_value, [key | _rest], operation),
    do: {:error, {:wandb_protocol_error, operation, {:missing_key, key}}}

  defp expect_empty_success({:ok, %{status: status}}, _operation) when status in 200..299,
    do: :ok

  defp expect_empty_success({:ok, %{status: status}}, operation),
    do: {:error, {:wandb_http_error, operation, status}}

  defp expect_empty_success({:error, _reason} = error, _operation), do: error

  defp parse_upload_headers(headers) when is_list(headers) do
    Enum.map(headers, fn header ->
      case String.split(header, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        [key] -> {String.trim(key), ""}
      end
    end)
  end

  defp absolute_upload_url(base_url, "/" <> _rest = path), do: base_url <> path
  defp absolute_upload_url(_base_url, url), do: url

  defp media_location(:table), do: {"media/table", ".table.json"}
  defp media_location(:html), do: {"media/html", ".html"}
  defp media_type(:table), do: "table-file"
  defp media_type(:html), do: "html-file"

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end

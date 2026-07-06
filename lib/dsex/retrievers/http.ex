defmodule DSEx.Retrievers.HTTP do
  @moduledoc "Generic HTTP retriever with injectable transport and response mapping."

  @behaviour DSEx.Retrieve

  defstruct [
    :url,
    transport: DSEx.HTTP.Hackneyless,
    headers: [],
    body_builder: nil,
    response_mapper: nil,
    method: :post
  ]

  @option_schema [
    transport: [type: :any],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    body_builder: [type: {:fun, 2}],
    response_mapper: [type: {:fun, 1}],
    method: [type: :atom]
  ]

  def new(url, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

    %__MODULE__{
      url: url,
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      body_builder: Keyword.get(opts, :body_builder, &default_body/2),
      response_mapper: Keyword.get(opts, :response_mapper, &default_mapper/1),
      method: Keyword.get(opts, :method, :post)
    }
  end

  @impl true
  def retrieve(retriever, query, opts \\ [])

  def retrieve(%__MODULE__{method: method}, _query, _opts) when method != :post do
    {:error, {:unsupported_http_method, method}}
  end

  def retrieve(%__MODULE__{} = retriever, query, opts) do
    DSEx.Telemetry.span([:dsex, :retriever], %{url: retriever.url, query: query}, fn ->
      body = retriever.body_builder.(query, opts) |> Jason.encode!()
      headers = [{"content-type", "application/json"} | retriever.headers]

      with {:ok, %{status: status, body: response}} when status in 200..299 <-
             DSEx.HTTP.post(retriever.transport, retriever.url, headers, body, opts),
           {:ok, decoded} <- Jason.decode(response) do
        {:ok, retriever.response_mapper.(decoded)}
      else
        {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp default_body(query, opts), do: %{query: query, k: Keyword.get(opts, :k, 3)}

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
end

defmodule DSEx.Retrievers.Weaviate do
  @moduledoc "Weaviate GraphQL retriever."

  @option_schema [
    transport: [type: :any],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    k: [type: :pos_integer],
    field: [type: :string]
  ]

  def new(base_url, class_name, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/3")
    endpoint = String.trim_trailing(base_url, "/") <> "/v1/graphql"

    DSEx.Retrievers.HTTP.new(endpoint,
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      body_builder: fn query, call_opts ->
        limit = Keyword.get(call_opts, :k, Keyword.get(opts, :k, 3))
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
end

defmodule DSEx.Retrievers.Databricks do
  @moduledoc "Databricks Vector Search retriever."

  @option_schema [
    transport: [type: :any],
    headers: [type: {:list, {:tuple, [:any, :any]}}],
    token: [type: {:or, [:string, nil]}],
    k: [type: :pos_integer],
    columns: [type: {:list, :string}]
  ]

  def new(endpoint_url, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

    DSEx.Retrievers.HTTP.new(endpoint_url,
      transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
      headers: auth_headers(opts) ++ Keyword.get(opts, :headers, []),
      body_builder: fn query, call_opts ->
        %{
          query_text: query,
          num_results: Keyword.get(call_opts, :k, Keyword.get(opts, :k, 3)),
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
end

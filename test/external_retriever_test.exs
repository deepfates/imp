defmodule ExternalRetrieverTest do
  use ExUnit.Case

  defmodule WeaviateTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      send(self(), {:weaviate_request, url, headers, Jason.decode!(body)})

      response = %{
        data: %{
          Get: %{
            Passage: [
              %{text: "Paris is the capital of France.", _additional: %{score: 0.91, id: "p1"}}
            ]
          }
        }
      }

      {:ok, %{status: 200, headers: [], body: Jason.encode!(response)}}
    end
  end

  defmodule DatabricksTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      send(self(), {:databricks_request, url, headers, Jason.decode!(body)})

      response = %{
        manifest: %{columns: [%{name: "text"}, %{name: "score"}, %{name: "doc_id"}]},
        result: %{data_array: [["Paris is the capital of France.", 0.88, "d1"]]}
      }

      {:ok, %{status: 200, headers: [], body: Jason.encode!(response)}}
    end
  end

  test "Weaviate retriever builds GraphQL request and maps documents" do
    retriever =
      DSEx.Retrievers.Weaviate.new("https://weaviate.example", "Passage",
        transport: WeaviateTransport
      )

    assert {:ok, [%{text: "Paris is the capital of France.", score: 0.91, metadata: metadata}]} =
             DSEx.Retrieve.retrieve(retriever, "capital France", k: 1)

    assert metadata["id"] == "p1"
    assert_received {:weaviate_request, "https://weaviate.example/v1/graphql", headers, body}
    assert {"content-type", "application/json"} in headers
    assert body["query"] =~ "nearText"
    assert body["query"] =~ "capital France"
  end

  test "Databricks retriever builds vector-search request and maps rows" do
    ref =
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :retriever, :start],
        [:dsex, :retriever, :stop]
      ])

    retriever =
      DSEx.Retrievers.Databricks.new(
        "https://dbc.example/api/2.0/vector-search/indexes/i/query",
        transport: DatabricksTransport,
        token: "dbc-token"
      )

    assert {:ok, [%{text: "Paris is the capital of France.", score: 0.88, metadata: metadata}]} =
             DSEx.Retrieve.retrieve(retriever, "capital France", k: 1)

    assert metadata["doc_id"] == "d1"

    assert_received {:databricks_request,
                     "https://dbc.example/api/2.0/vector-search/indexes/i/query", headers, body}

    assert {"authorization", "Bearer dbc-token"} in headers
    assert body["query_text"] == "capital France"
    assert body["num_results"] == 1
    assert_received {^ref, [:dsex, :retriever, :start], _, %{query: "capital France"}}

    assert_received {^ref, [:dsex, :retriever, :stop], %{duration: duration}, %{result: :ok}}

    assert is_integer(duration)
  end

  test "Databricks retriever does not bind ambient token to explicit endpoints" do
    Process.put(:previous_databricks_token, System.get_env("DATABRICKS_TOKEN"))
    System.put_env("DATABRICKS_TOKEN", "ambient-token")

    retriever =
      DSEx.Retrievers.Databricks.new(
        "https://dbc.example/api/2.0/vector-search/indexes/i/query",
        transport: DatabricksTransport
      )

    assert {:ok, [_doc]} = DSEx.Retrieve.retrieve(retriever, "capital France", k: 1)

    assert_received {:databricks_request,
                     "https://dbc.example/api/2.0/vector-search/indexes/i/query", headers, _body}

    refute {"authorization", "Bearer ambient-token"} in headers
  after
    if previous = Process.get(:previous_databricks_token) do
      System.put_env("DATABRICKS_TOKEN", previous)
    else
      System.delete_env("DATABRICKS_TOKEN")
    end

    Process.delete(:previous_databricks_token)
  end

  test "generic HTTP retriever rejects unsupported methods explicitly" do
    retriever =
      DSEx.Retrievers.HTTP.new("https://retriever.example/search",
        transport: DatabricksTransport,
        method: :get
      )

    assert {:error, {:unsupported_http_method, :get}} =
             DSEx.Retrieve.retrieve(retriever, "capital France")
  end
end

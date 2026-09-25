defmodule ExternalRetrieverTest do
  use ExUnit.Case

  setup do
    Process.register(self(), __MODULE__.TransportOwner)
    :ok
  end

  defmodule WeaviateTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      send(ExternalRetrieverTest.TransportOwner, {
        :weaviate_request,
        url,
        headers,
        Jason.decode!(body)
      })

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
    @behaviour Imp.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      send(ExternalRetrieverTest.TransportOwner, {
        :databricks_request,
        url,
        headers,
        Jason.decode!(body)
      })

      response = %{
        manifest: %{columns: [%{name: "text"}, %{name: "score"}, %{name: "doc_id"}]},
        result: %{data_array: [["Paris is the capital of France.", 0.88, "d1"]]}
      }

      {:ok, %{status: 200, headers: [], body: Jason.encode!(response)}}
    end
  end

  defmodule RaisingTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: raise("retriever transport exploded")
  end

  defmodule InvalidJSONTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: {:ok, %{status: 200, headers: [], body: "nope"}}
  end

  defmodule InvalidShapeTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: :not_an_http_response
  end

  test "Weaviate retriever builds GraphQL request and maps documents" do
    retriever =
      Imp.Retrievers.Weaviate.new("https://weaviate.example", "Passage",
        transport: WeaviateTransport
      )

    assert {:ok, [%{text: "Paris is the capital of France.", score: 0.91, metadata: metadata}]} =
             Imp.Retrieve.retrieve(retriever, "capital France", k: 1)

    assert metadata["id"] == "p1"
    assert_received {:weaviate_request, "https://weaviate.example/v1/graphql", headers, body}
    assert {"content-type", "application/json"} in headers
    assert body["query"] =~ "nearText"
    assert body["query"] =~ "capital France"
  end

  test "HTTP retriever constructors reject invalid positional boundaries" do
    assert_raise ArgumentError,
                 ~r/Imp\.Retrievers\.HTTP\.new\/2 expects url to be a binary/,
                 fn ->
                   Imp.Retrievers.HTTP.new(:not_a_url)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Retrievers\.Weaviate\.new\/3 expects base_url to be a binary/,
                 fn ->
                   Imp.Retrievers.Weaviate.new(:not_a_url, "Passage")
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Retrievers\.Weaviate\.new\/3 expects class_name to be a binary/,
                 fn ->
                   Imp.Retrievers.Weaviate.new("https://weaviate.example", :not_a_class)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Retrievers\.Databricks\.new\/2 expects endpoint_url to be a binary/,
                 fn ->
                   Imp.Retrievers.Databricks.new(:not_a_url)
                 end
  end

  test "Databricks retriever builds vector-search request and maps rows" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :retriever, :start],
        [:imp, :retriever, :stop]
      ])

    retriever =
      Imp.Retrievers.Databricks.new(
        "https://dbc.example/api/2.0/vector-search/indexes/i/query",
        transport: DatabricksTransport,
        token: "dbc-token"
      )

    assert {:ok, [%{text: "Paris is the capital of France.", score: 0.88, metadata: metadata}]} =
             Imp.Retrieve.retrieve(retriever, "capital France", k: 1)

    assert metadata["doc_id"] == "d1"

    assert_received {:databricks_request,
                     "https://dbc.example/api/2.0/vector-search/indexes/i/query", headers, body}

    assert {"authorization", "Bearer dbc-token"} in headers
    assert body["query_text"] == "capital France"
    assert body["num_results"] == 1
    assert_received {^ref, [:imp, :retriever, :start], _, %{retriever: Imp.Retrievers.HTTP}}

    assert_received {^ref, [:imp, :retriever, :stop], %{duration: duration}, %{result: :ok}}

    assert is_integer(duration)
  end

  test "Databricks retriever does not bind ambient token to explicit endpoints" do
    Process.put(:previous_databricks_token, System.get_env("DATABRICKS_TOKEN"))
    System.put_env("DATABRICKS_TOKEN", "ambient-token")

    retriever =
      Imp.Retrievers.Databricks.new(
        "https://dbc.example/api/2.0/vector-search/indexes/i/query",
        transport: DatabricksTransport
      )

    assert {:ok, [_doc]} = Imp.Retrieve.retrieve(retriever, "capital France", k: 1)

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

  test "HTTP retriever families accept zero k and reject invalid per-call k" do
    generic =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: DatabricksTransport
      )

    assert {:ok, [_doc]} = Imp.Retrieve.retrieve(generic, "capital France", k: 0)

    assert_received {:databricks_request, "https://retriever.example/search", _headers,
                     generic_body}

    assert generic_body["k"] == 0

    weaviate =
      Imp.Retrievers.Weaviate.new("https://weaviate.example", "Passage",
        transport: WeaviateTransport
      )

    assert {:ok, [_doc]} = Imp.Retrieve.retrieve(weaviate, "capital France", k: 0)
    assert_received {:weaviate_request, "https://weaviate.example/v1/graphql", _headers, body}
    assert body["query"] =~ "limit: 0"

    databricks =
      Imp.Retrievers.Databricks.new(
        "https://dbc.example/api/2.0/vector-search/indexes/i/query",
        transport: DatabricksTransport
      )

    assert {:ok, [_doc]} = Imp.Retrieve.retrieve(databricks, "capital France", k: 0)

    assert_received {:databricks_request,
                     "https://dbc.example/api/2.0/vector-search/indexes/i/query", _headers,
                     databricks_body}

    assert databricks_body["num_results"] == 0

    assert {:error, {:invalid_retriever_request, generic_message}} =
             Imp.Retrieve.retrieve(generic, "capital France", k: -1)

    assert generic_message =~ "retriever :k must be a non-negative integer"

    assert {:error, {:invalid_retriever_request, weaviate_message}} =
             Imp.Retrieve.retrieve(weaviate, "capital France", k: -3)

    assert weaviate_message =~ "retriever :k must be a non-negative integer"

    assert {:error, {:invalid_retriever_request, databricks_message}} =
             Imp.Retrieve.retrieve(databricks, "capital France", k: :bad)

    assert databricks_message =~ "retriever :k must be a non-negative integer"
  end

  test "generic HTTP retriever rejects unsupported methods explicitly" do
    retriever =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: DatabricksTransport,
        method: :get
      )

    assert {:error, {:http_method_not_supported, Imp.Retrievers.HTTP, :get}} =
             Imp.Retrieve.retrieve(retriever, "capital France")
  end

  test "retriever facade reports callback crashes and invalid results" do
    assert {:error,
            {:retriever_failed, :anonymous_retriever,
             %RuntimeError{message: "retriever exploded"}}} =
             Imp.Retrieve.retrieve(fn _query, _opts -> raise "retriever exploded" end, "q")

    assert {:ok, [%{text: "Paris", id: "p1"}]} =
             Imp.Retrieve.retrieve(
               fn _query, _opts -> {:ok, [[text: "Paris", id: "p1"]]} end,
               "q"
             )

    assert {:error, {:invalid_retriever_result, :not_docs}} =
             Imp.Retrieve.retrieve(fn _query, _opts -> {:ok, :not_docs} end, "q")

    assert {:error, {:invalid_retriever_document, :not_a_doc}} =
             Imp.Retrieve.retrieve(fn _query, _opts -> {:ok, [:not_a_doc]} end, "q")

    assert {:error, {:invalid_retriever_document, [:not_a_pair]}} =
             Imp.Retrieve.retrieve(fn _query, _opts -> {:ok, [[:not_a_pair]]} end, "q")

    assert {:error, {:not_a_retriever, String}} = Imp.Retrieve.retrieve(String, "q")
  end

  test "retriever facade validates option containers before dispatch" do
    callback = fn _query, _opts ->
      send(self(), :retriever_callback_ran)
      {:ok, [%{text: "should not run"}]}
    end

    assert_raise ArgumentError,
                 ~r/Imp.Retrieve.retrieve\/3 expects keyword options/,
                 fn ->
                   Imp.Retrieve.retrieve(callback, "q", %{k: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Retrieve.retrieve\/3 expects keyword options/,
                 fn ->
                   Imp.Retrieve.retrieve(callback, "q", [:not_a_pair])
                 end

    refute_received :retriever_callback_ran
  end

  test "a retriever module is called without options" do
    retriever = Imp.Retrieve.Memory.new([%{text: "Paris"}])
    assert {:ok, [%{text: "Paris"}]} = Imp.Retrieve.Memory.retrieve(retriever, "Paris")

    http = Imp.Retrievers.HTTP.new("http://127.0.0.1:1/search", method: :get)

    assert {:error, {:http_method_not_supported, Imp.Retrievers.HTTP, :get}} =
             Imp.Retrievers.HTTP.retrieve(http, "Paris")
  end

  test "memory retriever treats zero k as explicit no documents and rejects negative k" do
    retriever = Imp.Retrieve.Memory.new([%{text: "Paris"}], k: 0)
    assert {:ok, []} = Imp.Retrieve.retrieve(retriever, "Paris")

    assert {:ok, []} =
             Imp.Retrieve.retrieve(Imp.Retrieve.Memory.new([%{text: "Paris"}]), "Paris", k: 0)

    assert_raise ArgumentError,
                 ~r/Imp\.Retrieve\.Memory\.new\/2: invalid value for :k option: expected non negative integer/,
                 fn ->
                   Imp.Retrieve.Memory.new([%{text: "Paris"}], k: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Retrieve\.Memory\.retrieve\/3: invalid value for :k option: expected non negative integer/,
                 fn ->
                   Imp.Retrieve.Memory.retrieve(
                     Imp.Retrieve.Memory.new([%{text: "Paris"}]),
                     "Paris",
                     k: -1
                   )
                 end

    assert {:error, {:retriever_failed, Imp.Retrieve.Memory, %ArgumentError{message: message}}} =
             Imp.Retrieve.retrieve(Imp.Retrieve.Memory.new([%{text: "Paris"}]), "Paris", k: -1)

    assert message =~ "expected non negative integer"
  end

  test "memory retriever reports invalid construction and document inputs clearly" do
    assert_raise ArgumentError, ~r/Imp\.Retrieve\.Memory\.new\/2 expects a list/, fn ->
      Imp.Retrieve.Memory.new(:not_docs)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Retrieve\.Memory\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Retrieve.Memory.new([%{text: "Paris"}], :not_options)
                 end

    retriever = Imp.Retrieve.Memory.new([:not_a_document])

    assert {:error, {:invalid_memory_document, :not_a_document}} =
             Imp.Retrieve.retrieve(retriever, "Paris")

    retriever = Imp.Retrieve.Memory.new([[:not_a_pair]])

    assert {:error, {:invalid_memory_document, [:not_a_pair]}} =
             Imp.Retrieve.retrieve(retriever, "Paris")
  end

  test "generic HTTP retriever reports request transport decode and mapper failures" do
    bad_request =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        body_builder: fn _query, _opts -> raise "bad body" end
      )

    assert {:error, {:invalid_retriever_request, "bad body"}} =
             Imp.Retrieve.retrieve(bad_request, "capital France")

    bad_transport =
      Imp.Retrievers.HTTP.new("https://retriever.example/search", transport: RaisingTransport)

    assert {:error,
            {:retriever_http_failed,
             {:transport, %RuntimeError{message: "retriever transport exploded"}}, 1}} =
             Imp.Retrieve.retrieve(bad_transport, "capital France")

    invalid_json =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: InvalidJSONTransport
      )

    assert {:error, {:invalid_retriever_response, reason}} =
             Imp.Retrieve.retrieve(invalid_json, "capital France")

    assert reason =~ "unexpected byte"

    invalid_shape =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: InvalidShapeTransport
      )

    assert {:error,
            {:retriever_http_failed, {:invalid_transport_response, :not_an_http_response}, 1}} =
             Imp.Retrieve.retrieve(invalid_shape, "capital France")

    bad_mapper =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: DatabricksTransport,
        response_mapper: fn _decoded -> raise "mapper exploded" end
      )

    assert {:error, {:invalid_retriever_result, "mapper exploded"}} =
             Imp.Retrieve.retrieve(bad_mapper, "capital France")
  end
end

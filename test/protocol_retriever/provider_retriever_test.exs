defmodule ProtocolRetrieverProviderTest do
  use ExUnit.Case

  @moduletag :protocol_retriever

  test "protocol retriever gate exercises Weaviate-compatible HTTP retrieval" do
    ref =
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :retriever, :start],
        [:dsex, :retriever, :stop]
      ])

    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.path == "/v1/graphql"

        payload = Jason.decode!(request.body)
        assert payload["query"] =~ "Passage"
        assert payload["query"] =~ "nearText"
        assert payload["query"] =~ "capital France"
        assert payload["query"] =~ "limit: 2"

        {200,
         %{
           data: %{
             Get: %{
               Passage: [
                 %{
                   text: "Paris is the capital of France.",
                   _additional: %{score: 0.91, id: "p-live"}
                 }
               ]
             }
           }
         }}
      end)

    retriever = DSEx.Retrievers.Weaviate.new(base_url, "Passage")

    assert {:ok, [%{text: "Paris is the capital of France.", score: 0.91, metadata: metadata}]} =
             DSEx.Retrieve.retrieve(retriever, "capital France", k: 2)

    assert metadata["id"] == "p-live"
    assert_received {^ref, [:dsex, :retriever, :start], _, start_metadata}
    assert start_metadata.retriever == DSEx.Retrievers.HTTP
    assert start_metadata.method == :post
    refute Map.has_key?(start_metadata, :query)
    assert_received {^ref, [:dsex, :retriever, :stop], %{duration: duration}, %{result: :ok}}
    assert is_integer(duration)
  end

  test "protocol retriever gate exercises Databricks-compatible vector-search retrieval" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.path == "/api/2.0/vector-search/indexes/catalog.schema.index/query"
        assert request.headers["authorization"] == "Bearer dbc-live-retriever-test"

        payload = Jason.decode!(request.body)
        assert payload["query_text"] == "beam otp"
        assert payload["num_results"] == 1
        assert payload["columns"] == ["text", "score", "doc_id"]

        {200,
         %{
           manifest: %{columns: [%{name: "text"}, %{name: "score"}, %{name: "doc_id"}]},
           result: %{data_array: [["OTP supervision is explicit.", 0.87, "d-live"]]}
         }}
      end)

    retriever =
      DSEx.Retrievers.Databricks.new(
        base_url <> "/api/2.0/vector-search/indexes/catalog.schema.index/query",
        token: "dbc-live-retriever-test",
        columns: ["text", "score", "doc_id"]
      )

    assert {:ok, [%{text: "OTP supervision is explicit.", score: 0.87, metadata: metadata}]} =
             DSEx.Retrieve.retrieve(retriever, "beam otp", k: 1)

    assert metadata["doc_id"] == "d-live"
  end
end

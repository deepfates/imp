defmodule MemoryRetrieverTest do
  use ExUnit.Case, async: true

  # A keyword retriever returns documents that share a word with the query, at
  # most k of them; a document that shares none is not a match.
  test "a document with no word in common with the query is not returned" do
    retriever =
      Imp.Retrieve.Memory.new(
        [%{text: "Our office dog is named Biscuit"}, %{text: "Refunds take five days"}],
        k: 2
      )

    assert {:ok, [%{text: "Refunds take five days", score: 2}]} =
             Imp.Retrieve.retrieve(retriever, "how long do refunds take")

    assert {:ok, []} = Imp.Retrieve.retrieve(retriever, "quantum chromodynamics")
  end
end

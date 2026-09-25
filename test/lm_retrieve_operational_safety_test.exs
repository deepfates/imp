defmodule Imp.LMRetrieveOperationalSafetyTest do
  use ExUnit.Case, async: true

  test "raised LM guards remain typed errors while ordinary crashes stay normalized" do
    safety = Imp.OperationalSafetyError.exception(kind: :budget, reason: :task_limit)

    assert {:error, ^safety} =
             Imp.LM.generate(fn _messages, _opts -> raise safety end, [], [])

    assert {:error, {:lm_failed, :anonymous_lm, %RuntimeError{message: "ordinary LM crash"}}} =
             Imp.LM.generate(fn _messages, _opts -> raise "ordinary LM crash" end, [], [])
  end

  test "raised retriever guards remain typed errors while ordinary crashes stay normalized" do
    safety = Imp.OperationalSafetyError.exception(kind: :transport, reason: :offline)

    assert {:error, ^safety} =
             Imp.Retrieve.retrieve(fn _query, _opts -> raise safety end, "query")

    assert {:error,
            {:retriever_failed, :anonymous_retriever,
             %RuntimeError{message: "ordinary retrieval crash"}}} =
             Imp.Retrieve.retrieve(
               fn _query, _opts -> raise "ordinary retrieval crash" end,
               "query"
             )
  end

  test "HTTP transports and embedding providers preserve raised guards" do
    transport_safety =
      Imp.OperationalSafetyError.exception(kind: :transport, reason: :provider_offline)

    assert {:error, ^transport_safety} =
             Imp.HTTP.post(
               fn _url, _headers, _body, _opts -> raise transport_safety end,
               "https://example.test",
               [],
               "{}"
             )

    assert [{:error, ^transport_safety}] =
             Imp.HTTP.stream(
               fn _url, _headers, _body, _opts -> raise transport_safety end,
               "https://example.test",
               [],
               "{}"
             )
             |> Enum.to_list()

    budget_safety = Imp.OperationalSafetyError.exception(kind: :budget, reason: :embed_limit)

    assert {:error, ^budget_safety} =
             Imp.Embeddings.embed(
               fn _texts, _opts -> raise budget_safety end,
               ["query"]
             )
  end

  test "tool policies preserve raised guards while ordinary crashes stay normalized" do
    safety = Imp.OperationalSafetyError.exception(kind: :route, reason: :denied_provider)

    assert {:error, ^safety} =
             Imp.ToolPolicy.authorize(fn _name, _input -> raise safety end, :lookup, %{})

    assert {:error,
            {:tool_policy_error, :lookup, %RuntimeError{message: "ordinary policy crash"}}} =
             Imp.ToolPolicy.authorize(
               fn _name, _input -> raise "ordinary policy crash" end,
               :lookup,
               %{}
             )
  end
end

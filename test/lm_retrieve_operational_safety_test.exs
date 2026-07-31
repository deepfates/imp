defmodule Imp.LMRetrieveOperationalSafetyTest do
  use ExUnit.Case, async: true

  test "raised LM guards remain typed errors while ordinary crashes stay normalized" do
    safety = Imp.OperationalSafetyError.exception(kind: :budget, reason: :task_limit)

    assert {:error, ^safety} =
             Imp.LM.generate(fn _messages, _opts -> raise safety end, [], [])

    assert {:error, {:lm_failed, :anonymous_lm, "ordinary LM crash"}} =
             Imp.LM.generate(fn _messages, _opts -> raise "ordinary LM crash" end, [], [])
  end

  test "raised retriever guards remain typed errors while ordinary crashes stay normalized" do
    safety = Imp.OperationalSafetyError.exception(kind: :transport, reason: :offline)

    assert {:error, ^safety} =
             Imp.Retrieve.retrieve(fn _query, _opts -> raise safety end, "query")

    assert {:error, {:retriever_failed, :anonymous_retriever, "ordinary retrieval crash"}} =
             Imp.Retrieve.retrieve(
               fn _query, _opts -> raise "ordinary retrieval crash" end,
               "query"
             )
  end
end

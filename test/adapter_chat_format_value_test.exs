defmodule Imp.Adapter.ChatFormatValueTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.Chat

  test "a structured value renders complete, as DSPy's json.dumps does" do
    value = %{"documents" => Enum.map(1..200, &%{"id" => &1, "title" => "document #{&1}"})}
    rendered = Chat.format_value(value)
    assert String.starts_with?(rendered, ~s({"documents": [{"id": 1, "title": "document 1"}, ))
    assert rendered =~ ~s({"id": 200, "title": "document 200"})
    refute rendered =~ "..."

    # Remove the list/map clause of format_value: inspect's default limit cuts this at fifty elements.
    assert Jason.decode!(rendered) == value
  end

  test "the rendering is Python's default json.dumps, not Elixir's inspect" do
    assert Chat.format_value(%{"a" => [1, 2.5, nil, true, "x"]}) ==
             ~s({"a": [1, 2.5, null, true, "x"]})

    assert Chat.format_value([%{b: :atom}]) == ~s([{"b": "atom"}])
    assert Chat.format_value(%{"é" => "ü"}) == ~s({"é": "ü"})
    assert Chat.format_value(%{"n" => 1.0e-7}) == ~s({"n": 1e-07})
  end

  test "a value JSON cannot carry renders complete rather than cut" do
    tuples = Enum.map(1..100, &{:pair, &1})
    rendered = Chat.format_value(tuples)
    assert rendered =~ "pair: 100"
    refute rendered =~ "..."
    assert Chat.format_tool_result({:error, :nope}) == "Error: nope"
  end

  # A model reads the tool result. A failed submit told it `{:missing_output_fields,
  # [:answer]}`, which is a term, not an instruction it can act on.
  test "a failed submit says in words what the model has to do differently" do
    assert Chat.format_tool_result({:error, {:missing_output_fields, [:answer, :note]}}) ==
             "Error: submit is missing: answer, note"

    assert Chat.format_tool_result({:error, {:missing_output_fields, ["answer"]}}) ==
             "Error: submit is missing: answer"

    assert Chat.format_tool_result({:error, {:invalid_submit_outputs, :answer_is_not_a_number}}) ==
             "Error: submit outputs were not accepted: answer is not a number"

    assert Chat.format_tool_result({:error, {:invalid_submit_arguments, ["answer"]}}) ==
             "Error: submit needs a map of outputs"

    assert Chat.format_tool_result({:error, {:invalid_submit_arguments, nil}}) ==
             "Error: submit needs a map of outputs"
  end

  test "a map reason renders its reason, and its limit, as a sentence" do
    assert Chat.format_tool_result({:error, %{reason: :context_window_exceeded}}) ==
             "Error: context window exceeded"

    assert Chat.format_tool_result({:error, %{reason: :too_many_results, limit: 20}}) ==
             "Error: too many results (limit 20)"

    assert Chat.format_tool_result({:error, %{"reason" => "the file was not found"}}) ==
             "Error: the file was not found"

    assert Chat.format_tool_result({:error, %{"reason" => "too long", "limit" => 4}}) ==
             "Error: too long (limit 4)"
  end

  test "a map with no reason key still falls back to a term" do
    assert Chat.format_tool_result({:error, %{status: 500}}) == "Error: %{status: 500}"
  end

  test "the existing prose clauses are unchanged" do
    assert Chat.format_tool_result({:error, {:tool_error, :read, "no such file"}}) ==
             "Error: read failed: no such file"

    assert Chat.format_tool_result({:error, {:tool_authorization_denied, :post, :client_denied}}) ==
             "Error: post was not allowed; the person declined it."
  end
end

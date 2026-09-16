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
end

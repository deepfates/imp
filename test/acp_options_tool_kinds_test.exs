defmodule Imp.ACP.OptionsToolKindsTest do
  use ExUnit.Case, async: true

  defp options(extra) do
    Imp.ACP.Options.new(
      [program_factory: fn _session -> {:ok, Imp.predict("q -> a"), fn -> :ok end} end] ++ extra
    )
  end

  test "defaults to no declared kinds" do
    assert options([]).tool_kinds == %{}
  end

  test "normalizes names and kinds to strings" do
    assert options(tool_kinds: %{"get_timeline" => "read", post: :execute}).tool_kinds ==
             %{"post" => "execute", "get_timeline" => "read"}
  end

  test "rejects kinds that are not ACP tool kinds" do
    assert_raise ArgumentError, ~r/must be ACP tool kinds/, fn ->
      options(tool_kinds: %{post: :mutate})
    end
  end

  test "rejects a non-map" do
    assert_raise ArgumentError, ~r/must be a map/, fn -> options(tool_kinds: [post: :execute]) end
  end

  test "every option the session reads is routed to the adapter, not the transport" do
    option_keys = %Imp.ACP.Options{} |> Map.keys() |> List.delete(:__struct__)
    assert option_keys -- Imp.ACP.adapter_keys() == []
  end
end

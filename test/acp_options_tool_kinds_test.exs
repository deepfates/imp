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

  # A misspelled key used to reach ExMCP, which passes what it does not know to
  # the transport, so `permision_policy: :unrestricted` started an agent that
  # asked the client after all, and a misspelled `:session_store` kept nothing.
  test "start_link, run and Local refuse an option they do not know before starting anything" do
    factory = fn _session -> {:ok, Imp.predict("q -> a")} end

    for typo <- [[permision_policy: :unrestricted], [sesion_store: "/tmp/x"], [capabilities: %{}]] do
      opts = [program_factory: factory, transport: :memory] ++ typo
      assert_raise ArgumentError, ~r/unknown options/, fn -> Imp.ACP.start_link(opts) end
      assert_raise ArgumentError, ~r/unknown options/, fn -> Imp.ACP.run(opts) end

      assert_raise ArgumentError, ~r/unknown options/, fn ->
        Imp.ACP.Local.start_link(
          socket_path: "/tmp/imp-acp-options-never-created.sock",
          agent_options: [program_factory: factory] ++ typo
        )
      end
    end

    refute File.exists?("/tmp/imp-acp-options-never-created.sock")
  end

  test "Local sets each connection's transport itself" do
    assert_raise ArgumentError, ~r/unknown options \[:transport_mod\]/, fn ->
      Imp.ACP.Local.start_link(
        socket_path: "/tmp/imp-acp-options-never-created.sock",
        agent_options: [program_factory: fn _ -> nil end, transport_mod: Imp.ACP.Local.Transport]
      )
    end
  end

  test "an invalid value is refused by name" do
    assert_raise ArgumentError, ~r/:permission_policy/, fn ->
      Imp.ACP.start_link(program_factory: fn _ -> nil end, permission_policy: :sometimes)
    end
  end
end

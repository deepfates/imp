defmodule Imp.MCPContentModeTest do
  use ExUnit.Case
  alias Imp.Adapter.Types.Image

  @moduletag capture_log: true

  @pixels "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGP4z8DAAMH//zOA4X8ASskI+C0xXWQAAAAASUVORK5CYII="

  # A server that writes its text for a model and its structured content for
  # programs, as the MCP specification's own examples do.
  defmodule Server do
    use ExMCP.Server.Handler
    def init(_), do: {:ok, %{}}

    def handle_list_tools(_, state),
      do:
        {:ok,
         [
           %{
             "name" => "list_users",
             "inputSchema" => %{"type" => "object", "properties" => %{}}
           }
         ], nil, state}

    def handle_call_tool("list_users", _, state),
      do: {:ok, Imp.MCPContentModeTest.envelope(), state}
  end

  def envelope do
    %{
      "content" => [%{"type" => "text", "text" => "Found 2 users: Alice and Bob."}],
      "structuredContent" => %{"users" => [%{"id" => "1"}, %{"id" => "2"}]}
    }
  end

  test "the model reads the content a server wrote for it; the host reads the structured result" do
    {:ok, _} = Application.ensure_all_started(:ex_mcp)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    ref = {__MODULE__, port}

    {:ok, _} =
      Plug.Cowboy.http(
        ExMCP.HttpPlug,
        [
          handler: Server,
          server_info: %{name: "users", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any
        ],
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    imported = Imp.Test.MCPConnect.http!("http://127.0.0.1:#{port}", result_mode: :content)
    on_exit(fn -> imported.cleanup.() end)
    [tool] = imported.tools

    assert Imp.Tool.call(tool, %{}) == "Found 2 users: Alice and Bob."

    assert Imp.MCP.call(tool, %{}, result_mode: :structured) ==
             %{"users" => [%{"id" => "1"}, %{"id" => "2"}]}

    # The tool's own mode is unchanged by a call in another.
    assert Imp.Tool.call(tool, %{}) == "Found 2 users: Alice and Bob."
    refute inspect(imported.provenance) =~ "#Function"
  end

  test ":content keeps images as :multimodal does and falls back to structured content only without content" do
    image = %{"type" => "image", "data" => @pixels, "mimeType" => "image/png"}

    assert ["receipt", %Image{data: @pixels}] =
             Imp.MCP.tool_result(
               %{"content" => [%{"type" => "text", "text" => "receipt"}, image]},
               :content
             )

    assert Imp.MCP.tool_result(envelope(), :content) == "Found 2 users: Alice and Bob."
    assert Imp.MCP.tool_result(envelope(), :multimodal) == envelope()["structuredContent"]
    assert Imp.MCP.tool_result(%{"structuredContent" => %{"n" => 1}}, :content) == %{"n" => 1}

    # Text that only repeats the structured content as JSON adds nothing to it:
    # the structured value is returned, as :multimodal returns it.
    repeated = %{
      "content" => [%{"type" => "text", "text" => ~s({"n": 1})}],
      "structuredContent" => %{"n" => 1}
    }

    assert Imp.MCP.tool_result(repeated, :content) == %{"n" => 1}

    error = Map.put(envelope(), "isError", true)
    assert Imp.MCP.tool_result(error, :content) == {:error, {:mcp_tool_error, error}}
  end
end

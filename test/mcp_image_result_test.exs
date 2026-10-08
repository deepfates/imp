defmodule Imp.MCPImageResultTest do
  use ExUnit.Case
  alias Imp.Adapter.{Chat, Types.Image}

  @moduletag capture_log: true

  # Transport evidence only: the local provider never interprets these bytes.
  @pixels "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGP4z8DAAMH//zOA4X8ASskI+C0xXWQAAAAASUVORK5CYII="
  @image %{"type" => "image", "data" => @pixels, "mimeType" => "image/png"}

  defmodule Server do
    use ExMCP.Server.Handler
    def init(_), do: {:ok, %{}}

    def handle_list_tools(_, state),
      do: {:ok, [%{"name" => "look", "inputSchema" => %{"type" => "object"}}], nil, state}

    def handle_call_tool("look", _, state), do: {:ok, Imp.MCPImageResultTest.envelope(), state}
  end

  def envelope do
    %{
      "structuredContent" => %{"receipt" => "r280"},
      "content" => [%{"type" => "text", "text" => "receipt r280"}, @image]
    }
  end

  test "opt-in conversion retains text, structured data and typed pixels without changing existing modes" do
    assert ["receipt r280", %Image{data: @pixels, mime_type: "image/png"}] =
             Imp.MCP.tool_result(envelope(), :multimodal)

    assert Imp.MCP.tool_result(envelope(), :text) == "receipt r280"
    assert Imp.MCP.tool_result(envelope(), :structured) == %{"receipt" => "r280"}

    for value <- [nil, false, 0, "", [], %{}] do
      result = %{
        "structuredContent" => value,
        "content" => [%{"type" => "text", "text" => "plain"}]
      }

      assert Imp.MCP.tool_result(result, :multimodal) == value
    end

    error = Map.put(envelope(), "isError", true)

    for mode <- [:text, :structured, :multimodal],
        do: assert(Imp.MCP.tool_result(error, mode) == {:error, {:mcp_tool_error, error}})

    assert [%Image{data: @pixels}] =
             Imp.MCP.tool_result(
               %{content: [%{type: :image, data: @pixels, mime_type: "image/png"}]},
               :multimodal
             )
  end

  test "model renderer preserves explicit typed lists while UI renderer remains text" do
    content = ["attachment", %Image{data: @pixels, mime_type: "image/png"}]
    assert Chat.format_tool_content(content) == content
    assert is_binary(Chat.format_tool_result(content))

    assert Chat.format_tool_content(%{"content" => [@image]}) ==
             Chat.format_tool_result(%{"content" => [@image]})

    assert Chat.format_tool_content(["one", "two"]) == Chat.format_tool_result(["one", "two"])
  end

  test "malformed image data fails before a model request" do
    for image <- [Map.delete(@image, "mimeType"), Map.put(@image, "data", "invalid!")] do
      assert_raise ArgumentError, fn ->
        Imp.MCP.tool_result(%{"content" => [image]}, :multimodal)
      end
    end
  end

  test "MCP HTTP import, parallel ReAct results and restored history carry pixels onto the provider wire" do
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
          server_info: %{name: "images", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any
        ],
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    imported = Imp.Test.MCPConnect.http!("http://127.0.0.1:#{port}", result_mode: :multimodal)
    on_exit(fn -> imported.cleanup.() end)
    {:ok, bodies} = Agent.start_link(fn -> [] end)

    url =
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        n = Agent.get_and_update(bodies, &{length(&1), &1 ++ [body]})
        {200, response(body["model"], n)}
      end)

    lm =
      Imp.req_llm("openai:gpt-4-turbo", api_key: "fixture", base_url: url <> "/v1", cache: false)

    program = Imp.react("intent -> answer", imported.tools, lm: lm)
    assert {:ok, prediction} = Imp.call(program, %{intent: "Read attachments"})
    assert Imp.get(prediction, :answer) == "Fixture response"
    [_, observed] = Agent.get(bodies, & &1)
    assert_image_exchange(observed)

    history =
      prediction.metadata.history
      |> Imp.History.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.History.load!()

    assert {:ok, _} = Imp.call(program, %{intent: "Recall attachments", history: history})
    assert_image_exchange(List.last(Agent.get(bodies, & &1)))
  end

  test "image-only and written tool history retain images and the corresponding result" do
    result = Imp.MCP.tool_result(%{"content" => [@image]}, :multimodal)

    turn = %{
      intent: "look",
      next_thought: "",
      tool_calls: [
        %{id: "c1", name: "look", arguments: %{}},
        %{id: "c2", name: "empty", arguments: %{}}
      ],
      tool_call_results: [
        %{id: "c1", name: "look", result: result},
        %{id: "c2", name: "empty", result: ""}
      ]
    }

    history = Imp.history([turn])
    signature = Imp.signature("intent, history -> answer")
    messages = Chat.format(signature, %{intent: "again", history: history}, [])
    assert %{content: text} = Enum.find(messages, &(&1.role == :tool))
    assert text =~ "c1"
    assert [%{content: ^text}, %{content: ""}] = Enum.filter(messages, &(&1.role == :tool))
    assert [%Image{data: @pixels}] = images(messages)

    written = Imp.signature("intent, history -> answer, tool_calls: array")
    written = %{written | metadata: Map.put(written.metadata, :tool_calls_field, :tool_calls)}
    messages = Chat.format(written, %{intent: "again", history: history}, [])
    refute Enum.any?(messages, &(&1.role == :tool))
    assert [%Image{data: @pixels}] = images(messages)
  end

  defp images(messages),
    do:
      Enum.flat_map(messages, fn %{content: content} ->
        Enum.filter(List.wrap(content), &match?(%Image{}, &1))
      end)

  defp assert_image_exchange(body) do
    [_call, first, second, attachment1, attachment2 | _] =
      Enum.drop_while(body["messages"], &is_nil(&1["tool_calls"]))

    assert first["role"] == "tool"
    assert second["role"] == "tool"
    assert [first["tool_call_id"], second["tool_call_id"]] == ["c1", "c2"]

    for {attachment, id} <- [{attachment1, "c1"}, {attachment2, "c2"}] do
      assert attachment["role"] == "user"
      assert hd(attachment["content"])["text"] =~ id

      assert %{"image_url" => %{"url" => "data:image/png;base64," <> @pixels}} =
               List.last(attachment["content"])
    end

    assert first["content"] =~ "receipt r280"
    refute first["content"] =~ @pixels
  end

  defp response(model, n) do
    message =
      if n == 0 do
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" =>
            Enum.map(
              ["c1", "c2"],
              &%{
                "id" => &1,
                "type" => "function",
                "function" => %{"name" => "look", "arguments" => "{}"}
              }
            )
        }
      else
        %{"role" => "assistant", "content" => "Fixture response"}
      end

    %{
      "id" => "fixture",
      "model" => model,
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => if(n == 0, do: "tool_calls", else: "stop")
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end
end

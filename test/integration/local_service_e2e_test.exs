defmodule LocalServiceE2ETest do
  use ExUnit.Case

  @moduletag :integration

  test "save/load/rebind executes a saved program against a local OpenAI-compatible server" do
    Process.put(:previous_dsex_test_mode, System.get_env("DSEX_TEST_MODE"))
    System.put_env("DSEX_TEST_MODE", "live")

    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.path == "/chat/completions"

        payload = Jason.decode!(request.body)
        assert payload["model"] == "local-test"

        {200,
         %{
           choices: [
             %{message: %{content: Jason.encode!(%{answer: "local-ok"})}}
           ]
         }}
      end)

    lm = DSEx.Clients.Local.new("local-test", base_url: base_url, test_mode: :live)
    program = DSEx.predict("question -> answer", lm: lm, adapter: DSEx.Adapter.JSON)

    path =
      Path.join(System.tmp_dir!(), "dsex-integration-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(program, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    assert {:ok, prediction} = DSEx.call(loaded, %{question: "ping"})
    assert DSEx.Prediction.get(prediction, :answer) == "local-ok"
  after
    case Process.get(:previous_dsex_test_mode) do
      nil -> System.delete_env("DSEX_TEST_MODE")
      mode -> System.put_env("DSEX_TEST_MODE", mode)
    end

    Process.delete(:previous_dsex_test_mode)
  end

  test "HTTP retriever performs a real local HTTP request and maps documents" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.path == "/retrieve"
        assert %{"query" => "beam", "k" => 2} = Jason.decode!(request.body)

        {200,
         %{
           documents: [
             %{text: "BEAM document", score: 0.9, source: "local"}
           ]
         }}
      end)

    retriever = DSEx.Retrievers.HTTP.new(base_url <> "/retrieve")

    assert {:ok, [%{text: "BEAM document", score: 0.9, metadata: %{"source" => "local"}}]} =
             DSEx.Retrieve.retrieve(retriever, "beam", k: 2)
  end

  test "HTTP MCP client discovers and calls a local JSON-RPC tool server" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        decoded = Jason.decode!(request.body)

        case decoded["method"] do
          "initialize" ->
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: %{serverInfo: %{name: "local"}}}}

          "notifications/initialized" ->
            {200, %{jsonrpc: "2.0", result: %{}}}

          "tools/list" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{
                 tools: [
                   %{
                     name: "lookup",
                     description: "Lookup a local fact.",
                     input_schema: %{
                       type: "object",
                       properties: %{key: %{type: "string"}},
                       required: ["key"]
                     }
                   }
                 ]
               }
             }}

          "tools/call" ->
            assert get_in(decoded, ["params", "name"]) == "lookup"
            assert get_in(decoded, ["params", "arguments", "key"]) == "capital"
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: "Paris"}}
        end
      end)

    [tool] = base_url |> DSEx.MCP.HTTPClient.new() |> DSEx.MCP.import_tools()

    assert tool.name == :lookup
    assert DSEx.Tool.call(tool, %{"key" => "capital"}) == "Paris"
  end

  test "stdio MCP client discovers and calls a trusted local executable" do
    script = Path.join(System.tmp_dir!(), "dsex-mcp-#{System.unique_integer([:positive])}.exs")

    File.write!(script, """
    Enum.each(IO.stream(:stdio, :line), fn line ->
      request = Jason.decode!(line)
      response =
        case request["method"] do
          "initialize" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}}
          "tools/list" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"tools" => [%{"name" => "echo", "description" => "Echo input", "input_schema" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}}]}}
          "tools/call" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => request["params"]["arguments"]["text"]}
          _ ->
            nil
        end

      if response, do: IO.puts(Jason.encode!(response))
    end)
    """)

    on_exit(fn -> File.rm(script) end)

    [tool] =
      System.find_executable("mix")
      |> DSEx.MCP.StdioClient.new(args: ["run", script])
      |> DSEx.MCP.import_tools()

    assert tool.name == :echo
    assert DSEx.Tool.call(tool, %{"text" => "hello"}) == "hello"
  end
end

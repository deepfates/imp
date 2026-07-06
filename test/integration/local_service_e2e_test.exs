defmodule LocalServiceE2ETest do
  use ExUnit.Case

  @moduletag :integration

  defmodule LocalHTTP do
    def start(handler) when is_function(handler, 1) do
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, {_ip, port}} = :inet.sockname(listen)
      owner = self()

      pid =
        spawn_link(fn ->
          send(owner, {:local_http_ready, self()})
          accept_loop(listen, handler)
        end)

      assert_receive {:local_http_ready, ^pid}

      on_exit(fn ->
        Process.exit(pid, :shutdown)
        :gen_tcp.close(listen)
      end)

      "http://127.0.0.1:#{port}"
    end

    defp accept_loop(listen, handler) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          serve(socket, handler)
          accept_loop(listen, handler)

        {:error, :closed} ->
          :ok
      end
    end

    defp serve(socket, handler) do
      request = read_request(socket, "")
      response = handler.(request)
      :ok = :gen_tcp.send(socket, encode_response(response))
      :gen_tcp.close(socket)
    end

    defp read_request(socket, acc) do
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      acc = acc <> chunk

      if complete?(acc) do
        parse_request(acc)
      else
        read_request(socket, acc)
      end
    end

    defp complete?(raw) do
      case String.split(raw, "\r\n\r\n", parts: 2) do
        [_headers, body] ->
          content_length(raw) <= byte_size(body)

        _ ->
          false
      end
    end

    defp parse_request(raw) do
      [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
      [request_line | header_lines] = String.split(head, "\r\n")
      [method, path, _version] = String.split(request_line, " ", parts: 3)

      headers =
        Map.new(header_lines, fn line ->
          [key, value] = String.split(line, ":", parts: 2)
          {String.downcase(key), String.trim(value)}
        end)

      body = binary_part(body, 0, content_length(raw))
      %{method: method, path: path, headers: headers, body: body}
    end

    defp content_length(raw) do
      raw
      |> String.split("\r\n")
      |> Enum.find_value(0, fn line ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            if String.downcase(key) == "content-length",
              do: value |> String.trim() |> String.to_integer()

          _ ->
            nil
        end
      end)
    end

    defp encode_response({status, body}) when is_integer(status) do
      body = Jason.encode!(body)

      [
        "HTTP/1.1 #{status} OK\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n\r\n",
        body
      ]
    end
  end

  test "save/load/rebind executes a saved program against a local OpenAI-compatible server" do
    Process.put(:previous_dsex_test_mode, System.get_env("DSEX_TEST_MODE"))
    System.put_env("DSEX_TEST_MODE", "live")

    base_url =
      LocalHTTP.start(fn request ->
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
      LocalHTTP.start(fn request ->
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
      LocalHTTP.start(fn request ->
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

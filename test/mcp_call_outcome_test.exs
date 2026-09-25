defmodule Imp.MCPCallOutcomeTest do
  # A tool call's outcome is one of five: the tool answered (`:result`), the
  # server or Imp declined before anything ran (`:refused`), the server refused
  # the credential (`:auth_refused`), the request never left (`:not_sent`), or
  # it left and no trustworthy answer came back (`:unknown`). Each case here
  # drives the real ExMCP client against a real server and reads the outcome
  # Imp decided, never the shape of the term.
  use ExUnit.Case, async: false

  alias Imp.MCP.CallFailure

  @moduletag capture_log: true

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_mcp)
    :ok
  end

  defmodule Handler do
    use ExMCP.Server.Handler
    def init(_), do: {:ok, %{}}

    @tools ~w(answer tool_error declared_unknown crash slow invalid_params no_method)

    def handle_list_tools(_cursor, state) do
      tools =
        for name <- @tools,
            do: %{"name" => name, "description" => name, "inputSchema" => %{"type" => "object"}}

      {:ok, tools, nil, state}
    end

    def handle_call_tool(name, _arguments, state) do
      if probe = Process.whereis(:mcp_outcome_probe), do: send(probe, {:ran, name})
      call(name, state)
    end

    defp call("answer", state), do: {:ok, %{"content" => [text("done")]}, state}
    defp call("tool_error", state), do: {:error, "the tool said no", state}

    # Kite's error result for a write that may have been applied.
    defp call("declared_unknown", state) do
      {:ok,
       %{
         "content" => [text("error: write outcome unknown; the action may have completed.")],
         "isError" => true,
         "structuredContent" => %{"code" => "write_outcome_unknown", "outcome" => "unknown"}
       }, state}
    end

    defp call("crash", _state), do: raise("the handler crashed")

    defp call("slow", state) do
      Process.sleep(1_000)
      {:ok, %{"content" => [text("late")]}, state}
    end

    defp call("invalid_params", state),
      do: {:error, ExMCP.Error.protocol_error(-32_602, "Unknown tool: missing"), state}

    defp call("no_method", state),
      do: {:error, ExMCP.Error.protocol_error(-32_601, "Method not found"), state}

    defp text(value), do: %{"type" => "text", "text" => value}
  end

  # Stands in front of the MCP endpoint so a test can make the HTTP layer
  # answer with a status, or hold one request before the server sees it.
  defmodule Gate do
    @behaviour Plug
    def init(opts), do: ExMCP.HttpPlug.init(opts)

    def call(conn, opts) do
      key = {__MODULE__, conn.port}

      case :persistent_term.get(key, :open) do
        :open ->
          ExMCP.HttpPlug.call(conn, opts)

        {:hold_once, ms} ->
          :persistent_term.put(key, :open)
          Process.sleep(ms)
          ExMCP.HttpPlug.call(conn, opts)

        status when is_integer(status) ->
          conn |> Plug.Conn.send_resp(status, "gate") |> Plug.Conn.halt()
      end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp http_server(server_opts \\ []) do
    port = free_port()
    ref = {__MODULE__, port}

    {:ok, _} =
      Plug.Cowboy.http(
        Gate,
        [
          handler: Handler,
          server_info: %{name: "outcome", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any
        ] ++ server_opts,
        port: port,
        ref: ref
      )

    stop = fn ->
      try do
        Plug.Cowboy.shutdown(ref)
      catch
        _kind, _reason -> :ok
      end
    end

    on_exit(fn ->
      :persistent_term.erase({Gate, port})
      stop.()
    end)

    %{port: port, stop: stop, url: "http://127.0.0.1:#{port}/mcp"}
  end

  defp gate(server, setting), do: :persistent_term.put({Gate, server.port}, setting)

  defp tools(descriptor, opts) do
    {:ok, imported} = Imp.MCP.connect([descriptor], [trusted_servers: [descriptor]] ++ opts)
    on_exit(fn -> imported.cleanup.() end)
    {imported, Map.new(imported.tools, &{to_string(&1.name), &1})}
  end

  defp http_tools(server, opts \\ []) do
    tools(%{"name" => "outcome", "type" => "http", "url" => server.url}, opts)
  end

  defp call(tools, name), do: Imp.Tool.call(Map.fetch!(tools, name), %{})

  describe "the tool answered" do
    test "a successful call is a result" do
      {_imported, tools} = http_tools(http_server())
      assert "done" = result = call(tools, "answer")
      assert Imp.Tool.outcome(result) == :result
    end

    test "an MCP error result is the tool's own answer, kept whole" do
      {_imported, tools} = http_tools(http_server())
      assert {:error, {:mcp_tool_error, envelope}} = result = call(tools, "tool_error")
      assert envelope["isError"] == true
      assert Imp.Tool.outcome(result) == :result
    end

    test "an MCP error result that declares its outcome is read as it declares" do
      {_imported, tools} = http_tools(http_server())

      assert {:error, {:mcp_tool_error, envelope}} = result = call(tools, "declared_unknown")
      assert envelope["structuredContent"]["outcome"] == "unknown"
      assert Imp.Tool.outcome(result) == :unknown

      for {declared, outcome} <- [
            {"refused", :refused},
            {"auth_refused", :auth_refused},
            {"unknown", :unknown},
            {"not_sent", :result},
            {"partial", :result}
          ] do
        envelope = %{isError: true, structuredContent: %{outcome: declared}}
        assert Imp.Tool.outcome({:error, {:mcp_tool_error, envelope}}) == outcome, declared
      end

      # Structured content is the tool's data; only an error result's is read.
      assert Imp.Tool.outcome(%{"structuredContent" => %{"outcome" => "unknown"}}) == :result
    end
  end

  describe "declined before anything ran" do
    test "JSON-RPC method not found is a refusal" do
      {_imported, tools} = http_tools(http_server())

      assert {:error,
              %CallFailure{outcome: :refused, server: "outcome", tool: "no_method"} = failure} =
               result = call(tools, "no_method")

      assert %{"code" => -32_601} = failure.reason
      assert Imp.Tool.outcome(result) == :refused
    end

    test "an HTTP 403 on the call is a refusal, and a 401 refuses the credential" do
      server = http_server()
      {_imported, tools} = http_tools(server)

      gate(server, 403)
      assert {:error, %CallFailure{outcome: :refused}} = call(tools, "answer")

      gate(server, 401)
      assert {:error, %CallFailure{outcome: :auth_refused} = failure} = call(tools, "answer")
      assert Imp.MCP.failure_text(failure) =~ "refused the credential"
    end

    # A tool can return any term, including one shaped like Imp's own
    # refusals, so a value alone never reads as a refusal: the loop that
    # refused the call records it.
    test "a term shaped like a refusal that a tool returned is the tool's answer" do
      for reason <- [
            {:unknown_tool, "frobnicate"},
            {:malformed_tool_call, %{}},
            {:missing_required, ["uri"]},
            {:schema_validation, [%{field: "limit", message: "must be <= 100"}]},
            {:tool_authorization_denied, :post, :client_denied},
            {:tool_denied, :post},
            {:rlm_tool_error, {:tool_denied, :post}}
          ] do
        assert Imp.Tool.outcome({:error, reason}) == :result, inspect(reason)
      end
    end
  end

  describe "the request never left" do
    test "a server that refuses the connection was not sent anything" do
      server = http_server()
      {_imported, tools} = http_tools(server)
      server.stop.()

      assert {:error, %CallFailure{outcome: :not_sent, reason: reason}} = call(tools, "answer")
      # The durable error is ExMCP's own, not a summary of it.
      assert %{type: :transport_error, message: "Failed to send request: " <> _} = reason
    end

    test "a closed import has no client to send through" do
      {imported, tools} = http_tools(http_server())
      imported.cleanup.()

      assert {:error, %CallFailure{outcome: :not_sent, reason: :not_connected}} =
               call(tools, "answer")
    end

    @tag :tmp_dir
    test "a stdio server that has exited leaves the client unconnected", %{tmp_dir: dir} do
      {_imported, tools} = stdio_tools(dir)

      assert {:error, %CallFailure{outcome: :unknown}} = call(tools, "exit")

      assert {:error, %CallFailure{outcome: :not_sent, reason: :not_connected}} =
               call(tools, "answer")
    end
  end

  describe "sent, with no trustworthy answer" do
    # ExMCP's server sends a tool handler's returned ProtocolError as the
    # JSON-RPC error, after the handler ran. So the code alone does not say the
    # tool did not run.
    test "JSON-RPC invalid params is unknown: the handler that sent it had run" do
      Process.register(self(), :mcp_outcome_probe)
      {_imported, tools} = http_tools(http_server())

      assert {:error, %CallFailure{outcome: :unknown, reason: %{"code" => -32_602}}} =
               call(tools, "invalid_params")

      assert_received {:ran, "invalid_params"}
    end

    test "a handler that crashes after it started is unknown, not refused" do
      {_imported, tools} = http_tools(http_server())

      assert {:error, %CallFailure{outcome: :unknown, reason: reason}} = call(tools, "crash")
      assert %{"code" => -32_603, "data" => %{"type" => "handler_crash"}} = reason
    end

    test "a handler the server stopped waiting for is unknown, and it keeps running" do
      Process.register(self(), :mcp_outcome_probe)
      {_imported, tools} = http_tools(http_server(handler_call_timeout: 100))

      assert {:error, %CallFailure{outcome: :unknown, reason: reason}} = call(tools, "slow")
      assert %{"code" => -32_603, "data" => %{"type" => "handler_timeout"}} = reason
      assert_received {:ran, "slow"}
    end

    test "a caller timeout is unknown: the server still runs the call" do
      Process.register(self(), :mcp_outcome_probe)
      {_imported, tools} = http_tools(http_server(), timeout: 300)

      assert {:error, %CallFailure{outcome: :unknown, reason: :timeout}} = call(tools, "slow")
      assert_receive {:ran, "slow"}, 2_000
    end

    # ExMCP's client makes a plain HTTP POST inside its own process, so a second
    # call on the same client waits for the first. A call that times out while
    # waiting has not left yet, but its request is still in the client's queue
    # and is sent when the first finishes. So a timeout is never "not sent".
    # Imp does not put one HTTP call behind another on a client (each call
    # borrows a client of its own, and one whose call timed out is replaced),
    # so this is shown on ExMCP's client directly, borrowed from the import.
    # The wait is over five seconds because ExMCP's pre-flight check before
    # each call waits up to five seconds for the busy client, outside the
    # call's own timeout.
    @tag timeout: 30_000
    test "a call that timed out waiting behind another on one client is sent afterwards" do
      Process.register(self(), :mcp_outcome_probe)
      server = http_server()
      {imported, _tools} = http_tools(server, timeout: 300)
      gate(server, {:hold_once, 6_000})

      {:env, env} = Function.info(imported.cleanup, :env)
      {:ok, client} = Imp.MCP.Clients.checkout(Enum.find(env, &is_pid/1), 0, 1_000)
      options = [format: :map, retry_policy: false, http_stream_retry: :safe_only]

      spawn(fn -> ExMCP.Client.call_tool(client, "slow", %{}, [timeout: 10_000] ++ options) end)
      Process.sleep(100)

      assert {:error, :timeout = reason} =
               ExMCP.Client.call_tool(client, "answer", %{}, [timeout: 300] ++ options)

      assert %CallFailure{outcome: :unknown} = CallFailure.returned("outcome", "answer", reason)
      refute_received {:ran, "answer"}
      assert_receive {:ran, "answer"}, 5_000
    end

    test "a server error status after the request arrived is unknown" do
      server = http_server()
      {_imported, tools} = http_tools(server)

      for status <- [500, 502, 503, 504] do
        gate(server, status)
        assert {:error, %CallFailure{outcome: :unknown}} = call(tools, "answer")
      end
    end

    @tag :tmp_dir
    test "a stdio server that exits during the call is unknown", %{tmp_dir: dir} do
      {_imported, tools} = stdio_tools(dir)

      assert {:error,
              %CallFailure{outcome: :unknown, reason: %ExMCP.Error{code: :connection_error}}} =
               call(tools, "exit")
    end

    # The client waits five seconds for `Imp.MCP.OwnedStdio` to take a write.
    # A transport that is busy past that (here held by `:sys.suspend/1`, in
    # life a slow erlexec manager or a group being stopped) still has the
    # request in its mailbox and writes it when it gets to it.
    @tag :tmp_dir
    @tag timeout: 30_000
    test "a stdio write the client stopped waiting for is unknown, and it arrives", %{
      tmp_dir: dir
    } do
      # Only this import's transport: another test's may still be closing.
      before = owned_stdio_processes()
      {_imported, tools} = stdio_tools(dir)
      [transport] = owned_stdio_processes() -- before
      :sys.suspend(transport)

      failure =
        try do
          call(tools, "answer")
        after
          :sys.resume(transport)
        end

      assert {:error, %CallFailure{outcome: :unknown} = failure} = failure
      assert Imp.MCP.failure_text(failure) =~ "may have been carried out"
      assert eventually(fn -> File.read(Path.join(dir, "ran")) == {:ok, "answer\n"} end)
    end

    test "a local tool that exits or raises may have acted" do
      assert Imp.Tool.outcome({:error, {:tool_error, :lookup, {:exit, :killed}}}) == :unknown
      assert Imp.Tool.outcome({:error, {:tool_error, :lookup, "boom"}}) == :unknown
    end

    test "an RLM budget that stopped or refused a tool call does not say whether it ran" do
      for reason <- [
            :rlm_time_budget_exceeded,
            {:rlm_effect_exit, :killed},
            {:rlm_cancelled, :owner_stopped},
            {:rlm_max_llm_calls, 4}
          ] do
        assert Imp.Tool.outcome({:error, {:rlm_tool_error, reason}}) == :unknown, inspect(reason)
      end
    end
  end

  # Shapes ExMCP produces on paths a live server cannot be made to take on
  # demand here: the streaming POST (its raw transport reason), a response
  # stream that broke after delivery, a client that exits mid-call, and a
  # cancelled request. Each is built exactly as ExMCP builds it.
  describe "the shapes ExMCP reports on its other paths" do
    test "each is classified by what it says about delivery" do
      cases = [
        {{:transport_error, %Mint.TransportError{reason: :econnrefused}}, :not_sent},
        {{:transport_error, :dns_failed}, :not_sent},
        {{:transport_error, {:unauthorized, 401, "", nil}}, :auth_refused},
        {{:transport_error, {:http_error, 401, ""}}, :auth_refused},
        {{:transport_error, {:oauth_failed, :invalid_grant}}, :auth_refused},
        {transport_text({:unauthorized, 401, "", nil}), :auth_refused},
        {{:transport_error, {:http_error, 403, ""}}, :refused},
        {{:transport_error, {:http_error, 429, ""}}, :refused},
        {{:transport_error, {:http_error, 502, ""}}, :unknown},
        {{:transport_error, {:http_receive_failed, %Mint.TransportError{reason: :closed}}},
         :unknown},
        {{:transport_error, {:http_request_failed, %Mint.TransportError{reason: :closed}}},
         :unknown},
        {transport_text({:http_receive_failed, %Mint.TransportError{reason: :timeout}}),
         :unknown},
        {transport_text(%Mint.TransportError{reason: :timeout}), :not_sent},
        {transport_text(:dns_timeout), :not_sent},
        {transport_text({:json_decode_error, %Jason.DecodeError{data: ""}}), :unknown},
        {ExMCP.Error.transport_error(:http, :outcome_unknown, %{}), :unknown},
        {ExMCP.Error.connection_error("Client disconnected"), :unknown},
        {%{"code" => -32_800, "message" => "Request cancelled"}, :unknown},
        {%{"code" => -32_700, "message" => "Parse error"}, :refused},
        {%{"code" => -32_600, "message" => "Invalid Request"}, :refused},
        # ExMCP builds these itself, some after the first round of a
        # multi-round call reached the server (`ExMCP.Client` MRTR).
        {%ExMCP.Error.ProtocolError{code: -32_602, message: "MRTR round limit exceeded"},
         :unknown},
        {%ExMCP.Error.ProtocolError{code: -32_601, message: "unsupported input"}, :unknown}
      ]

      for {reason, expected} <- cases do
        assert CallFailure.returned("s", "t", reason).outcome == expected, inspect(reason)
      end

      assert CallFailure.exited("s", "t", {:noproc, {GenServer, :call, []}}).outcome ==
               :not_sent

      for exit <- [{:normal, {GenServer, :call, []}}, {:killed, {GenServer, :call, []}}, :timeout] do
        assert CallFailure.exited("s", "t", exit).outcome == :unknown, inspect(exit)
      end
    end
  end

  describe "the record" do
    test "a ReActV2 tool_result event carries the outcome" do
      exits = Imp.Tool.new(:lookup, "look something up", fn _ -> exit(:killed) end)

      lm =
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            if List.last(messages)[:role] == :tool,
              do: "gave up",
              else: %{
                next_thought: "look",
                tool_calls: [%{id: "call-1", name: "lookup", arguments: %{}}]
              }
          end
        )

      program = Imp.react_v2("question -> answer", [exits], lm: lm, max_iters: 2)
      owner = self()

      {:ok, run} =
        Imp.Run.start(program, %{question: "q"}, event_sink: &send(owner, {:event, &1}))

      assert_receive {:event, %{kind: :tool_result} = event}, 5_000
      assert event.metadata.outcome == :unknown
      assert Imp.Run.Event.to_map(event)["metadata"]["outcome"] == "unknown"
      Imp.Run.cancel(run)
    end

    # A terminal tool has run by the time `finish_on` reads its result, so
    # outputs that do not fit the signature do not make the call a refusal.
    test "a terminal tool whose finish_on outputs do not fit still ran" do
      reply = Imp.Tool.new(:reply, "reply", fn _arguments -> "sent" end)

      lm =
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            if List.last(messages)[:role] == :tool,
              do: "gave up",
              else: %{
                next_thought: "reply",
                tool_calls: [%{id: "call-1", name: "reply", arguments: %{}}]
              }
          end
        )

      program =
        Imp.react_v2("question -> answer", [reply],
          lm: lm,
          max_iters: 2,
          finish_on: %{reply: fn _arguments, _result, _inputs -> {:finish, %{}} end}
        )

      owner = self()

      {:ok, run} =
        Imp.Run.start(program, %{question: "q"}, event_sink: &send(owner, {:event, &1}))

      assert_receive {:event, %{kind: :tool_result} = event}, 5_000
      assert {:error, {:missing_output_fields, _}} = event.error
      assert event.metadata.outcome == :result
      Imp.Run.cancel(run)
    end

    # The refusal is decided where the call is refused: a policy that denies
    # with its own term refuses the call, and a tool that returns a term
    # shaped like a refusal has answered.
    test "ReActV2 records a refusal where it refused the call, not from the term" do
      echo = Imp.Tool.new(:echo, "echo", fn _ -> {:error, {:unknown_tool, "frobnicate"}} end)
      post = Imp.Tool.new(:post, "post", fn _ -> "posted" end)

      lm =
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            if List.last(messages)[:role] == :tool,
              do: "done",
              else: %{
                tool_calls: [
                  %{id: "echo-1", name: "echo", arguments: %{}},
                  %{id: "post-1", name: "post", arguments: %{}}
                ]
              }
          end
        )

      policy = fn
        :post, _args -> {:error, :not_today}
        _name, _args -> true
      end

      program =
        Imp.react_v2("question -> answer", [echo, post],
          lm: lm,
          max_iters: 2,
          tool_policy: policy
        )

      assert outcomes(program) == %{"echo-1" => :result, "post-1" => :refused}
    end

    test "RLM records a refusal where it refused the call, not from the term" do
      echo = Imp.Tool.new(:echo, "echo", fn _ -> {:error, {:unknown_tool, "frobnicate"}} end)
      post = Imp.Tool.new(:post, "post", fn _ -> "posted" end)
      {:ok, turns} = Agent.start_link(fn -> [~S|echo(%{})|, ~S|post(%{})|] end)

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            Agent.get_and_update(turns, fn
              [code | rest] -> {%{code: code}, rest}
              [] -> {%{code: ~S|submit(%{answer: "done"})|}, []}
            end)
          end
        )

      program =
        Imp.Predict.RLM.new("question -> answer",
          lm: lm,
          tools: [echo, post],
          tool_policy: fn
            :post, _args -> {:error, :not_today}
            _name, _args -> true
          end,
          max_iterations: 3
        )

      assert outcomes_by_name(program) == %{echo: :result, post: :refused}
    end

    test "an MCP call failure serializes with its outcome beside the untouched reason" do
      failure = CallFailure.returned("kite", "reply", :timeout)

      assert %{
               "outcome" => "unknown",
               "server" => "kite",
               "tool" => "reply",
               "reason" => "timeout"
             } =
               Imp.Run.Event.to_map(%Imp.Run.Event{
                 run_id: "r",
                 sequence: 0,
                 kind: :tool_result,
                 error: failure
               })["error"]
    end
  end

  defp outcomes(program),
    do: program |> tool_results() |> Map.new(&{&1.tool_call_id, &1.metadata.outcome})

  defp outcomes_by_name(program),
    do: program |> tool_results() |> Map.new(&{&1.tool_name, &1.metadata.outcome})

  defp tool_results(program) do
    {:ok, run} = Imp.Run.start(program, %{question: "q"})
    assert {:ok, _prediction} = Task.await(run.task, 10_000)
    events = Imp.Run.events(run)
    :ok = Imp.Run.stop(run)
    Enum.filter(events, &(&1.kind == :tool_result))
  end

  defp transport_text(reason),
    do: %{type: :transport_error, message: "Failed to send request: #{inspect(reason)}"}

  @stdio_script """
  import json, os, sys
  for line in sys.stdin:
      request = json.loads(line)
      method = request.get("method")
      response = None
      if method == "initialize":
          response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "stdio", "version": "1"}}}
      elif method == "tools/list":
          response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {"tools": [{"name": name, "description": name, "inputSchema": {"type": "object"}} for name in ["answer", "exit"]]}}
      elif method == "tools/call":
          with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ran"), "a") as ran:
              ran.write(request["params"]["name"] + "\\n")
          if request["params"]["name"] == "exit":
              os._exit(3)
          response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {"content": [{"type": "text", "text": "done"}]}}
      elif request.get("id") is not None:
          response = {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Method not found"}}
      if response is not None:
          sys.stdout.write(json.dumps(response) + "\\n")
          sys.stdout.flush()
  """

  defp owned_stdio_processes do
    for pid <- Process.list(),
        match?({:dictionary, %{"$initial_call": {Imp.MCP.OwnedStdio, :init, 1}}}, dict(pid)),
        do: pid
  end

  defp dict(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, entries} -> {:dictionary, Map.new(entries)}
      nil -> nil
    end
  end

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  defp stdio_tools(dir) do
    script = Path.join(dir, "server.py")
    File.write!(script, @stdio_script)
    python = System.find_executable("python3") || raise "python3 required for this test"

    tools(
      %{"name" => "stdio", "type" => "stdio", "command" => python, "args" => [script]},
      timeout: 10_000
    )
  end
end

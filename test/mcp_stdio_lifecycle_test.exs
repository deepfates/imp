defmodule Imp.MCPStdioLifecycleTest do
  # The shared ExMCP transport owns a persistent server and its descendants.
  # Explicit close must reap even servers that ignore EOF and SIGTERM;
  # cancelling a request alone does not claim rollback or server termination.
  use ExUnit.Case, async: true

  alias Imp.MCP

  @moduletag :tmp_dir

  test "stdio server that ignores stdin EOF is killed, not orphaned", %{tmp_dir: tmp_dir} do
    {pid_file, client} = fake_server(tmp_dir, "eof_ignoring", ignore_sigterm: false)

    assert [%{"name" => "noop"}] =
             Enum.map(client.tools, fn tool ->
               %{"name" => to_string(tool.name)}
             end)

    os_pid = read_pid!(pid_file)
    client.cleanup.()
    assert os_process_dead?(os_pid), "stdio server #{os_pid} survived teardown as an orphan"
  end

  test "stdio server that also ignores SIGTERM is KILLed", %{tmp_dir: tmp_dir} do
    {pid_file, client} = fake_server(tmp_dir, "term_ignoring", ignore_sigterm: true)

    assert [%{"name" => "noop"}] =
             Enum.map(client.tools, fn tool ->
               %{"name" => to_string(tool.name)}
             end)

    os_pid = read_pid!(pid_file)
    client.cleanup.()
    assert os_process_dead?(os_pid), "stdio server #{os_pid} survived TERM and KILL escalation"
  end

  test "tool calls reuse a connection until explicit close reaps it", %{tmp_dir: tmp_dir} do
    {pid_file, client} = fake_server(tmp_dir, "tool_call", ignore_sigterm: false)

    [tool] = client.tools

    assert %{"ok" => true} = Imp.Tool.call(tool, %{})

    os_pid = read_pid!(pid_file)
    client.cleanup.()
    assert os_process_dead?(os_pid), "stdio tool-call server #{os_pid} survived teardown"
  end

  test "Run cancellation followed by owner cleanup reaps a noncooperative server", %{
    tmp_dir: tmp_dir
  } do
    started_file = Path.join(tmp_dir, "cancel.started")
    child_pid_file = Path.join(tmp_dir, "cancel.child.pid")

    {pid_file, client} =
      fake_server(tmp_dir, "cancel_blocked",
        ignore_sigterm: true,
        block_tool_call: {started_file, child_pid_file}
      )

    [tool] = client.tools

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "call the external tool",
            tool_calls: [%{id: "stdio-blocked", name: "noop", arguments: %{}}]
          }
        end
      )

    program = Imp.react_v2("question -> answer", [tool], lm: lm)
    assert {:ok, run} = Imp.start_run(program, %{question: "block"})
    wait_for_file!(started_file)

    os_pid = read_pid!(pid_file)
    child_pid = read_pid!(child_pid_file)

    on_exit(fn -> kill_process_group(os_pid) end)

    cancellation = Task.async(fn -> Imp.cancel_run(run, :probe_cancel, 200) end)
    assert :ok = Task.await(cancellation, 5_000)

    client.cleanup.()

    assert os_process_dead?(os_pid),
           "stdio tool-call server #{os_pid} survived Run cancellation"

    assert os_process_dead?(child_pid),
           "stdio tool-call child #{child_pid} survived process-group cancellation"
  end

  test "a client killed without closing takes its server's process group with it", %{
    tmp_dir: tmp_dir
  } do
    started_file = Path.join(tmp_dir, "killed.started")
    child_pid_file = Path.join(tmp_dir, "killed.child.pid")

    {pid_file, script} =
      server_script(tmp_dir, "killed_owner",
        ignore_sigterm: true,
        block_tool_call: {started_file, child_pid_file}
      )

    python = System.find_executable("python3")
    {:ok, _started} = Application.ensure_all_started(:ex_mcp)

    Process.flag(:trap_exit, true)

    {:ok, client} =
      ExMCP.Client.start_link(
        transport: Imp.MCP.OwnedStdio,
        command: [python, script],
        health_check_interval: nil,
        reconnect: false
      )

    caller = self()

    spawn(fn ->
      send(caller, {:call, ExMCP.Client.call_tool(client, "noop", %{}, timeout: 30_000)})
    end)

    wait_for_file!(started_file)
    os_pid = read_pid!(pid_file)
    child_pid = read_pid!(child_pid_file)
    on_exit(fn -> kill_process_group(os_pid) end)

    Process.exit(client, :kill)

    assert os_process_dead?(os_pid), "stdio server #{os_pid} outlived its killed client"

    assert os_process_dead?(child_pid),
           "stdio server child #{child_pid} outlived its killed client"
  end

  test "a server that exits on its own leaves no child behind", %{tmp_dir: tmp_dir} do
    started_file = Path.join(tmp_dir, "exits.started")
    child_pid_file = Path.join(tmp_dir, "exits.child.pid")

    {pid_file, script} =
      server_script(tmp_dir, "exits_itself",
        ignore_sigterm: true,
        block_tool_call: {started_file, child_pid_file},
        exit_after_child: true
      )

    python = System.find_executable("python3")
    {:ok, _started} = Application.ensure_all_started(:ex_mcp)
    Process.flag(:trap_exit, true)

    {:ok, client} =
      ExMCP.Client.start_link(
        transport: Imp.MCP.OwnedStdio,
        command: [python, script],
        health_check_interval: nil,
        reconnect: false
      )

    spawn(fn -> ExMCP.Client.call_tool(client, "noop", %{}, timeout: 30_000) end)

    wait_for_file!(started_file)
    os_pid = read_pid!(pid_file)
    child_pid = read_pid!(child_pid_file)
    on_exit(fn -> kill_process_group(os_pid) end)

    assert os_process_dead?(os_pid), "stdio server #{os_pid} did not exit"

    assert os_process_dead?(child_pid, 5_000),
           "stdio server child #{child_pid} outlived the server that started it"
  end

  # A request that cannot be written is reported in the words ExMCP's client
  # and `Imp.MCP.CallFailure` already read as "never sent".
  test "a request to a server that has exited, or one too large to send, was not sent" do
    python = System.find_executable("python3")

    {:ok, stdio} =
      Imp.MCP.OwnedStdio.connect(command: [python, "-c", "pass"], max_frame_bytes: 64)

    on_exit(fn -> Imp.MCP.OwnedStdio.close(stdio) end)

    assert {:error, {:connection_error, {:process_exited, 0}}} =
             Imp.MCP.OwnedStdio.receive_message(stdio, 5_000)

    request = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"})
    assert {:error, :not_connected} = Imp.MCP.OwnedStdio.send_message(request, stdio)

    assert {:error, :request_too_large} =
             Imp.MCP.OwnedStdio.send_message(String.duplicate("x", 65), stdio)

    for reason <- [
          :not_connected,
          %{type: :transport_error, message: "Failed to send request: :request_too_large"}
        ] do
      assert %Imp.MCP.CallFailure{outcome: :not_sent} =
               Imp.MCP.CallFailure.returned("s", "t", reason)
    end
  end

  # A JSON-RPC server that answers initialize/tools/list/tools/call, then
  # deliberately refuses to exit on stdin EOF (and optionally ignores SIGTERM).
  defp fake_server(tmp_dir, label, opts) do
    {pid_file, script} = server_script(tmp_dir, label, opts)
    python = System.find_executable("python3") || raise "python3 required for this regression"
    {pid_file, Imp.Test.MCPConnect.stdio!(python, args: [script], timeout: 15_000)}
  end

  defp server_script(tmp_dir, label, opts) do
    ignore_sigterm = Keyword.fetch!(opts, :ignore_sigterm)
    block_tool_call = Keyword.get(opts, :block_tool_call)
    # After starting its child, the server exits on its own instead of blocking.
    after_child =
      if Keyword.get(opts, :exit_after_child, false), do: "os._exit(0)", else: "time.sleep(300)"

    pid_file = Path.join(tmp_dir, "#{label}.pid")
    script = Path.join(tmp_dir, "#{label}.py")

    sigterm_line =
      if ignore_sigterm,
        do: "signal.signal(signal.SIGTERM, signal.SIG_IGN)",
        else: "pass"

    tool_call_body =
      case block_tool_call do
        {started_file, child_pid_file} ->
          """
          with open(#{inspect(started_file)}, "w") as handle:
              handle.write("started")
          child = subprocess.Popen([
              sys.executable,
              "-c",
              "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)",
          ])
          with open(#{inspect(child_pid_file)}, "w") as handle:
              handle.write(str(child.pid))
          #{after_child}
          """

        nil ->
          """
          response = {
              "jsonrpc": "2.0",
              "id": request.get("id"),
              "result": {"ok": True},
          }
          """
      end

    File.write!(script, """
    import json
    import os
    import signal
    import subprocess
    import sys
    import time

    #{sigterm_line}

    with open(#{inspect(pid_file)}, "w") as handle:
        handle.write(str(os.getpid()))

    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        response = None

        if method == "initialize":
            response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}}
        elif method == "tools/list":
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": {
                    "tools": [
                        {
                            "name": "noop",
                            "description": "does nothing",
                            "inputSchema": {"type": "object"},
                        }
                    ]
                },
            }
        elif method == "tools/call":
            #{tool_call_body |> String.trim() |> String.replace("\n", "\n        ")}
        elif request.get("id") is not None:
            response = {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Method not found"}}

        if response is not None:
            sys.stdout.write(json.dumps(response) + "\\n")
            sys.stdout.flush()

    # Ignore stdin EOF: linger long past any test timeout.
    time.sleep(300)
    """)

    {pid_file, script}
  end

  defp read_pid!(pid_file) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    wait_for_pid_file(pid_file, deadline)
  end

  defp wait_for_pid_file(pid_file, deadline) do
    case File.read(pid_file) do
      {:ok, contents} when contents != "" ->
        String.to_integer(String.trim(contents))

      _missing ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "fake stdio server never wrote #{pid_file}"
        end

        Process.sleep(20)
        wait_for_pid_file(pid_file, deadline)
    end
  end

  defp wait_for_file!(path) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    wait_for_file(path, deadline)
  end

  defp wait_for_file(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "fake stdio server never wrote #{path}"
      end

      Process.sleep(20)
      wait_for_file(path, deadline)
    end
  end

  defp kill_process_group(os_pid) do
    kill = System.find_executable("kill") || "/bin/kill"
    _ = System.cmd(kill, ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  end

  # kill -0 probes existence without sending a signal. Poll briefly so process
  # table cleanup after a synchronous kill cannot flake the assertion.
  defp os_process_dead?(os_pid, within \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + within
    poll_dead(os_pid, deadline)
  end

  defp poll_dead(os_pid, deadline) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    cond do
      status != 0 ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        poll_dead(os_pid, deadline)
    end
  end
end

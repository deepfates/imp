defmodule Imp.MCPStdioLifecycleTest do
  # Regression for de-2bcy: the stdio transport used to tear down with
  # Port.close/1 only, which merely closes stdin. Servers that ignore stdin EOF
  # (or SIGTERM) accumulated as orphan OS processes. Teardown now goes through
  # Imp.ExternalCommand.Lifecycle.terminate_port_group/3 (TERM -> grace -> KILL
  # on the process group).
  use ExUnit.Case, async: true

  alias Imp.MCP

  @moduletag :tmp_dir

  test "stdio server that ignores stdin EOF is killed, not orphaned", %{tmp_dir: tmp_dir} do
    {pid_file, client} = fake_server(tmp_dir, "eof_ignoring", ignore_sigterm: false)

    assert [%{"name" => "noop"}] =
             Enum.map(MCP.StdioClient.list_tools(client), &Map.take(&1, ["name"]))

    os_pid = read_pid!(pid_file)
    assert os_process_dead?(os_pid), "stdio server #{os_pid} survived teardown as an orphan"
  end

  test "stdio server that also ignores SIGTERM is KILLed", %{tmp_dir: tmp_dir} do
    {pid_file, client} = fake_server(tmp_dir, "term_ignoring", ignore_sigterm: true)

    assert [%{"name" => "noop"}] =
             Enum.map(MCP.StdioClient.list_tools(client), &Map.take(&1, ["name"]))

    os_pid = read_pid!(pid_file)
    assert os_process_dead?(os_pid), "stdio server #{os_pid} survived TERM and KILL escalation"
  end

  test "tool calls over stdio also reap the per-call server", %{tmp_dir: tmp_dir} do
    {pid_file, client} = fake_server(tmp_dir, "tool_call", ignore_sigterm: false)

    [tool] = MCP.import_tools(client)
    File.rm(pid_file)

    assert %{"ok" => true} = Imp.Tool.call(tool, %{})

    os_pid = read_pid!(pid_file)
    assert os_process_dead?(os_pid), "stdio tool-call server #{os_pid} survived teardown"
  end

  # A JSON-RPC server that answers initialize/tools/list/tools/call, then
  # deliberately refuses to exit on stdin EOF (and optionally ignores SIGTERM).
  defp fake_server(tmp_dir, label, ignore_sigterm: ignore_sigterm) do
    pid_file = Path.join(tmp_dir, "#{label}.pid")
    script = Path.join(tmp_dir, "#{label}.py")

    sigterm_line =
      if ignore_sigterm,
        do: "signal.signal(signal.SIGTERM, signal.SIG_IGN)",
        else: "pass"

    File.write!(script, """
    import json
    import os
    import signal
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
            response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {}}
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
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": {"ok": True},
            }

        if response is not None:
            sys.stdout.write(json.dumps(response) + "\\n")
            sys.stdout.flush()

    # Ignore stdin EOF: linger long past any test timeout.
    time.sleep(300)
    """)

    python = System.find_executable("python3") || raise "python3 required for this regression"
    {pid_file, MCP.StdioClient.new(python, args: [script], timeout: 15_000)}
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

  # kill -0 probes existence without sending a signal. Poll briefly so process
  # table cleanup after a synchronous kill cannot flake the assertion.
  defp os_process_dead?(os_pid) do
    deadline = System.monotonic_time(:millisecond) + 2_000
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

defmodule Imp.MCPStdioEnvironmentTest do
  # What a local MCP server's environment is: the host's ordinary variables
  # minus any OTP release directories on PATH, and the descriptor's own env.
  # Changes the VM's environment, so not async.
  use ExUnit.Case, async: false

  alias Imp.MCP

  @moduletag :tmp_dir

  setup do
    saved = Map.take(System.get_env(), ["PATH", "RELEASE_ROOT", "IMP_TEST_HOST_SECRET"])

    on_exit(fn ->
      for name <- ["PATH", "RELEASE_ROOT", "IMP_TEST_HOST_SECRET"] do
        case Map.fetch(saved, name) do
          {:ok, value} -> System.put_env(name, value)
          :error -> System.delete_env(name)
        end
      end
    end)

    :ok
  end

  test "a server started from inside a release finds the host's programs, not the release's",
       %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || raise "python3 required for this test"

    # A release puts its own bin directories first. Its `python3` here stands in
    # for the release's `erl`: found first, and wrong for the child.
    release = Path.join(tmp_dir, "release")
    release_bin = Path.join(release, "erts-16.0/bin")
    File.mkdir_p!(release_bin)
    shadow = Path.join(release_bin, "python3")
    File.write!(shadow, "#!/bin/sh\necho 'release runtime, not the host' >&2\nexit 70\n")
    File.chmod!(shadow, 0o755)

    host_path = System.get_env("PATH")
    System.put_env("RELEASE_ROOT", release)
    System.put_env("PATH", Enum.join([release_bin, Path.join(release, "bin"), host_path], ":"))
    System.put_env("IMP_TEST_HOST_SECRET", "not-for-servers")

    report = Path.join(tmp_dir, "environment.json")
    script = Path.join(tmp_dir, "server.py")
    File.write!(script, server_script(report))

    client =
      MCP.StdioClient.new("python3",
        args: [script],
        env: [{"IMP_TEST_DECLARED", "declared"}],
        timeout: 15_000
      )

    assert [%{name: name}] = MCP.StdioClient.list_tools(client)
    assert to_string(name) == "noop"
    MCP.StdioClient.close(client)

    environment = report |> File.read!() |> Jason.decode!()
    entries = String.split(environment["PATH"], ":")

    refute Enum.any?(entries, &String.starts_with?(&1, release)),
           "release directories reached the server's PATH: #{environment["PATH"]}"

    assert Path.dirname(python) in entries
    assert environment["IMP_TEST_DECLARED"] == "declared"
    refute Map.has_key?(environment, "IMP_TEST_HOST_SECRET")
    refute Map.has_key?(environment, "RELEASE_ROOT")
  end

  defp server_script(report) do
    """
    import json
    import os
    import sys

    with open(#{inspect(report)}, "w") as handle:
        json.dump(dict(os.environ), handle)

    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        response = None

        if method == "initialize":
            response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}}
        elif method == "tools/list":
            response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {"tools": [{"name": "noop", "description": "does nothing", "inputSchema": {"type": "object"}}]}}
        elif request.get("id") is not None:
            response = {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Method not found"}}

        if response is not None:
            sys.stdout.write(json.dumps(response) + "\\n")
            sys.stdout.flush()
    """
  end
end

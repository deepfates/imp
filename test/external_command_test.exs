defmodule DSEx.ExternalCommandTest do
  use ExUnit.Case, async: false

  test "passes metacharacters as literal argv without a shell and redacts bounded output" do
    marker = "dsex-shell-marker-#{System.unique_integer([:positive])}"

    literal = "value; touch #{marker}"

    assert {:ok, result} =
             DSEx.ExternalCommand.run("printf", ["%s", literal], max_output_bytes: 100)

    assert result.exit_status == 0
    assert result.output =~ "; touch #{marker}"
    refute File.exists?(marker)

    secret = "sk-local-command-secret-1234567890"
    assert {:ok, redacted} = DSEx.ExternalCommand.run("printf", ["%s", secret])
    assert redacted.output == "[REDACTED]"
    refute redacted.output =~ secret

    assert {:ok, bounded} =
             DSEx.ExternalCommand.run("python3", ["-c", "print('x ' * 500, end='')"],
               max_output_bytes: 64
             )

    assert byte_size(bounded.output) == 64
    assert bounded.output =~ "[output truncated]"
  end

  @tag timeout: 5_000
  test "timeout terminates the command and its spawned child" do
    script =
      "import subprocess,time; p=subprocess.Popen(['sleep','30']); print(p.pid, flush=True); time.sleep(30)"

    assert {:error, {:timeout, result}} =
             DSEx.ExternalCommand.run("python3", ["-c", script],
               timeout: 500,
               kill_grace_ms: 100
             )

    child_pid = result.output |> String.trim() |> String.to_integer()
    Process.sleep(50)
    refute process_alive?(child_pid)
  end

  test "returns a structured nonzero result" do
    assert {:error, {:exit_status, 7, %{exit_status: 7, output: "failed"}}} =
             DSEx.ExternalCommand.run("python3", [
               "-c",
               "import sys; print('failed', end=''); sys.exit(7)"
             ])
  end

  @tag timeout: 5_000
  test "managed stop is a synchronous process-group cleanup barrier" do
    root =
      Path.join(System.tmp_dir!(), "dsex-managed-command-#{System.unique_integer([:positive])}")

    child_file = Path.join(root, "child.pid")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    script = """
    import signal,subprocess,sys,time
    child=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'])
    open(sys.argv[1],'w').write(str(child.pid))
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)
    """

    assert {:ok, handle} =
             DSEx.ExternalCommand.start("python3", ["-c", script, child_file],
               timeout: :infinity,
               kill_grace_ms: 100
             )

    child_pid = await_pid_file!(child_file)
    assert process_alive?(handle.os_pid)
    assert process_alive?(child_pid)
    assert :ok = DSEx.ExternalCommand.stop(handle, 2_000)
    refute process_alive?(handle.os_pid)
    refute process_alive?(child_pid)
  end

  @tag timeout: 5_000
  test "normal leader exit cleans descendants before run returns" do
    root = Path.join(System.tmp_dir!(), "dsex-exit-command-#{System.unique_integer([:positive])}")
    child_file = Path.join(root, "child.pid")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    script = """
    import subprocess,sys
    child=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    open(sys.argv[1],'w').write(str(child.pid))
    """

    assert {:ok, %{exit_status: 0}} =
             DSEx.ExternalCommand.run("python3", ["-c", script, child_file], kill_grace_ms: 100)

    child_pid = child_file |> File.read!() |> String.to_integer()
    refute process_alive?(child_pid)
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp await_pid_file!(path, attempts \\ 100)
  defp await_pid_file!(_path, 0), do: raise("child pid file was not written")

  defp await_pid_file!(path, attempts) do
    case File.read(path) do
      {:ok, value} ->
        String.to_integer(value)

      {:error, :enoent} ->
        Process.sleep(10)
        await_pid_file!(path, attempts - 1)
    end
  end
end

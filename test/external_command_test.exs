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
               timeout: 100,
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

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end

defmodule DSEx.BenchmarkTruth.ParitySidecarTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.ParitySidecar
  alias DSEx.BenchmarkTruth.ParitySidecar.Output

  @python System.find_executable("python3")
  @kill System.find_executable("kill") || "/bin/kill"

  setup do
    unless @python, do: flunk("python3 is required for parity sidecar tests")
    :ok
  end

  test "captures a normal sentinel/result and runs in the OTP Port session" do
    assert {:ok, %Output{} = output, 0} =
             ParitySidecar.run(@python, [
               "-c",
               ~S|import os; print(f"{os.getpid()}:{os.getpgrp()}:{os.getsid(0)}"); print("DSPY_REPORT_PATH=tmp/report.json")|
             ])

    refute output.truncated
    assert output.total_bytes == output.captured_bytes

    assert {:ok, "tmp/report.json"} =
             Mix.Tasks.Dsex.Benchmark.Parity.parse_dspy_report_path(output.text)

    [identity, _sentinel] = String.split(output.text, "\n", trim: true)
    [pid, group, session] = String.split(identity, ":")
    assert pid == group
    assert pid == session
  end

  test "captures child crashes without leaking the Port owner" do
    owners_before = parity_sidecar_owners()

    assert {:ok, %Output{text: "before crash\n", truncated: false}, 23} =
             ParitySidecar.run(@python, [
               "-c",
               ~S|import sys; print("before crash", flush=True); sys.exit(23)|
             ])

    assert parity_sidecar_owners() == owners_before
  end

  test "killing the caller terminates the Python process and its descendant" do
    pid_path = tmp_path("caller-kill")
    task = Task.async(fn -> ParitySidecar.run(@python, process_tree_args(pid_path)) end)
    [parent_pid, child_pid, group_pid] = await_pids(pid_path)

    assert parent_pid == group_pid
    assert process_alive?(parent_pid)
    assert process_alive?(child_pid)
    Task.shutdown(task, :brutal_kill)

    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
    refute process_group_alive?(group_pid)
  end

  test "a crashing caller terminates the Python process and its descendant" do
    pid_path = tmp_path("caller-crash")

    caller =
      spawn(fn ->
        ParitySidecar.run(@python, process_tree_args(pid_path))
      end)

    caller_ref = Process.monitor(caller)
    [parent_pid, child_pid, group_pid] = await_pids(pid_path)
    Process.exit(caller, :campaign_crash)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :campaign_crash}, 1_000
    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
    refute process_group_alive?(group_pid)
  end

  test "timeout returns captured output and terminates the process tree" do
    pid_path = tmp_path("timeout")

    assert {:error, :timeout, %Output{} = output} =
             ParitySidecar.run(@python, process_tree_args(pid_path), timeout: 150)

    assert output.text =~ "tree ready"
    [parent_pid, child_pid, group_pid] = await_pids(pid_path)
    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
    refute process_group_alive?(group_pid)
  end

  test "bounded cleanup kills a fully TERM-resistant process tree" do
    pid_path = tmp_path("term-resistant")

    assert {:error, :timeout, %Output{}} =
             ParitySidecar.run(
               @python,
               process_tree_args(pid_path, leader_ignore_term: true, child_ignore_term: true),
               timeout: 150
             )

    [parent_pid, child_pid, group_pid] = await_pids(pid_path)
    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
    refute process_group_alive?(group_pid)
  end

  test "Port exit does not hide a TERM-resistant child with redirected stdio" do
    pid_path = tmp_path("mixed-tree")

    assert {:error, :timeout, %Output{text: text}} =
             ParitySidecar.run(
               @python,
               process_tree_args(pid_path,
                 child_ignore_term: true,
                 child_redirect_stdio: true
               ),
               timeout: 150
             )

    assert text =~ "tree ready"
    [parent_pid, child_pid, group_pid] = await_pids(pid_path)
    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
    refute process_group_alive?(group_pid)
  end

  test "output floods retain a bounded tail and explicit truncation metadata" do
    limit = 1024

    assert {:ok, %Output{} = output, 0} =
             ParitySidecar.run(
               @python,
               [
                 "-c",
                 ~S|import sys; sys.stdout.write("x" * 100000); print("\nDSPY_REPORT_PATH=tmp/flood-report.json")|
               ],
               max_output_bytes: limit
             )

    assert output.truncated
    assert output.total_bytes > 100_000
    assert output.captured_bytes == limit
    assert output.limit_bytes == limit
    assert byte_size(output.text) <= limit

    assert {:ok, "tmp/flood-report.json"} =
             Mix.Tasks.Dsex.Benchmark.Parity.parse_dspy_report_path(output.text)

    diagnostic = ParitySidecar.diagnostic(output)
    assert diagnostic =~ "sidecar output truncated"
    assert diagnostic =~ "captured tail 1024"
  end

  test "captured diagnostics redact configured and credential-shaped secrets" do
    secret = "provider-secret-value-0123456789"
    openai_secret = "sk-test-sidecar-secret-1234567890"
    bearer = "Bearer abcdefghijklmnopqrstuvwxyz123456"

    code =
      "import sys; print(#{inspect(secret)}); print(#{inspect(openai_secret)}); " <>
        "print(#{inspect(bearer)}); sys.exit(17)"

    assert {:ok, %Output{} = output, 17} =
             ParitySidecar.run(@python, ["-c", code], secrets: [secret])

    diagnostic = ParitySidecar.diagnostic(output)
    refute diagnostic =~ secret
    refute diagnostic =~ openai_secret
    refute diagnostic =~ bearer
    assert diagnostic =~ "[REDACTED]"
    assert output.total_bytes > byte_size(output.text)
  end

  test "validates timeout, output limit, and secrets" do
    assert_raise ArgumentError, ~r/sidecar timeout/, fn ->
      ParitySidecar.run(@python, ["-c", "pass"], timeout: 0)
    end

    assert_raise ArgumentError, ~r/output limit/, fn ->
      ParitySidecar.run(@python, ["-c", "pass"], max_output_bytes: 0)
    end

    assert_raise ArgumentError, ~r/sidecar secrets/, fn ->
      ParitySidecar.run(@python, ["-c", "pass"], secrets: [:not_a_string])
    end
  end

  defp process_tree_args(pid_path, opts \\ []) do
    leader_ignore_term = Keyword.get(opts, :leader_ignore_term, false)
    child_ignore_term = Keyword.get(opts, :child_ignore_term, false)
    child_redirect_stdio = Keyword.get(opts, :child_redirect_stdio, false)

    child_stdio =
      if child_redirect_stdio do
        ", stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL"
      else
        ""
      end

    code = """
    import os, signal, subprocess, sys, time
    #{if leader_ignore_term, do: "signal.signal(signal.SIGTERM, signal.SIG_IGN)", else: ""}
    child_code = #{inspect(child_code(child_ignore_term))}
    child = subprocess.Popen([sys.executable, "-c", child_code]#{child_stdio})
    with open(#{inspect(pid_path)}, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\\n{child.pid}\\n{os.getpgrp()}\\n")
        handle.flush()
        os.fsync(handle.fileno())
    print("tree ready", flush=True)
    time.sleep(60)
    """

    ["-c", code]
  end

  defp child_code(true) do
    "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
  end

  defp child_code(false), do: "import time; time.sleep(60)"

  defp await_pids(path, attempts \\ 100)
  defp await_pids(_path, 0), do: flunk("sidecar did not publish process ids")

  defp await_pids(path, attempts) do
    case File.read(path) do
      {:ok, contents} ->
        case contents |> String.split("\n", trim: true) |> Enum.map(&Integer.parse/1) do
          [{parent, ""}, {child, ""}, {group, ""}] -> [parent, child, group]
          _other -> retry_pids(path, attempts)
        end

      _other ->
        retry_pids(path, attempts)
    end
  end

  defp retry_pids(path, attempts) do
    Process.sleep(20)
    await_pids(path, attempts - 1)
  end

  defp await_alive?(pid, attempts \\ 100)
  defp await_alive?(pid, 0), do: process_alive?(pid)

  defp await_alive?(pid, attempts) do
    if process_alive?(pid) do
      Process.sleep(20)
      await_alive?(pid, attempts - 1)
    else
      false
    end
  end

  defp process_alive?(pid), do: signal_status(Integer.to_string(pid)) == 0
  defp process_group_alive?(pid), do: signal_status("-#{pid}") == 0

  defp signal_status(target) do
    {_output, status} = System.cmd(@kill, ["-0", target], stderr_to_stdout: true)
    assert status in [0, 1]
    status
  end

  defp parity_sidecar_owners do
    Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor)
  end

  defp tmp_path(name) do
    path =
      Path.join(System.tmp_dir!(), "dsex-sidecar-#{name}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    path
  end
end

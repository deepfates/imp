defmodule DSEx.BenchmarkTruth.ParitySidecarTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.ParitySidecar

  @python System.find_executable("python3")
  @kill System.find_executable("kill") || "/bin/kill"

  setup do
    unless @python, do: flunk("python3 is required for parity sidecar tests")
    :ok
  end

  test "captures normal output and exit status" do
    assert {:ok, "normal output\n", 0} =
             ParitySidecar.run(@python, ["-c", ~S|print("normal output")|])

    assert {:ok, process_group, 0} =
             ParitySidecar.run(@python, [
               "-c",
               ~S|import os; print(f"{os.getpid()}:{os.getpgrp()}")|
             ])

    [pid, group] = process_group |> String.trim() |> String.split(":")
    assert pid == group
  end

  test "captures child crashes without leaking the Port owner" do
    owners_before = parity_sidecar_owners()

    assert {:ok, "before crash\n", 23} =
             ParitySidecar.run(@python, [
               "-c",
               ~S|import sys; print("before crash", flush=True); sys.exit(23)|
             ])

    assert parity_sidecar_owners() == owners_before
  end

  test "killing the caller terminates the Python process and its descendant" do
    pid_path = tmp_path("caller-kill")
    task = Task.async(fn -> ParitySidecar.run(@python, process_tree_args(pid_path)) end)
    [parent_pid, child_pid] = await_pids(pid_path)

    assert process_alive?(parent_pid)
    assert process_alive?(child_pid)
    Task.shutdown(task, :brutal_kill)

    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
  end

  test "timeout returns captured output and terminates the process tree" do
    pid_path = tmp_path("timeout")

    assert {:error, :timeout, output} =
             ParitySidecar.run(@python, process_tree_args(pid_path), timeout: 150)

    assert output =~ "tree ready"
    [parent_pid, child_pid] = await_pids(pid_path)
    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
  end

  test "bounded cleanup kills a TERM-resistant process tree without leaks" do
    pid_path = tmp_path("term-resistant")

    assert {:error, :timeout, _output} =
             ParitySidecar.run(@python, process_tree_args(pid_path, ignore_term: true),
               timeout: 150
             )

    [parent_pid, child_pid] = await_pids(pid_path)
    refute await_alive?(parent_pid)
    refute await_alive?(child_pid)
  end

  defp process_tree_args(pid_path, opts \\ []) do
    ignore_term = Keyword.get(opts, :ignore_term, false)

    code = """
    import os, signal, subprocess, sys, time
    if os.getpgrp() != os.getpid():
        os.setsid()
    #{if ignore_term, do: "signal.signal(signal.SIGTERM, signal.SIG_IGN)", else: ""}
    child_code = #{inspect(child_code(ignore_term))}
    child = subprocess.Popen([sys.executable, "-c", child_code])
    with open(#{inspect(pid_path)}, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\\n{child.pid}\\n")
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
          [{parent, ""}, {child, ""}] -> [parent, child]
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

  defp process_alive?(pid) do
    {_output, status} = System.cmd(@kill, ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp parity_sidecar_owners do
    DSEx.UnlinkedTaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :current_function) do
        {:current_function, {ParitySidecar, :port_owner, 5}} -> true
        _other -> false
      end
    end)
  end

  defp tmp_path(name) do
    path =
      Path.join(System.tmp_dir!(), "dsex-sidecar-#{name}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    path
  end
end

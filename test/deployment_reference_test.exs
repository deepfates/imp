defmodule DeploymentReferenceTest do
  use ExUnit.Case, async: false

  @example_root Path.expand("../examples/deployment", __DIR__)

  setup_all do
    Code.require_file(Path.join(@example_root, "lib/dsex_deployment/callbacks.ex"))
    Code.require_file(Path.join(@example_root, "lib/dsex_deployment/program_server.ex"))
    Code.require_file(Path.join(@example_root, "lib/dsex_deployment/application.ex"))
    :ok
  end

  test "reference OTP server loads a checksummed registry-backed artifact and serves calls" do
    path =
      Path.join(System.tmp_dir!(), "dsex-deployment-#{System.unique_integer([:positive])}.json")

    previous_path = System.get_env("DSEX_ARTIFACT_PATH")
    previous_answer = System.get_env("DSEX_STATIC_ANSWER")

    on_exit(fn ->
      File.rm(path)
      restore_env("DSEX_ARTIFACT_PATH", previous_path)
      restore_env("DSEX_STATIC_ANSWER", previous_answer)
    end)

    metric = fn _example, prediction -> DSEx.get(prediction, :answer, "") != "" end
    registry = DSEx.Saving.Registry.new(quality_metric: metric)

    program =
      DSEx.predict("question -> answer")
      |> DSEx.Predict.BestOfN.new(metric, n: 2)

    assert :ok = DSEx.save!(program, path, registry: registry)
    System.put_env("DSEX_ARTIFACT_PATH", path)
    System.put_env("DSEX_STATIC_ANSWER", "Paris")

    task_supervisor = start_supervised!({Task.Supervisor, max_children: 2})

    start_supervised!({DSExDeployment.ProgramServer, task_supervisor: task_supervisor})

    assert {:ok, prediction} =
             apply(DSExDeployment.ProgramServer, :call, [%{question: "Capital?"}])

    assert DSEx.get(prediction, :answer) == "Paris"
  end

  test "a slow provider call does not serialize a fast call" do
    test_pid = self()

    executor = fn _program, _lm, input ->
      send(test_pid, {:started, input, self()})

      if input == :slow do
        receive do
          :release -> {:ok, :slow}
        end
      else
        {:ok, :fast}
      end
    end

    {server, _task_supervisor} = start_runtime(executor, max_children: 2)
    slow = Task.async(fn -> deployment_call(server, :slow, 1_000) end)

    assert_receive {:started, :slow, slow_worker}
    assert {:ok, :fast} = deployment_call(server, :fast, 200)
    assert Process.alive?(slow_worker)

    send(slow_worker, :release)
    assert {:ok, :slow} = Task.await(slow)
  end

  test "timeouts terminate only the timed-out worker" do
    test_pid = self()

    executor = fn _program, _lm, _input ->
      send(test_pid, {:started, self()})
      Process.sleep(:infinity)
    end

    {server, _task_supervisor} = start_runtime(executor)
    caller = Task.async(fn -> deployment_call(server, :input, 25) end)

    assert_receive {:started, worker}
    worker_ref = Process.monitor(worker)
    assert {:error, :timeout} = Task.await(caller)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert Process.alive?(server)
  end

  test "worker crashes are isolated from callers and the ProgramServer" do
    executor = fn _program, _lm, :crash -> exit(:provider_crash) end
    {server, _task_supervisor} = start_runtime(executor)

    assert {:error, {:worker_crash, :provider_crash}} =
             deployment_call(server, :crash, 200)

    assert Process.alive?(server)
  end

  test "bounded workers reject excess calls without disturbing in-flight work" do
    test_pid = self()

    executor = fn _program, _lm, _input ->
      send(test_pid, {:started, self()})
      receive do: (:release -> {:ok, :done})
    end

    {server, _task_supervisor} = start_runtime(executor, max_children: 1)
    first = Task.async(fn -> deployment_call(server, :first, 1_000) end)

    assert_receive {:started, worker}
    assert {:error, :overloaded} = deployment_call(server, :second, 200)

    send(worker, :release)
    assert {:ok, :done} = Task.await(first)
  end

  test "supervisor shutdown terminates in-flight workers and releases callers" do
    test_pid = self()
    task_name = {:global, {__MODULE__, make_ref()}}
    server_name = {:global, {__MODULE__, make_ref()}}

    executor = fn _program, _lm, _input ->
      send(test_pid, {:started, self()})
      Process.sleep(:infinity)
    end

    task_spec =
      Supervisor.child_spec(
        {Task.Supervisor, name: task_name, max_children: 1},
        shutdown: 25
      )

    children = [
      task_spec,
      {DSExDeployment.ProgramServer,
       name: server_name,
       task_supervisor: task_name,
       program: :program,
       lm: :lm,
       executor: executor}
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    caller = Task.async(fn -> deployment_call(server_name, :input, 1_000) end)
    assert_receive {:started, worker}
    worker_ref = Process.monitor(worker)

    assert :ok = Supervisor.stop(supervisor)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :shutdown}
    assert {:error, {:worker_crash, :shutdown}} = Task.await(caller)
    refute Process.alive?(supervisor)
  end

  test "reference project declares both published and source-checkout dependency modes" do
    mix_file = File.read!(Path.join(@example_root, "mix.exs"))
    readme = File.read!(Path.join(@example_root, "README.md"))

    assert mix_file =~ ~s({:dsex, "~> 0.1"})
    assert mix_file =~ "DSEX_PATH"
    assert readme =~ "supervised startup"
    assert readme =~ "DSEX_MODEL"
    assert readme =~ "DSEX_MAX_CONCURRENCY"
  end

  defp start_runtime(executor, opts \\ []) do
    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: Keyword.get(opts, :max_children, 2)})

    server =
      start_supervised!(
        {DSExDeployment.ProgramServer,
         name: nil,
         task_supervisor: task_supervisor,
         program: :program,
         lm: :lm,
         executor: executor}
      )

    {server, task_supervisor}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp deployment_call(server, input, timeout) do
    apply(DSExDeployment.ProgramServer, :call, [server, input, timeout])
  end
end

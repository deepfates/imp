defmodule Imp.CurrentDSPyTimeoutBoundaryTest do
  use ExUnit.Case, async: false

  @example_root Path.expand("../examples/deployment", __DIR__)

  Code.require_file(Path.join(@example_root, "lib/imp_deployment/callbacks.ex"))
  Code.require_file(Path.join(@example_root, "lib/imp_deployment/support_pipeline.ex"))
  Code.require_file(Path.join(@example_root, "lib/imp_deployment/workflow.ex"))
  Code.require_file(Path.join(@example_root, "lib/imp_deployment/program_server.ex"))

  @moduletag :evidence_infrastructure

  test "timed-out Imp work is killed while current DSPy asyncify abandons its thread" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "imp-timeout-boundary-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(marker) end)

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: make_ref()))

    executor = fn _program, _lm, input ->
      Process.sleep(input.delay_ms)
      if input.marker, do: File.write!(input.marker, "late side effect\n")
      {:ok, :healthy}
    end

    server =
      start_supervised!(
        Supervisor.child_spec(
          {ImpDeployment.ProgramServer,
           name: nil,
           program: :fixture,
           lm: nil,
           executor: executor,
           task_supervisor: task_supervisor},
          id: make_ref()
        )
      )

    assert {:error, :timeout} =
             ImpDeployment.ProgramServer.call(
               server,
               %{delay_ms: 200, marker: marker},
               25
             )

    assert {:ok, :healthy} =
             ImpDeployment.ProgramServer.call(
               server,
               %{delay_ms: 0, marker: nil},
               100
             )

    Process.sleep(250)
    refute File.exists?(marker)
    assert Process.alive?(server)

    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-current-venv/bin/python")
    target = Path.join(root, "tmp/dspy-current-target")

    {stdout, 0} =
      System.cmd(
        python,
        ["scripts/current_dspy_timeout_boundary.py", "--dspy-target", target],
        env: [{"PYTHONPATH", ""}]
      )

    dspy = Jason.decode!(stdout)

    assert dspy["dspy_version"] == "3.3.0b1"
    assert dspy["primitive"] == "dspy.asyncify + asyncio.wait_for"
    assert dspy["async_max_workers"] == 1
    assert dspy["caller_timed_out"]
    assert dspy["healthy_call_succeeded"]
    assert dspy["timed_out_worker_side_effect_observed"]
    assert dspy["timeout_elapsed_ms"] < 150
    assert dspy["healthy_elapsed_ms"] < 100

    assert dspy["scope"] == %{
             "http_server_exercised" => false,
             "provider_calls" => 0,
             "provider_transport_cancellation_claimed" => false
           }
  end
end

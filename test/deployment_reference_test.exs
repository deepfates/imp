defmodule DeploymentReferenceTest do
  use ExUnit.Case, async: false

  @example_root Path.expand("../examples/deployment", __DIR__)

  Code.require_file(Path.join(@example_root, "lib/imp_deployment/callbacks.ex"))
  Code.require_file(Path.join(@example_root, "lib/imp_deployment/support_pipeline.ex"))
  Code.require_file(Path.join(@example_root, "lib/imp_deployment/workflow.ex"))
  Code.require_file(Path.join(@example_root, "lib/imp_deployment/program_server.ex"))
  Code.require_file(Path.join(@example_root, "lib/imp_deployment/application.ex"))

  test "the routing predictor consumes the analysis predictor output" do
    test_pid = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = Enum.map_join(messages, "\n", & &1.content)

          if String.contains?(rendered, "`team`") do
            send(test_pid, {:routing_messages, rendered})
            %{team: "beacon", urgency: "high"}
          else
            %{analysis: "stage-one-account-security-sentinel"}
          end
        end
      )

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn ->
               Imp.call(ImpDeployment.Workflow.program(), %{ticket: "Account access issue"})
             end)

    assert_receive {:routing_messages, rendered}
    assert rendered =~ "stage-one-account-security-sentinel"
    assert Imp.get(prediction, :team) == "beacon"

    assert prediction.metadata.support_pipeline == %{
             analysis: "stage-one-account-security-sentinel",
             stages: [:analyze, :route]
           }
  end

  test "ordinary workflow compiles, inspects, persists, hot-reloads, and contains failures" do
    artifact =
      Path.join(
        System.tmp_dir!(),
        "imp-deployment-workflow-#{System.unique_integer([:positive])}.json"
      )

    result_path = artifact <> ".result"

    invalid = artifact <> ".invalid"
    incompatible = artifact <> ".incompatible"

    on_exit(fn ->
      File.rm(artifact)
      File.rm(result_path)
      File.rm(invalid)
      File.rm(incompatible)
    end)

    base = ImpDeployment.Workflow.program()
    assert {:ok, checked} = ImpDeployment.Workflow.check()
    assert checked.selected == :optimized
    assert checked.baseline_selection.score == 0.25
    assert checked.optimized_selection.score == 1.0
    assert checked.test.score == 1.0

    parameters = ImpDeployment.Workflow.selected_parameters(checked.program)
    demo_parameters = Enum.filter(parameters, &(&1["kind"] == "demos"))
    assert length(demo_parameters) == 2
    assert Enum.all?(demo_parameters, &(length(&1["value"]) == 4))
    assert Enum.all?(parameters, &is_binary(&1["digest"]))

    server =
      start_program_runtime(base, ImpDeployment.Workflow.static_lm(), max_children: 4)

    assert {:ok, before_reload} =
             deployment_call(server, %{ticket: "The API is down for every customer"}, 1_000)

    assert Imp.get(before_reload, :team) == "atlas"

    :ok = Imp.Experiment.Result.write!(checked, result_path)
    :ok = Imp.Optimizer.Artifact.write!(checked.artifact, artifact)
    stored = Imp.Experiment.Result.read!(result_path)
    loaded_artifact = Imp.Optimizer.Artifact.read!(artifact)
    assert stored["payload"]["artifact"] == loaded_artifact

    loaded_selected =
      Imp.Optimizer.Artifact.apply(loaded_artifact, ImpDeployment.Workflow.program())

    assert ImpDeployment.Workflow.selected_parameters(loaded_selected) == parameters
    assert :ok = ImpDeployment.ProgramServer.reload_parameters(server, artifact)

    concurrent =
      1..4
      |> Enum.map(fn index ->
        Task.async(fn ->
          deployment_call(server, %{ticket: "Request #{index}: refund the invoice"}, 1_000)
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.all?(concurrent, fn {:ok, prediction} -> Imp.get(prediction, :team) == "atlas" end)

    File.write!(invalid, ~s({"not":"an Imp artifact"}))

    assert {:error, {:invalid_artifact, _reason}} =
             ImpDeployment.ProgramServer.reload_parameters(server, invalid)

    incompatible_program =
      Imp.optimize!(
        Imp.predict("question -> answer"),
        Imp.Optimizer.LabeledFewShot.new(k: 0),
        []
      )

    incompatible_program
    |> Imp.Optimizer.Artifact.from_optimized_program()
    |> Imp.Optimizer.Artifact.write!(incompatible)

    assert {:error, {:invalid_artifact, reason}} =
             ImpDeployment.ProgramServer.reload_parameters(server, incompatible)

    assert reason =~ "predictor set is incompatible"

    assert {:ok, still_selected} =
             deployment_call(server, %{ticket: "A leaked password still works"}, 1_000)

    assert Imp.get(still_selected, :team) == "beacon"

    assert {:error, {:worker_crash, :killed}} =
             deployment_call(server, %{ticket: "IMP_DEMO_CRASH"}, 1_000)

    assert {:error, :timeout} =
             deployment_call(server, %{ticket: "IMP_DEMO_HANG"}, 25)

    assert Process.alive?(server)

    assert {:ok, after_failures} =
             deployment_call(server, %{ticket: "Where are the import docs?"}, 1_000)

    assert Imp.get(after_failures, :team) == "quill"
  end

  test "fixed outer repetitions select the better expected two-stage program and load fresh" do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-deployment-repetitions-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    [train | _] = ImpDeployment.Workflow.trainset()
    [selection | _] = ImpDeployment.Workflow.selection_set()
    [test | _] = ImpDeployment.Workflow.testset()

    data = Imp.Experiment.Data.new(train: [train], selection: [selection], test: [test])
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 1, sample: false)

    single_state =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{baseline: 0, optimized: 0} end},
          id: make_ref()
        )
      )

    assert {:ok, single} =
             Imp.context([lm: noisy_routing_lm(single_state)], fn ->
               Imp.Experiment.check(
                 ImpDeployment.Workflow.program(),
                 optimizer,
                 data,
                 &ImpDeployment.Workflow.metric/2
               )
             end)

    assert single.selected == :baseline
    assert single.baseline_selection.score == 1.0
    assert single.optimized_selection.score == 0.0
    assert single.repetition_summary == nil

    repeated_state =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{baseline: 0, optimized: 0} end},
          id: make_ref()
        )
      )

    assert {:ok, repeated} =
             Imp.context([lm: noisy_routing_lm(repeated_state)], fn ->
               Imp.Experiment.check(
                 ImpDeployment.Workflow.program(),
                 optimizer,
                 data,
                 &ImpDeployment.Workflow.metric/2,
                 artifact_id: "repeated-selected",
                 compare_baseline_on_test: true,
                 evaluation_options: [repetitions: 3, aggregation: :mean]
               )
             end)

    assert repeated.selected == :optimized
    assert_in_delta repeated.baseline_selection.score, 1 / 3, 1.0e-12
    assert_in_delta repeated.optimized_selection.score, 2 / 3, 1.0e-12
    assert repeated.repetition_summary.paired_deltas.selection == [-1.0, 1.0, 1.0]
    assert repeated.repetition_summary.paired_deltas.test == [-1.0, 1.0, 1.0]
    assert repeated.repetition_summary.outer_row_evaluations.total == 12

    result_path = Path.join(root, "result.json")
    artifact_path = Path.join(root, "artifact.json")
    receipt_path = Path.join(root, "fresh.json")
    :ok = Imp.Experiment.Result.write!(repeated, result_path)
    :ok = Imp.Optimizer.Artifact.write!(repeated.artifact, artifact_path)

    assert %{"schema_version" => 3, "payload" => payload} =
             Imp.Experiment.Result.read!(result_path)

    assert payload["artifact"] == Imp.Optimizer.Artifact.read!(artifact_path)
    assert payload["repetitions"]["outer_row_evaluations"]["total"] == 12

    support_pipeline = Path.join(@example_root, "lib/imp_deployment/support_pipeline.ex")

    code = """
    Code.require_file(#{inspect(support_pipeline)})
    artifact = Imp.Optimizer.Artifact.read!(#{inspect(artifact_path)})
    program = Imp.Optimizer.Artifact.apply(artifact, ImpDeployment.SupportPipeline.new())
    lm = Imp.LM.Static.new(handler: fn messages, _opts ->
      rendered = Enum.map_join(messages, "\\n", & &1.content)
      if String.contains?(rendered, "`team`") do
        %{team: "atlas", urgency: "normal"}
      else
        %{analysis: "fresh two-stage analysis"}
      end
    end)
    {:ok, prediction} = Imp.context([lm: lm], fn ->
      Imp.call(program, %{ticket: "Fresh invoice question"})
    end)
    File.write!(#{inspect(receipt_path)}, Jason.encode!(%{
      team: Imp.get(prediction, :team),
      champion: Imp.Optimizer.Artifact.inspect(artifact).champion_id
    }))
    """

    assert {"", 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
               cd: File.cwd!(),
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert %{"team" => "atlas", "champion" => "repeated-selected"} =
             receipt_path |> File.read!() |> Jason.decode!()
  end

  test "reference OTP server loads a checksummed registry-backed artifact and serves calls" do
    path =
      Path.join(System.tmp_dir!(), "imp-deployment-#{System.unique_integer([:positive])}.json")

    previous_path = System.get_env("IMP_ARTIFACT_PATH")
    previous_answer = System.get_env("IMP_STATIC_ANSWER")

    on_exit(fn ->
      File.rm(path)
      restore_env("IMP_ARTIFACT_PATH", previous_path)
      restore_env("IMP_STATIC_ANSWER", previous_answer)
    end)

    metric = fn _example, prediction -> Imp.get(prediction, :answer, "") != "" end
    registry = Imp.Saving.Registry.new(quality_metric: metric)

    program =
      Imp.predict("question -> answer")
      |> Imp.Predict.BestOfN.new(metric, n: 2)

    assert :ok = Imp.save!(program, path, registry: registry)
    System.put_env("IMP_ARTIFACT_PATH", path)
    System.put_env("IMP_STATIC_ANSWER", "Paris")

    task_supervisor = start_supervised!({Task.Supervisor, max_children: 2})

    start_supervised!({ImpDeployment.ProgramServer, task_supervisor: task_supervisor})

    assert {:ok, prediction} =
             apply(ImpDeployment.ProgramServer, :call, [%{question: "Capital?"}])

    assert Imp.get(prediction, :answer) == "Paris"
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

    # The worker crashes immediately, so this call returns as soon as the DOWN is
    # observed — but under full-suite load the worker can take longer than a tight
    # 200ms window just to be scheduled, and the ProgramServer's own Task.yield
    # timeout would then brutal-kill it and report {:error, :timeout} instead of
    # the crash. A generous ceiling closes that window without slowing the test.
    # with_log contains the expected abnormal-exit report so it stays deterministic
    # under load. Ticket dee-n3sb.
    {result, _log} =
      ExUnit.CaptureLog.with_log(fn -> deployment_call(server, :crash, 5_000) end)

    assert result == {:error, {:worker_crash, :provider_crash}}
    assert Process.alive?(server)
  end

  test "concurrent calls preserve successful and returned structured error identities" do
    parse_error = %Imp.AdapterParseError{
      message: "strict chat marker was malformed",
      reason: :missing_output_marker
    }

    safety_error = %Imp.OperationalSafetyError{
      message: "input envelope exceeded",
      kind: :budget,
      reason: {:input_bytes, 9_001, 8_192}
    }

    executor = fn _program, _lm, input ->
      case input do
        :ok -> {:ok, Imp.Prediction.new(answer: "ok")}
        :parse -> {:error, parse_error}
        :safety -> {:error, safety_error}
      end
    end

    {server, _task_supervisor} = start_runtime(executor, max_children: 3)

    results =
      [:ok, :parse, :safety]
      |> Task.async_stream(&deployment_call(server, &1, 1_000),
        ordered: true,
        max_concurrency: 3,
        timeout: 1_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [
             {:ok, %Imp.Prediction{}},
             {:error, ^parse_error},
             {:error, ^safety_error}
           ] = results

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
      {ImpDeployment.ProgramServer,
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

    assert mix_file =~ ~s(elixir: "~> 1.19")
    assert mix_file =~ ~s({:imp, "~> 0.2"})
    assert mix_file =~ "IMP_PATH"
    assert readme =~ "bounded supervised task"
    assert readme =~ "IMP_MODEL"
    assert readme =~ "IMP_MAX_CONCURRENCY"
    assert readme =~ "two-stage Banking77"
    assert readme =~ "reload_parameters/1"
    assert readme =~ "starts a second OS process"
    assert readme =~ "fresh OS"
  end

  defp start_runtime(executor, opts \\ []) do
    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: Keyword.get(opts, :max_children, 2)})

    server =
      start_supervised!(
        {ImpDeployment.ProgramServer,
         name: nil,
         task_supervisor: task_supervisor,
         program: :program,
         lm: :lm,
         executor: executor}
      )

    {server, task_supervisor}
  end

  defp start_program_runtime(program, lm, opts) do
    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: Keyword.fetch!(opts, :max_children)})

    start_supervised!(
      {ImpDeployment.ProgramServer,
       name: nil, task_supervisor: task_supervisor, program: program, lm: lm}
    )
  end

  defp noisy_routing_lm(state) do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\n", & &1.content)

        if String.contains?(rendered, "`team`") do
          optimized? = Enum.any?(messages, &(Map.get(&1, :role) in [:assistant, "assistant"]))
          key = if optimized?, do: :optimized, else: :baseline

          index =
            Agent.get_and_update(
              state,
              &{Map.fetch!(&1, key), Map.update!(&1, key, fn n -> n + 1 end)}
            )

          correct? =
            Enum.at(
              if(optimized?, do: [false, true, true], else: [true, false, false]),
              rem(index, 3)
            )

          if correct?,
            do: %{team: "atlas", urgency: "normal"},
            else: %{team: "harbor", urgency: "high"}
        else
          %{analysis: "two-stage analysis"}
        end
      end
    )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp deployment_call(server, input, timeout) do
    apply(ImpDeployment.ProgramServer, :call, [server, input, timeout])
  end
end

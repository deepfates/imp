Application.ensure_all_started(:imp)

alias ImpDeployment.{ProgramServer, Workflow}

artifact_path =
  System.get_env("IMP_WORKFLOW_ARTIFACT_PATH") ||
    Path.join(
      System.tmp_dir!(),
      "imp-deployment-workflow-#{System.unique_integer([:positive])}.json"
    )

previous_env =
  for name <- ~w(IMP_ARTIFACT_PATH IMP_WORKFLOW_BASELINE IMP_STATIC_WORKFLOW IMP_MAX_CONCURRENCY),
      into: %{},
      do: {name, System.get_env(name)}

restore_env = fn ->
  Enum.each(previous_env, fn
    {name, nil} -> System.delete_env(name)
    {name, value} -> System.put_env(name, value)
  end)
end

try do
  lm = Workflow.static_lm()
  base = Workflow.program()
  candidate = Workflow.compile(base)

  base_selection = Workflow.evaluate(base, Workflow.selection_set(), lm)
  candidate_selection = Workflow.evaluate(candidate, Workflow.selection_set(), lm)

  selected =
    if candidate_selection.score > base_selection.score,
      do: candidate,
      else: base

  selected_prefix = if selected == candidate, do: :labeled_few_shot, else: :baseline
  untouched = Workflow.evaluate(selected, Workflow.testset(), lm)

  parameters = Workflow.selected_parameters(selected)
  demo_parameters = Enum.filter(parameters, &(&1["kind"] == "demos"))

  # The application reconstructs its trusted two-stage module, then replaces
  # only its checksummed selected parameters without restarting supervision.
  selected_artifact = Workflow.optimizer_artifact(selected)
  :ok = Imp.Optimizer.Artifact.write!(selected_artifact, artifact_path)
  System.put_env("IMP_ARTIFACT_PATH", artifact_path)
  System.put_env("IMP_WORKFLOW_BASELINE", "1")
  System.put_env("IMP_STATIC_WORKFLOW", "1")
  System.put_env("IMP_MAX_CONCURRENCY", "4")
  {:ok, _started} = Application.ensure_all_started(:imp_deployment)

  {:ok, before_reload} = ProgramServer.call(%{ticket: "The API is down for every customer"})

  loaded_artifact = Imp.Optimizer.Artifact.read!(artifact_path)
  loaded = Imp.Optimizer.Artifact.apply(loaded_artifact, Workflow.program())
  true = Workflow.selected_parameters(loaded) == parameters
  :ok = ProgramServer.reload_parameters(artifact_path)

  concurrent =
    1..4
    |> Enum.map(fn index ->
      Task.async(fn -> ProgramServer.call(%{ticket: "Request #{index}: refund the invoice"}) end)
    end)
    |> Task.await_many(5_000)

  true = Enum.all?(concurrent, &match?({:ok, _prediction}, &1))

  crash = ProgramServer.call(%{ticket: "IMP_DEMO_CRASH"})
  timeout = ProgramServer.call(%{ticket: "IMP_DEMO_HANG"}, 25)
  {:ok, after_failures} = ProgramServer.call(%{ticket: "A leaked password still works"})

  true = Process.alive?(Process.whereis(ProgramServer))
  true = Imp.get(before_reload, :team) == "atlas"
  true = Imp.get(after_failures, :team) == "beacon"
  true = match?({:error, {:worker_crash, :killed}}, crash)
  true = timeout == {:error, :timeout}

  IO.inspect(
    %{
      selection: %{baseline: base_selection.score, candidate: candidate_selection.score},
      selected_prefix: selected_prefix,
      untouched_score: untouched.score,
      selected_predictors: Enum.map(demo_parameters, & &1["id"]),
      selected_demo_count: Enum.sum(Enum.map(demo_parameters, &length(&1["value"]))),
      selected_parameter_digests: Map.new(parameters, &{&1["id"], &1["digest"]}),
      concurrent_calls: length(concurrent),
      contained_failure: crash,
      contained_cancellation: timeout,
      post_failure_team: Imp.get(after_failures, :team)
    },
    label: "Imp OTP workflow"
  )

  IO.puts("Imp OTP workflow passed: selection 0.25 -> 1.0, untouched 1.0")
after
  Application.stop(:imp_deployment)

  unless System.get_env("IMP_WORKFLOW_KEEP_ARTIFACT") == "1" do
    File.rm(artifact_path)
  end

  restore_env.()
end

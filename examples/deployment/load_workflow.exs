Application.ensure_all_started(:imp)

alias ImpDeployment.ProgramServer

artifact_path = System.fetch_env!("IMP_WORKFLOW_ARTIFACT_PATH")
result_path = System.fetch_env!("IMP_WORKFLOW_RESULT_PATH")
artifact = Imp.Optimizer.Artifact.read!(artifact_path)
stored = Imp.Experiment.Result.read!(result_path)
true = stored["payload"]["artifact"] == artifact
program = Imp.Optimizer.Artifact.apply(artifact, ImpDeployment.Workflow.program())
parameters = ImpDeployment.Workflow.selected_parameters(program)

demo_parameters = Enum.filter(parameters, &(&1["kind"] == "demos"))
true = length(demo_parameters) == 2
true = Enum.all?(demo_parameters, &(length(&1["value"]) == 4))

System.put_env("IMP_ARTIFACT_PATH", artifact_path)
System.put_env("IMP_WORKFLOW_BASELINE", "1")
System.put_env("IMP_STATIC_WORKFLOW", "1")
System.put_env("IMP_MAX_CONCURRENCY", "4")
{:ok, _started} = Application.ensure_all_started(:imp_deployment)
:ok = ProgramServer.reload_parameters(artifact_path)

predictions =
  1..4
  |> Enum.map(fn _index ->
    Task.async(fn ->
      ProgramServer.call(%{ticket: "The API is down for every customer"})
    end)
  end)
  |> Task.await_many(5_000)

true = Enum.all?(predictions, &match?({:ok, _prediction}, &1))

true =
  Enum.all?(predictions, fn {:ok, prediction} ->
    Imp.get(prediction, :team) == "harbor" and Imp.get(prediction, :urgency) == "high"
  end)

:ok = Application.stop(:imp_deployment)

IO.puts(
  "Imp OTP workflow fresh-process service passed: linked result/artifact, 4 concurrent harbor/high calls with 2 predictors x 4 demos"
)

Application.ensure_all_started(:imp)

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

{:ok, prediction} =
  Imp.context([lm: ImpDeployment.Workflow.static_lm()], fn ->
    Imp.call(program, %{ticket: "The API is down for every customer"})
  end)

true = Imp.get(prediction, :team) == "harbor"
true = Imp.get(prediction, :urgency) == "high"

IO.puts(
  "Imp OTP workflow fresh-process load passed: linked result/artifact, harbor/high with 2 predictors x 4 demos"
)

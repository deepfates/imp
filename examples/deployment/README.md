# Serve an optimized Imp program under OTP

This example is for the point after you have a useful Imp program and want to
run it as part of an application. It shows how to keep trusted program code in
your release, load selected parameters from an artifact, and serve concurrent
calls without turning a slow or failed model request into a blocked GenServer.

The example program has two stages:

1. `analyze` extracts the signal that matters from a support ticket.
2. `route` uses the ticket and that analysis to choose a team and urgency.

Both stages are ordinary `Imp.predict/2` programs inside an application-owned
struct implementing `Imp.Module`. The named predictor callbacks let an
optimizer update either stage without taking ownership of the surrounding
application code.

## Run the complete workflow without a provider

From this directory in a source checkout or unpacked Hex artifact:

```sh
IMP_PATH=../.. mix deps.get
IMP_PATH=../.. mix run --no-start run_workflow.exs
```

After Imp is published, a copied application can omit `IMP_PATH` and resolve
the declared Hex dependency normally.

The workflow:

1. constructs the two-stage program;
2. gives `Imp.Experiment.check/5` separate training, selection, and test rows;
3. uses `LabeledFewShot` to attach demonstrations to both predictors;
4. selects between the original and optimized programs on validation data;
5. builds the selected artifact before reading the test set;
6. writes the linked `Imp.Experiment.Result` and
   `Imp.Optimizer.Artifact` with private file permissions;
7. starts `ImpDeployment.ProgramServer` with trusted application code;
8. hot-reloads the selected parameters;
9. serves four calls concurrently; and
10. contains one crashed call and one timed-out call before serving again.

It then stops the in-process service and starts a second OS process. That fresh
process reads the result and artifact, reconstructs the trusted program,
reapplies the selected parameters, starts `ProgramServer`, and serves four
concurrent predictions before the parent removes its temporary files.

To inspect or reuse the exact files instead of removing them, choose private
paths and set the retention flag:

```sh
IMP_PATH=../.. \
IMP_WORKFLOW_ARTIFACT_PATH="$PWD/private-selected-artifact.json" \
IMP_WORKFLOW_RESULT_PATH="$PWD/private-experiment-result.json" \
IMP_WORKFLOW_KEEP_ARTIFACT=1 \
mix run --no-start run_workflow.exs
```

Both files are written with mode `0600`. The workflow refuses an incompatible
Result/Artifact pair before applying parameters.

The scripted model has planted routing rules, so the deterministic selection
score moves from `0.25` to `1.0`. That number proves the application lifecycle,
not model effectiveness. Replace the scripted model and datasets before using
this example to make a claim about your own task.

## The application owns code; the artifact owns selected parameters

`ImpDeployment.SupportPipeline` remains normal source code in the release. The
artifact contains the selected instructions, demonstrations, and optimizer
report for its named predictors. It contains no provider credentials or
application callbacks.

At startup the application:

1. constructs the trusted program;
2. reads and verifies the checksummed artifact;
3. binds live model clients and callbacks from application configuration; and
4. applies the artifact to the matching named predictors.

This division keeps serialized model output from becoming executable
application code. A corrupt or incompatible artifact returns
`{:error, {:invalid_artifact, reason}}` and leaves the current program serving.

## The server does not hold slow calls in its mailbox

`ImpDeployment.ProgramServer` owns the current immutable program value. Each
request borrows a snapshot and runs in a bounded supervised task, so unrelated
calls can proceed concurrently.

Configure the live application with environment variables:

```sh
IMP_ARTIFACT_PATH=/secure/program.json \
IMP_MODEL=provider:model-id \
IMP_API_KEY=... \
mix run --no-halt
```

`IMP_MAX_CONCURRENCY` defaults to the number of online schedulers. Calls above
the limit return `{:error, :overloaded}`. Timed-out calls return
`{:error, :timeout}` and their worker is terminated. `IMP_SHUTDOWN_TIMEOUT`
controls how long shutdown waits for calls already in flight.

`ProgramServer.reload_parameters/1` verifies and applies a new parameter
artifact before swapping server state. Calls already running keep their old
program snapshot; later calls see the new one. `reload/1` is the corresponding
whole-program operation for Imp's built-in portable program shapes.

## Research case studies stay separate from the deployment template

The source repository retains real-provider Banking77 and HotPotQA runs,
including clean negative optimizer outcomes and their exact artifacts. They are
research records rather than dependencies of this application template, so
they are not shipped in the Hex package. See the repository's
[deployment research directory](https://github.com/deepfates/imp/tree/main/examples/deployment)
when you need those scoped results. The packaged workflow above remains the
canonical executable example of selection, private persistence, restart, hot
reload, concurrency, and failure containment.

## Build a whole-program artifact when parameters are not enough

Imp can also serialize its built-in portable program shapes. Create that
artifact in an application-owned release task where callbacks are reviewed:

```elixir
metric = fn _example, prediction -> Imp.get(prediction, :answer, "") != "" end
registry = Imp.Saving.Registry.new(quality_metric: metric)

program =
  Imp.predict("question -> answer")
  |> Imp.Predict.BestOfN.new(metric, n: 2)

:ok = Imp.save!(program, "/secure/program.json", registry: registry)
```

Use a whole-program artifact for a supported portable Imp shape. Use
`Imp.Optimizer.Artifact` when the application owns a custom program and only
its selected predictor parameters should cross the persistence boundary.

During source development set `IMP_PATH` to the Imp checkout. A published
application will use the normal package dependency after Imp is released on
Hex.

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

From this directory in a source checkout:

```sh
IMP_PATH=../.. mix deps.get
IMP_PATH=../.. mix run --no-start run_workflow.exs
```

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

It then starts a second OS process, reads the result and artifact, reconstructs
the trusted program, reapplies the selected parameters, and makes another
prediction.

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
IMP_MODEL=openai:gpt-4.1-mini \
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

## A real-model run shows why selection matters

`banking77_gepa.exs` runs the same public path with a two-stage Banking77
program, GPT-5.4 Mini for the task, and Claude Sonnet 4.6 for GEPA reflection:

```sh
OPENROUTER_API_KEY=... \
IMP_PATH=../.. \
mix run --no-start banking77_gepa.exs
```

The retained run is an honest negative result. The baseline scored `0.25` on
selection and the proposed program scored `0.125`, so
`Imp.Experiment.check/5` retained the baseline. The selected program then
scored `0.275` on 40 untouched rows with no parse errors, loaded in a fresh OS
process, and served four concurrent calls.

The exact [`Result`](banking77-gepa-exercised-result.json) and
[`Artifact`](banking77-gepa-selected-artifact.json) are retained beside the
example. This result does not show that GEPA is ineffective in general. It
shows the behavior an application needs when an optimizer makes the program
worse: choose on validation data, retain the better program, and deploy the
selected artifact normally.

The script has fixed data sizes, model routes, optimizer limits, no retries or
fallbacks, and a conservative maximum of 328 task calls plus two optimizer
calls. It checks provider identity, privacy, and price before making a call.
Those checks bound this example; they are not a second deployment framework.

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

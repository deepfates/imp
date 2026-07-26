# Imp OTP Deployment Reference

This application loads a checksummed Imp artifact during supervised startup,
rebinds named callbacks from trusted application code, and serves calls through
bounded supervised tasks. The `ProgramServer` owns the loaded artifact and runtime
configuration, but provider calls execute concurrently outside its mailbox so a
slow request does not block unrelated callers. Production uses `IMP_MODEL` and
`IMP_API_KEY`; smoke tests can set `IMP_STATIC_ANSWER` instead.

## Run The Complete Provider-Free Workflow

The shortest product walkthrough starts with an ordinary typed support-routing
program and finishes inside the supervised server. From this directory in a
source checkout:

```sh
IMP_PATH=../.. mix deps.get
IMP_PATH=../.. mix run --no-start run_workflow.exs
```

The script performs one coherent lifecycle:

1. declares an application-owned two-predictor program: `analyze` produces a
   typed intermediate value and `route` consumes it to produce validated team
   and urgency classifications;
2. measures the baseline on a selection split, compiles four demonstrations
   per predictor with `LabeledFewShot`, and keeps the candidate only when
   selection improves;
3. evaluates the selected program on a separate untouched split;
4. prints selected parameter IDs and content digests, including the four
   reviewable demonstrations;
5. writes and reads a checksummed parameter artifact, reconstructs the trusted
   application module, starts OTP on the baseline, then hot-reloads both
   predictors' selected parameters without restarting it;
6. serves four concurrent calls in bounded supervised tasks; and
7. forces one worker crash and one timeout, then proves the same server still
   handles the next request.

The expected deterministic teaching-fixture scores are selection `0.25 -> 1.0`
and untouched `1.0`. The static LM contains planted routing rules that activate
when demonstrations are rendered. Those scores prove the evaluation,
compilation, parameter, persistence, hot-reload, concurrency, and containment
mechanics; they do **not** show that `LabeledFewShot` improves a real model, a
natural task, or a user's data. Replace `ImpDeployment.Workflow.static_lm/0`
and the three disjoint datasets before making an effectiveness claim.

```sh
IMP_ARTIFACT_PATH=/secure/program.json \
IMP_MODEL=openai:gpt-4.1-mini \
IMP_API_KEY=... \
mix run --no-halt
```

`IMP_MAX_CONCURRENCY` defaults to the number of online schedulers. Calls above
that limit return `{:error, :overloaded}`; timed-out calls return
`{:error, :timeout}` and their worker is terminated. `IMP_SHUTDOWN_TIMEOUT`
controls how long application shutdown waits for in-flight workers and defaults
to 5000 milliseconds.

`ImpDeployment.ProgramServer.reload_parameters/1` verifies a checksummed
optimizer artifact and applies it to the trusted application-owned program
before swapping server state. Calls already in flight keep the old immutable
program snapshot; subsequent calls see both selected predictors. A corrupt,
tampered, or incompatible artifact returns `{:error, {:invalid_artifact, reason}}`
and leaves the current program serving. `reload/1` remains the corresponding
whole-program path for built-in portable Imp program shapes.

The package clean-room gate runs this workflow against the unpacked Hex
artifact, stops the first OS process, then starts a second `mix run` process to
load and call the retained selected program. That is the cold persistence
boundary; the static LM remains only a deterministic runtime binding.

During source development, set `IMP_PATH` to the Imp checkout. Published
applications omit it and resolve the Hex dependency once Imp is published
to Hex (publication is still pending; until then `IMP_PATH` is the working
path).

## Prepare An Artifact

Create the portable artifact before starting the release. This code belongs in
an application-owned release task or deployment pipeline, where the quality
metric and callback registry are reviewed along with the program:

```elixir
metric = fn _example, prediction -> Imp.get(prediction, :answer, "") != "" end
registry = Imp.Saving.Registry.new(quality_metric: metric)

program =
  Imp.predict("question -> answer")
  |> Imp.Predict.BestOfN.new(metric, n: 2)

:ok = Imp.save!(program, "/secure/program.json", registry: registry)
```

Start the application with an artifact and live credentials from the host
environment. The process never reads credentials from the serialized artifact:

```sh
IMP_ARTIFACT_PATH=/secure/program.json \
IMP_MODEL=openai:gpt-4.1-mini \
IMP_API_KEY=... \
mix run --no-halt
```

For a source-checkout smoke run, set `IMP_PATH` to this repository and use
`IMP_STATIC_ANSWER=Paris`. That setting bypasses the provider only for the
smoke path; it is not a production configuration.

## Optimizer Artifacts

`Imp.Optimizer.Artifact` stores checksummed champion and challenger parameter
states without runtime credentials or callback functions. Load an artifact and
apply its champion to an already configured live program with
`ImpDeployment.OptimizerArtifacts.load_apply_and_preserve/3`. Promotion and
rollback update the artifact atomically while preserving the previous champion
in revision history.

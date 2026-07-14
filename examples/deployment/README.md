# Imp OTP Deployment Reference

This application loads a checksummed Imp artifact during supervised startup,
rebinds named callbacks from trusted application code, and serves calls through
bounded supervised tasks. The `ProgramServer` owns the loaded artifact and runtime
configuration, but provider calls execute concurrently outside its mailbox so a
slow request does not block unrelated callers. Production uses `IMP_MODEL` and
`IMP_API_KEY`; smoke tests can set `IMP_STATIC_ANSWER` instead.

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

During source development, set `IMP_PATH` to the Imp checkout. Published
applications omit it and resolve the Hex dependency.

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

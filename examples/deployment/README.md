# DSEx OTP Deployment Reference

This application loads a checksummed DSEx artifact during supervised startup,
rebinds named callbacks from trusted application code, and serves calls through
bounded supervised tasks. The `ProgramServer` owns the loaded artifact and runtime
configuration, but provider calls execute concurrently outside its mailbox so a
slow request does not block unrelated callers. Production uses `DSEX_MODEL` and
`DSEX_API_KEY`; smoke tests can set `DSEX_STATIC_ANSWER` instead.

```sh
DSEX_ARTIFACT_PATH=/secure/program.json \
DSEX_MODEL=openai:gpt-4.1-mini \
DSEX_API_KEY=... \
mix run --no-halt
```

`DSEX_MAX_CONCURRENCY` defaults to the number of online schedulers. Calls above
that limit return `{:error, :overloaded}`; timed-out calls return
`{:error, :timeout}` and their worker is terminated. `DSEX_SHUTDOWN_TIMEOUT`
controls how long application shutdown waits for in-flight workers and defaults
to 5000 milliseconds.

During source development, set `DSEX_PATH` to the DSEx checkout. Published
applications omit it and resolve the Hex dependency.

## Prepare An Artifact

Create the portable artifact before starting the release. This code belongs in
an application-owned release task or deployment pipeline, where the quality
metric and callback registry are reviewed along with the program:

```elixir
metric = fn _example, prediction -> DSEx.get(prediction, :answer, "") != "" end
registry = DSEx.Saving.Registry.new(quality_metric: metric)

program =
  DSEx.predict("question -> answer")
  |> DSEx.Predict.BestOfN.new(metric, n: 2)

:ok = DSEx.save!(program, "/secure/program.json", registry: registry)
```

Start the application with an artifact and live credentials from the host
environment. The process never reads credentials from the serialized artifact:

```sh
DSEX_ARTIFACT_PATH=/secure/program.json \
DSEX_MODEL=openai:gpt-4.1-mini \
DSEX_API_KEY=... \
mix run --no-halt
```

For a source-checkout smoke run, set `DSEX_PATH` to this repository and use
`DSEX_STATIC_ANSWER=Paris`. That setting bypasses the provider only for the
smoke path; it is not a production configuration.

## Optimizer Artifacts

`DSEx.Optimizer.Artifact` stores checksummed champion and challenger parameter
states without runtime credentials or callback functions. Load an artifact and
apply its champion to an already configured live program with
`DSExDeployment.OptimizerArtifacts.load_apply_and_preserve/3`. Promotion and
rollback update the artifact atomically while preserving the previous champion
in revision history.

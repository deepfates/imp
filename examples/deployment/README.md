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

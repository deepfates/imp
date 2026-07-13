# DSEx OTP Deployment Reference

This application loads a checksummed DSEx artifact during supervised startup,
rebinds named callbacks from trusted application code, and serves calls through
a GenServer. Production uses `DSEX_MODEL` and `DSEX_API_KEY`; smoke tests can set
`DSEX_STATIC_ANSWER` instead.

```sh
DSEX_ARTIFACT_PATH=/secure/program.json \
DSEX_MODEL=openai:gpt-4.1-mini \
DSEX_API_KEY=... \
mix run --no-halt
```

During source development, set `DSEX_PATH` to the DSEx checkout. Published
applications omit it and resolve the Hex dependency.

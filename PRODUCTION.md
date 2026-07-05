# Production Readiness Gate

This repo is not considered production-ready unless all of these pass from a
clean tree:

```sh
mix production.check
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

The deterministic gate runs:

- formatting check
- compilation with warnings as errors
- generated upstream public export parity check
- full non-live test suite

The live gate uses local `.env` credentials and validates a real
OpenAI-compatible provider call.

## Upstream Parity

The public upstream export snapshot lives at
`priv/parity/upstream_public_exports.json` and is regenerated with:

```sh
mix parity.generate
```

`mix parity.check` fails if any upstream public export in that snapshot is not
classified in `PARITY.md`.

# Production Readiness Gate

This repo is not considered production-ready unless all of these pass from a
clean tree and [PRODUCTION_AUDIT.md](PRODUCTION_AUDIT.md) has no `PARTIAL` or
`UNPROVEN` P0/P1 rows:

```sh
mix production.check
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

The deterministic gate runs:

- formatting check
- compilation with warnings as errors
- generated upstream public export parity check
- production audit structural check
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

## Current Audit Status

`mix production.check` writes
`priv/parity/production_audit_unproven.json`. That file reports how many P0/P1
audit rows still need stronger evidence before the project can honestly be
called production-ready.

## V2 Production Bar

Production-ready V2 is tracked separately in [V2_ROADMAP.md](V2_ROADMAP.md).
V2 is not complete until every P0/P1 V2 row is `PROVEN`, `mix v2.check` passes,
the existing production gate passes, and applicable live gates pass.

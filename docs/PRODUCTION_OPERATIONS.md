# Production Operations

This document is the release checklist for people who want to use or publish
this library seriously.

## Required Gates

Run from a clean tree:

```sh
mix production.check
mix v2.check
```

With live credentials:

```sh
set -a
. ./.env
set +a
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

## What The Gates Prove

`mix production.check` runs:

- format check
- compile with warnings as errors
- DSEx public surface check
- production audit check
- non-live test suite

`mix v2.check` runs:

- format check
- compile with warnings as errors
- V2 audit check
- V2-tagged tests

The live provider test proves a real OpenAI-compatible provider can execute the
basic program and structured-output path with local credentials.

## What The Gates Do Not Prove

They do not prove:

- every implementation detail from adjacent projects is copied
- every provider-specific feature is live-tested
- every future model response shape is supported
- credentials are safe if a local `.env` has leaked elsewhere

## Secret Handling

The library avoids persisting provider secrets in saved program JSON.

Security-sensitive defaults:

- saved HTTP LMs load with `api_key: nil`
- unknown external keys are not converted with `String.to_atom/1`
- agent traces redact common secret keys
- agents and ReAct/RLM support tool policies

Operational advice:

- never commit `.env`
- rotate keys that were pasted into logs, screenshots, or shared artifacts
- prefer short-lived provider keys for CI and demos
- use explicit `api_key:` or environment variables at runtime, not saved state

## Live Provider Setup

Typical `.env`:

```sh
OPENAI_API_KEY=...
OPENAI_MODEL=gpt-4o-mini
```

Run:

```sh
set -a
. ./.env
set +a
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

## Release Checklist

Before tagging:

1. `git status --short` is clean.
2. `mix production.check` passes.
3. `mix v2.check` passes.
4. Live provider gate passes, or release notes explicitly say it was skipped.
5. `PRODUCTION_AUDIT.md` has no `PARTIAL` or `UNPROVEN` P0/P1 rows.
6. `V2_ROADMAP.md` has no `PARTIAL` or `UNPROVEN` P0/P1 rows.
7. Docs and Livebooks match the current public API.

## Debugging Gates

Public surface failure:

```sh
mix public_surface.check
```

Audit failure:

```sh
mix production.audit
cat tmp/audit/production_audit_unproven.json
```

V2 failure:

```sh
mix v2.audit
cat tmp/audit/v2_audit_unproven.json
```

Provider failure:

- confirm `.env` is loaded
- confirm the provider model exists for the account
- run only the live test file first
- inspect contract tests before assuming provider behavior is a library bug

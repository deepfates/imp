# Production Operations

This document is the authoritative release gate contract for DSEx.

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
LIVE_PROVIDER=1 mix live.check
```

## What The Gates Prove

`mix production.check` runs:

- format check
- compile with warnings as errors
- the non-live test suite, including the public surface contract
- documentation generation with ExDoc

`mix v2.check` runs:

- format check
- compile with warnings as errors
- the deterministic suite with V2-tagged tests included
- V2 positive controls and negative controls, including reward-encoding
  program-optimization fixtures

The live provider tests prove a real OpenAI-compatible provider can execute:

- basic `Predict`
- schema-constrained JSON `Predict`
- `ChainOfThought` with required reasoning
- provider streaming through `DSEx.Streaming`
- `ReActV2` function-tool calls plus reserved `submit`
- orchestration wrappers over real calls: `Parallel`, `BestOfN`, and `Refine`
- `ProgramOfThought` planning followed by BEAM-safe sandbox execution

## What The Gates Do Not Prove

They do not prove:

- every possible provider feature or future model response shape
- every provider-specific feature is live-tested
- live training jobs, MCP servers, or external retriever services
- credentials are safe if a local `.env` has leaked elsewhere

## Secret Handling

The library avoids persisting provider secrets in saved program JSON.

Security-sensitive defaults:

- saved HTTP LMs load with `api_key: nil`
- custom provider `base_url:` values require explicit `api_key:` and do not
  silently bind ambient provider credentials
- default `:httpc` transport verifies TLS peer certificates
- unknown external keys are not converted with `String.to_atom/1`
- prediction, program, agent, ReAct, CodeAct, and RLM traces redact common
  secret keys and secret-shaped values
- agents and ReAct/RLM support tool policies

Operational advice:

- never commit `.env`
- rotate keys that were pasted into logs, screenshots, or shared artifacts
- prefer short-lived provider keys for CI and demos
- use explicit `api_key:` or environment variables at runtime, not saved state
- treat MCP, retriever, training, and provider URLs as trusted configuration;
  DSEx does not provide a network egress sandbox or private-IP SSRF guard

## Live Provider Setup

Typical `.env`:

```sh
OPENAI_API_KEY=...
OPENAI_MODEL=gpt-4o-mini
DSEX_TEST_MODE=live
```

Run:

```sh
set -a
. ./.env
set +a
LIVE_PROVIDER=1 mix live.check
```

## Release Checklist

Before tagging:

1. `git status --short` is clean.
2. `mix production.check` passes.
3. `mix v2.check` passes.
4. `LIVE_PROVIDER=1 mix live.check` passes, or release notes explicitly say it was skipped.
5. Docs and Livebooks match the current public API.

## Debugging Gates

Public surface failure:

```sh
mix public_surface.check
```

V2 failure:

```sh
mix test --include v2
```

Provider failure:

- confirm `.env` is loaded
- confirm the provider model exists for the account
- run `LIVE_PROVIDER=1 mix live.check`
- inspect contract tests before assuming provider behavior is a library bug

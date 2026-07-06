# Production Operations

This document is the authoritative release gate contract for DSEx.

## Required Gates

Run from a clean tree:

```sh
mix production.check
mix v2.check
mix integration.check
mix quality.check
```

With live credentials:

```sh
set -a
. ./.env
set +a
LIVE_PROVIDER=1 mix live.check
```

Stateful or external-service gates are opt-in because they may create provider
resources, depend on private infrastructure, or talk to trusted MCP servers:

```sh
LIVE_TRAINING=1 mix live.training.check
LIVE_RETRIEVER=1 mix live.retriever.check
LIVE_MCP=1 mix live.mcp.check
```

## Runtime Posture

Production applications should run DSEx as an OTP application:

```elixir
Application.ensure_all_started(:dsex)
```

Normal Mix releases and applications start dependencies automatically. The
explicit call matters for embedded scripts, Livebook setup cells, and unusual
host runtimes. DSEx keeps lazy-start fallbacks for ergonomics, but the release
posture is supervised startup.

Supervised DSEx runtime state:

- `DSEx.Settings` owns global defaults. Prefer `DSEx.context/2` for scoped
  overrides in concurrent code and tests.
- `DSEx.Cache` owns the ETS table used by the built-in response cache.
- `DSEx.TaskSupervisor` owns DSEx async helpers, including provider async,
  agent event streaming, and parallel prediction fan-out through `DSEx.Tasks`.
- host applications still own higher-level orchestration lifetimes and
  cancellation policy.

Calling settings/cache APIs before `:dsex` is started attempts to start the
application, so lazy library use and supervised app use share the same ownership
path. Global settings are intentionally mutable and node-local. Use
`DSEx.context/2` for request, test, or task scoped overrides; those overrides
live in the calling process and are restored after the function returns.

Cache entries live in an ETS table owned by `DSEx.Cache`. A cache owner
crash/restart recreates the table and loses cached values by design.
`fetch_or_store/2` is best-effort under concurrent misses and does not provide
single-flight locking.

Provider access should normally use `DSEx.req_llm/2`, which delegates provider
catalogs, Req/Finch transport, streaming, structured-output negotiation, and
provider-specific option translation to `ReqLLM`. Use direct `DSEx.openai/2`
or `DSEx.Clients.HTTPLM` when you need a narrow OpenAI-compatible contract for
local servers, transport injection, or credential-binding regression tests.

Dependency policy:

- runtime dependencies must own a real operational boundary or a stable
  primitive DSEx should not reimplement;
- test/dev dependencies are encouraged when they strengthen contracts,
  property coverage, local integration harnesses, or static review without
  bloating production runtime;
- docs and gate claims must name which paths are live-proven, deterministic
  only, or reserved.

## What The Gates Prove

`mix production.check` runs:

- format check
- compile with warnings as errors
- the deterministic non-live, non-integration test suite, including the public
  surface contract
- documentation generation with ExDoc

`mix v2.check` runs:

- format check
- compile with warnings as errors
- the deterministic suite with V2-tagged tests included
- V2 positive controls and negative controls, including reward-encoding
  program-optimization fixtures

`mix integration.check` runs local-service end-to-end tests. It is reserved for
tests that may start local HTTP servers, local MCP processes, or other
controlled local infrastructure, but do not require paid provider credentials.
The current integration gate proves:

- save/load/rebind/deployed-call through a local OpenAI-compatible HTTP server
- generic HTTP retriever request and response mapping through a local server
- HTTP MCP initialize, discovery, and tool-call flow through a local JSON-RPC server
- stdio MCP discovery and tool-call flow through a trusted local executable

`mix quality.check` runs the static warning gate. CI must run it alongside the
deterministic release gates so style and maintainability regressions are caught
before merge, not only during local release preparation.

The live provider tests prove a real provider can execute:

- basic `Predict`
- JSON `Predict` with schema validation and retry feedback
- basic `Predict` through the ReqLLM-backed DSEx client
- `ChainOfThought` with required reasoning
- provider streaming through `DSEx.Streaming`
- `ReActV2` function-tool calls plus reserved `submit`
- orchestration wrappers over real calls: `Parallel`, `BestOfN`, and `Refine`
- `ProgramOfThought` planning followed by BEAM-safe sandbox execution

The stateful live aliases are opt-in gates. They are intentionally separate
from the default release gate because they may create provider resources, depend
on private infrastructure, or talk to trusted services. A release may only claim
one of these external systems is live-proven when the corresponding alias
contains real service tests:

- `mix live.training.check` proves provider-compatible training submit/refresh
  over the production HTTP transport and provider trainer/job lifecycle.
- `mix live.retriever.check` proves Weaviate-compatible and
  Databricks-compatible retriever requests over the production HTTP transport.
- `mix live.mcp.check` proves JSON-RPC HTTP, Streamable HTTP, and trusted
  stdio MCP clients through imported tool discovery and tool-call execution.

## What The Gates Do Not Prove

They do not prove:

- every possible provider feature or future model response shape
- every provider-specific feature is live-tested
- paid provider-side training jobs, external MCP servers, or external retriever
  services unless the matching opt-in live alias contains real service tests and
  is configured/run
- credentials are safe if a local `.env` has leaked elsewhere

## Secret Handling

The library avoids persisting provider secrets in saved program JSON.

Security-sensitive defaults:

- saved HTTP LMs load with `api_key: nil`
- custom provider `base_url:` values require explicit `api_key:` and do not
  silently bind ambient provider credentials
- provider clients use real transport by default; mock/fallback behavior
  requires explicit `DSEX_TEST_MODE` or `test_mode:` configuration
- Databricks vector-search retrievers require explicit `token:` for explicit
  endpoint URLs and do not silently bind ambient `DATABRICKS_TOKEN`
- default `:httpc` transport verifies TLS peer certificates
- default `:httpc` transport applies finite HTTP timeouts unless overridden
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

## Telemetry Events

DSEx emits redacted `:telemetry` events through `DSEx.Telemetry`.

Stable event families:

- `[:dsex, :lm, :start | :stop]`
- `[:dsex, :lm, :stream, :start | :chunk | :stop]`
- `[:dsex, :adapter, :parse, :retry | :error]`
- `[:dsex, :cache, :hit | :miss]`
- `[:dsex, :tool, :start | :stop | :exception]`
- `[:dsex, :retriever, :start | :stop | :exception]`
- `[:dsex, :mcp, :http | :stdio | :streamable_http, :start | :stop | :exception]`
- `[:dsex, :training, :submit | :refresh, :start | :stop | :exception]`
- `[:dsex, :optimizer, :trial, :start | :stop | :exception]`

Event metadata is redacted before dispatch. Secret-shaped values and common
secret keys are replaced with `[REDACTED]`.

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
LIVE_PROVIDER=1 mix live.check
```

## Release Checklist

Before tagging:

1. `git status --short` is clean.
2. `mix production.check` passes.
3. `mix v2.check` passes.
4. `mix integration.check` passes.
5. `LIVE_PROVIDER=1 mix live.check` passes, or release notes explicitly say it was skipped.
6. Any production claim about live training, external retrievers, or external
   MCP servers is backed by the corresponding opt-in live gate.
7. Docs and Livebooks match the current public API.

## Debugging Gates

Public surface failure:

```sh
mix public_surface.check
```

V2 failure:

```sh
mix test --include v2
```

Local integration failure:

```sh
mix integration.check
```

Provider failure:

- confirm `.env` is loaded
- confirm the provider model exists for the account
- run `LIVE_PROVIDER=1 mix live.check`
- inspect contract tests before assuming provider behavior is a library bug

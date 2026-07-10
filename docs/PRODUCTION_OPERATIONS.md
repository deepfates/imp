# Production Operations

This document is the authoritative source-checkout release gate contract for
DSEx.

It is the final chapter of the same manual path used by the README, API guide,
and Livebooks: after a DSEx program has a signature, examples, metrics,
optimization, and any needed tools, this page explains how maintainers prove the
repository and how applications run live providers without hiding credentials or
transport behavior.

## Required Gates

Run from a clean source checkout tree before shipping ordinary product changes:

```sh
mix production.check
mix integration.check
mix protocol.check
mix package.check
mix quality.check
```

When changing public examples, notebooks, or learning-material control flow in
the source checkout, also run the slower executable Livebook proof:

```sh
mix livebook.execute.check
```

With live provider credentials in the source checkout, run the opt-in provider
smoke gate:

```sh
set -a
. ./.env
set +a
LIVE_PROVIDER=1 mix live.check
```

Maintainer evidence for benchmarks and parity is separate from the production
gate. In a source checkout:

```sh
mix evidence.check
```

Use benchmark evidence when changing prompts, adapters, metrics, optimizers, or
claims about DSEx-vs-DSPy parity. Do not make paid live campaigns part of the
default product workflow.

## Runtime Posture

Production applications should run DSEx as an OTP application:

```elixir
Application.ensure_all_started(:dsex)
```

Normal Mix releases and applications start dependencies automatically. The
explicit call matters for embedded scripts, Livebook setup cells, and unusual
host runtimes. DSEx keeps lazy-start fallbacks only for script-style contexts
where the OTP application spec is unavailable. If the `:dsex` application is
available but fails to start, DSEx raises instead of creating shadow runtime
state outside supervision.

Supervised DSEx runtime state:

- `DSEx.Settings` owns global defaults. Prefer `DSEx.context/2` for scoped
  overrides in request code and tests. Plain BEAM tasks keep ordinary
  process-local semantics; DSEx-owned fan-out through `DSEx.Tasks`,
  `Parallel`, provider async, and agent event streams inherits the caller's
  DSEx context.
- `DSEx.Cache` owns the ETS table used by the built-in response cache.
- `DSEx.TaskSupervisor` owns linked DSEx async helpers, including provider
  async and parallel prediction fan-out through `DSEx.Tasks`.
- `DSEx.UnlinkedTaskSupervisor` owns unlinked event workers, including agent
  event streaming.
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

Provider access uses `DSEx.req_llm/2`, which delegates provider
catalogs, Req/Finch transport, streaming, structured-output negotiation, and
provider-specific option translation to `ReqLLM`. DSEx does not maintain a
parallel OpenAI-compatible provider client stack.

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
- the deterministic non-live, non-integration, non-protocol test suite
- package-boundary checks through `mix package.check`
- Livebook syntax validation through `mix livebook.check`
- clean documentation generation with ExDoc, so renamed modules or Livebooks
  cannot leave stale pages in the ignored `doc/` output directory

It intentionally does not run paid provider calls, dataset fetches, long
campaigns, or parity dashboards.

`mix livebook.execute.check` runs every shipped notebook. Keep it out of the
ordinary fast gate, but run it when changing public examples, notebook code, or
the learning path. With `OPENAI_API_KEY` and `OPENAI_MODEL` loaded, the same
command also executes the notebooks' live-provider proof cells.

`mix integration.check` runs local-service end-to-end tests. It is reserved for
tests that may start local HTTP servers, local MCP processes, or other
controlled local infrastructure, but do not require paid provider credentials.
The current integration gate proves:

- generic HTTP retriever request and response mapping through a local server
- HTTP MCP initialize, discovery, and tool-call flow through a local JSON-RPC server
- stdio MCP discovery and tool-call flow through a trusted local executable

`mix protocol.check` runs provider-compatible protocol tests over local
controlled endpoints. It proves DSEx's production HTTP/MCP/training/retriever
code paths and wire-shape handling, but it does not claim paid external service
state:

- `mix protocol.training.check` proves provider-compatible training
  submit/refresh over the production HTTP transport and provider trainer/job
  lifecycle.
- `mix protocol.retriever.check` proves Weaviate-compatible and
  Databricks-compatible retriever requests over the production HTTP transport.
- `mix protocol.mcp.check` proves JSON-RPC HTTP, Streamable HTTP with SSE
  decoding, and trusted stdio MCP clients through imported tool discovery and
  tool-call execution.

`mix quality.check` runs the static warning and dependency advisory gate:
Credo warning-level review plus Hex package audit. CI must run it alongside the
deterministic release gates so maintainability and known dependency risks are
caught before merge, not only during local release preparation.

`mix package.check` verifies the Hex package boundary. It checks that the
installable package contains product modules, docs, and Livebooks while
excluding local benchmark evidence tasks, Mix-only proof harnesses, and
test-only support.

In a source checkout, `mix evidence.check` runs deterministic maintainer
evidence. These commands are not shipped as package APIs:

Source-checkout maintainer aliases:

- benchmark truth fixture harness tests through `mix benchmark.truth.check`
- provider-free DSEx-vs-DSPy golden trace parity through
  `mix benchmark.trace.check`
- overhead checks through `mix benchmark.overhead.check`
- optimizer lift checks through `mix benchmark.optimizer_lift.check`
- GEPA paper-family artifact validation through
  `mix benchmark.gepa_replication.check`
- RAG/tool/agent checks through `mix benchmark.rag_tool_agent.check`
- operations stress checks through `mix benchmark.operations_stress.check`
- RLM recursive-controller benchmark checks through `mix benchmark.rlm.check`
- pinned executable upstream conformance through `mix upstream_fidelity.check`

The live provider tests prove a real provider can execute:

- basic `Predict`
- JSON `Predict` with schema validation and retry feedback
- basic `Predict` through the ReqLLM-backed DSEx client
- `ChainOfThought` with required reasoning
- provider streaming through `DSEx.Streaming`
- `ReAct` function-tool calls plus reserved `submit`
- orchestration wrappers over real calls: `Parallel`, `BestOfN`, and `Refine`
- `ProgramOfThought` planning followed by BEAM-safe sandbox execution

In a source checkout, `mix benchmark.live.check` is a separate research smoke
gate. It fetches fresh GSM8K and HotPotQA rows and runs DSEx programs over a
live provider, writing result artifacts under `benchmarks/results/`. It is
intentionally not part of the fast production gate because it spends provider
tokens and depends on external dataset and provider availability.

In a source checkout, `mix benchmark.parity.check` is a live smoke comparison:
it runs DSEx and the real Python DSPy package against the same rows and model
endpoint, then writes a parity artifact with score, latency, error, row-level
agreement, and evidence scale. It requires a local Python environment with
`dspy-ai` installed and live provider credentials. It proves wiring, not full
parity.

In a source checkout, `mix benchmark.parity.full` is the expensive evidence
lane. It fetches the full canonical GSM8K test and HotPotQA distractor
validation splits, uses current OpenAI-compatible model discovery when
`OPENAI_MODEL` is unset, and writes the same DSEx-vs-DSPy report schema over
the full row set. Use full-lane artifacts, not smoke runs, before making
production parity claims.

For long campaigns, use the parity task in chunks with `--offset` and
`--max-examples`, then aggregate the chunk artifacts with the parity aggregate
task. The campaign aggregate is the decisive artifact: it deduplicates
overlapping chunks by absolute row index, reports missing ranges, computes
weighted scores, refuses to mix historical provider paths, and refuses
`full_parity` unless the complete canonical row range is covered.

Use `--max-concurrency` on parity chunks or campaign runs to improve wall-clock
time without changing the evidence standard. Concurrency must be chosen within
provider rate limits and is recorded in chunk artifacts.

## What The Gates Do Not Prove

They do not prove:

- every possible provider feature or future model response shape
- every provider-specific feature is live-tested
- paid provider-side training jobs, external MCP servers, or external retriever
  services; `protocol.*` gates prove provider-compatible local protocol
  behavior, not account-specific external service state
- credentials are safe if a local `.env` has leaked elsewhere

## Secret Handling

The library avoids persisting provider secrets in saved program JSON.

Security-sensitive defaults:

- saved provider clients load without serialized credentials
- custom provider endpoint configuration must be explicit and must not silently
  bind ambient provider credentials
- provider clients use real transport by default; tests use injectable
  transports and ExUnit tags instead of hidden provider fallbacks
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
OPENAI_MODEL=...
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
3. `mix integration.check` passes.
4. `mix protocol.check` passes.
5. `mix quality.check` passes.
6. `LIVE_PROVIDER=1 mix live.check` passes, or release notes explicitly say it was skipped.
7. Any production claim about paid training, external retrievers, or external
   MCP servers is backed by dedicated external-service tests.
8. Docs and Livebooks match the current public API.

## Debugging Gates

Public surface failure:

```sh
mix public_surface.check
```

Maintainer evidence failure:

```sh
# source checkout only
mix evidence.check
```

Local integration failure:

```sh
mix integration.check
```

Protocol failure:

```sh
mix protocol.check
```

Provider failure:

- confirm `.env` is loaded
- confirm the provider model exists for the account
- run `LIVE_PROVIDER=1 mix live.check`
- inspect contract tests before assuming provider behavior is a library bug

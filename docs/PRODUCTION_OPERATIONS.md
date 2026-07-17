# Production Operations

This document covers consumer runtime operations and source-checkout validation
for Imp maintainers. Mix gate aliases mentioned here are available only in a
source checkout; they are not installed with the Hex package. The canonical
release procedure remains in repository-only maintainer documentation.

It is the final chapter of the same manual path used by the README, API guide,
and Livebooks: after an Imp program has a signature, examples, metrics,
optimization, and any needed tools, this page explains how applications run
live providers without hiding credentials or transport behavior.

## Runtime Posture

Production applications should run Imp as an OTP application:

```elixir
Application.ensure_all_started(:imp)
```

Normal Mix releases and applications start dependencies automatically. The
explicit call matters for embedded scripts, Livebook setup cells, and unusual
host runtimes. Imp keeps lazy-start fallbacks only for script-style contexts
where the OTP application spec is unavailable. If the `:imp` application is
available but fails to start, Imp raises instead of creating shadow runtime
state outside supervision.

Supervised Imp runtime state:

- `Imp.Settings` owns global defaults. Prefer `Imp.context/2` for scoped
  overrides in request code and tests. Plain BEAM tasks keep ordinary
  process-local semantics; Imp-owned fan-out through `Parallel`, provider async,
  and agent event streams inherits the caller's Imp context.
- `Imp.Cache` owns the ETS table used by the built-in response cache.
- supervised task owners hold linked async helpers, including provider async
  and parallel prediction fan-out.
- a separate unlinked worker owner handles agent event streaming.
- host applications still own higher-level orchestration lifetimes and
  cancellation policy.

Calling settings/cache APIs before `:imp` is started attempts to start the
application, so lazy library use and supervised app use share the same ownership
path. Global settings are intentionally mutable and node-local. Use
`Imp.context/2` for request, test, or task scoped overrides; those overrides
live in the calling process and are restored after the function returns.

Cache entries live in an ETS table owned by `Imp.Cache`. A cache owner
crash/restart recreates the table and loses cached values by design.
`fetch_or_store/2` coalesces concurrent misses per key while unrelated keys
continue independently. The owner monitors the active producer and promotes a
waiting caller after a producer crash; coalescing, retries, and producer
failures have dedicated redacted telemetry events.

Provider access uses `Imp.req_llm/2`, which delegates provider
catalogs, Req/Finch transport, streaming, structured-output negotiation, and
provider-specific option translation to `ReqLLM`. Imp does not maintain a
parallel OpenAI-compatible provider client stack.

Dependency policy:

- runtime dependencies must own a real operational boundary or a stable
  primitive Imp should not reimplement;
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
controlled endpoints. It proves Imp's production HTTP/MCP/training/retriever
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

`mix legacy_identity.check` scans tracked live and package-facing surfaces for
the retired identity, with only explicit historical benchmark/provenance
exceptions. `mix quality.check` runs that audit plus the static warning and
dependency advisory gate: Credo warning-level review plus Hex package audit.
CI must run these checks alongside the deterministic release gates so identity
drift, maintainability, and known dependency risks are caught before merge,
not only during local release preparation.

`mix package.check` verifies the Hex package boundary. It checks that the
installable package contains product modules, docs, and Livebooks while
excluding local benchmark evidence tasks, Mix-only proof harnesses, and
test-only support.

The deterministic source-checkout suite also executes the pinned Python DSPy
reference sidecars and reads the pinned GEPA artifact source registry. CI uses
DSPy `3.2.1` and `gepa-ai/gepa-artifact` commit
`cbefbc1aa0f43dd39874ec4bf42211365dbda42e`; changing either pin requires an
upstream-conformance review rather than an incidental dependency update.

In a source checkout, `mix evidence.check` runs deterministic maintainer
evidence. These commands are not shipped as package APIs:

Source-checkout maintainer aliases:

- benchmark truth harness tests through `mix benchmark.truth.check`
- provider-free Imp-vs-DSPy golden trace parity through
  `mix benchmark.trace.check`
- overhead checks through `mix benchmark.overhead.check`
- optimizer lift checks through `mix benchmark.optimizer_lift.check`
- GEPA paper-family artifact validation through
  `mix benchmark.gepa_replication.check`
- RAG/tool/agent checks through `mix benchmark.rag_tool_agent.check`
- matched provider-free RAG/tool failure traces through
  `mix benchmark.rag_tool_failure.check`
- repeated deterministic timeout, cancellation, backpressure, partial-stream,
  checkpoint, tamper, and leak checks through
  `mix benchmark.failure_campaign.check`
- RLM recursive-controller benchmark checks through `mix benchmark.rlm.check`
- pinned executable upstream conformance through `mix upstream_fidelity.check`

`mix benchmark.operations_stress.check` remains available as a test-only,
single-process diagnostic. It is intentionally excluded from `mix
evidence.check`: its timestamped JSON has no source-bound RunContext,
environment identity, or tamper envelope and must not be cited as C0-C5 claim
evidence. The underlying behaviors are enforced by ExUnit; source-bound
operational claims use the failure-recovery and overhead lanes.

The failure campaign writes normalized per-iteration outcomes and flake rates.
The default alias is T0 provider-free evidence. The compatibility `--live`
flag adds two local operational rows: bounded provider-shaped timeout and
idempotent retry, plus retriever recovery and an exact tool
failure/retry/submit trajectory. Neither mode contacts an external provider.

The live provider tests prove a real provider can execute:

- basic `Predict`
- JSON `Predict` with schema validation and retry feedback
- basic `Predict` through the ReqLLM-backed Imp client
- `ChainOfThought` with required reasoning
- provider streaming through `Imp.Streaming`
- `ReAct` function-tool calls plus reserved `submit`
- orchestration wrappers over real calls: `Parallel`, `BestOfN`, and `Refine`
- `ProgramOfThought` planning followed by BEAM-safe sandbox execution

In a source checkout, `mix benchmark.live.check` is a separate research smoke
gate. It fetches fresh GSM8K and HotPotQA rows and runs Imp programs over a
live provider, writing run artifacts under `benchmarks/runs/benchmark/`. It is
intentionally not part of the fast production gate because it spends provider
tokens and depends on external dataset and provider availability.

In a source checkout, `mix benchmark.parity.check` is a live smoke comparison:
it runs Imp and the real Python DSPy package against the same rows and model
endpoint, then writes a parity artifact with score, latency, error, row-level
agreement, and evidence scale. It requires a local Python environment with
`dspy-ai` installed and live provider credentials. It proves wiring, not full
parity.

In a source checkout, `mix benchmark.parity.full` is the expensive evidence
lane. It fetches the full canonical GSM8K test and HotPotQA distractor
validation splits, uses current OpenAI-compatible model discovery when
`OPENAI_MODEL` is unset, and writes the same Imp-vs-DSPy report schema over
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
- saved training-job checkpoints contain lifecycle state and checksums but no
  transport or API key; both must be reinjected explicitly on load
- dispatch journals serialize callers using the same path within one BEAM node,
  bind provider/model/endpoint/method semantics and job idempotency identity,
  and refuse credential-bearing job locators; their atomic rename and checksum
  cover ordinary process interruption, not adversarial writers, power loss, or
  filesystem failure
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
  Imp does not provide a network egress sandbox or private-IP SSRF guard

## Telemetry Events

Imp emits redacted `:telemetry` events through `Imp.Telemetry`.

Use `Imp.trace/2` to capture selected redacted runtime events around one
operation without installing telemetry handlers manually. Use
`Imp.inspect_history/2` for a redacted rendering of recent signature-shaped
turns. Long-running optimizer UIs can call
`Imp.subscribe_optimizer_progress/1` and detach the returned handle with
`Imp.unsubscribe_optimizer_progress/1`.

`Imp.disable_logging/0` and `Imp.enable_logging/0` control only logs emitted
through `Imp.Observability.log/3`; they do not mutate the host application's
global Logger level. Log metadata is redacted before emission.

## Deployment Reference

`examples/deployment` is a packaged OTP reference application. It loads a
checksummed program artifact during supervised startup, resolves callback names
through a host-supplied callback allowlist, obtains provider configuration from runtime
environment variables, and serves calls through a GenServer. The accompanying
test executes the same server with a deterministic LM and registry-backed
artifact before release.

Stable event families:

- `[:imp, :lm, :start | :stop]`
- `[:imp, :lm, :stream, :start | :chunk | :stop]`
- `[:imp, :adapter, :parse, :retry | :error]`
- `[:imp, :cache, :hit | :miss | :coalesced | :retry | :producer_down | :producer_exception]`
- `[:imp, :tool, :start | :stop | :exception]`
- `[:imp, :retriever, :start | :stop | :exception]`
- `[:imp, :mcp, :http | :stdio | :streamable_http, :start | :stop | :exception]`
- `[:imp, :training, :submit | :refresh | :cancel, :start | :stop | :exception]`
- `[:imp, :optimizer, :trial, :start | :stop | :exception]`

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

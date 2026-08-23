# Production Operations

This document covers consumer runtime operations. Imp's release procedure and
maintainer-only verification commands remain in the source repository rather
than the Hex package.

It is the final chapter of the path used by the README, Learning Path, and
Livebooks: after an Imp program has a signature, examples, metrics,
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
  evaluation, and optimizer tasks inherits the caller's Imp context.
- `Imp.Cache` owns the ETS table used by the built-in response cache.
- supervised task owners hold linked async helpers, including provider async
  and parallel prediction fan-out.
- a separate unlinked task supervisor handles bounded workers whose callers
  own cancellation and result collection.
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

## Maintainer verification

Release gates, benchmark evidence, and gate-debugging instructions remain in
the [source repository](https://github.com/deepfates/imp/blob/main/docs/maintainers/GATES.md).
They are not installed as consumer Mix tasks and are not needed to run Imp in
production.

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
- prediction, program, ReAct, CodeAct, and RLM traces redact common
  secret keys and secret-shaped values
- ReAct-family and RLM programs support tool policies

Operational advice:

- never commit `.env`
- rotate keys that were pasted into logs, screenshots, or shared artifacts
- prefer short-lived provider keys for CI and demos
- use explicit `api_key:` or environment variables at runtime, not saved state
- treat MCP, retriever, training, and provider URLs as trusted configuration;
  Imp does not provide a network egress sandbox or private-IP SSRF guard

## Telemetry Events

Imp emits redacted `:telemetry` events through `Imp.Telemetry`.
Every span carries a stable `call_id`; a nested span also carries the enclosing
`parent_call_id`. Imp propagates that lineage through its supervised task boundary, so module,
evaluation, optimizer, LM, tool, retriever, MCP, and training work can be
reconstructed without installing mutable callbacks in program structs. Attach
handlers with `:telemetry.attach/4` or `:telemetry.attach_many/4`; a
`callbacks:` setting is rejected because it would otherwise imply observation
that never occurs.

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

- `[:imp, :module, :start | :stop | :exception]`
- `[:imp, :evaluate, :start | :stop | :exception]`
- `[:imp, :optimizer, :start | :stop | :exception]`
- `[:imp, :lm, :start | :stop]`
- `[:imp, :lm, :stream, :start | :chunk | :stop]`
- `[:imp, :adapter, :parse, :retry | :error]`
- `[:imp, :cache, :hit | :miss | :coalesced | :retry | :producer_down | :producer_exception]`
- `[:imp, :tool, :start | :stop | :exception]`
- `[:imp, :retriever, :start | :stop | :exception]`
- `[:imp, :mcp, :http | :stdio | :streamable_http, :start | :stop | :exception]`
- `[:imp, :training, :submit | :refresh | :cancel, :start | :stop | :exception]`
- `[:imp, :optimizer, :trial, :start | :stop | :exception]` (RandomSearch,
  COPRO, SIMBA, and MIPROv2 candidate evaluations)
- `[:imp, :optimizer, :progress]` (GEPA generations)

Event metadata is redacted before dispatch. Secret-shaped values and common
secret keys are replaced with `[REDACTED]`.

## Live Provider Setup

Configure `OPENAI_API_KEY` and `OPENAI_MODEL` in the host application's secret
store, then exercise the application's own bounded live smoke before rollout.

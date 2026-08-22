# Gates

This is maintainer documentation for the `mix` gates that prove and bound Imp's
behavior. Every command here is available only in a source checkout; none of it
is installed with the Hex package, and none of it is needed to use Imp. The
consumer-facing runtime guidance is [Production Operations](../PRODUCTION_OPERATIONS.md).

## What The Gates Prove

`mix check` runs:

- format check
- compile with warnings as errors
- the deterministic non-live, non-integration, non-protocol test suite

It intentionally does not run paid provider calls, dataset fetches, long
campaigns, package installation, or upstream differentials. Those have their
own commands because they exercise different environments.

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

`mix quality.check` runs Credo's warning-level review plus the Hex dependency
audit. Historical naming decisions are documentation, not a permanent release
gate.

`mix package.check` verifies the Hex package boundary. It checks that the
installable package contains product modules, docs, and Livebooks while
excluding local benchmark evidence tasks, Mix-only proof harnesses, and
test-only support.

The deterministic source-checkout suite also executes the pinned Python DSPy
reference sidecars and reads the pinned GEPA artifact source registry. CI uses
DSPy `3.2.1` and `gepa-ai/gepa-artifact` commit
`cbefbc1aa0f43dd39874ec4bf42211365dbda42e`; changing either pin requires an
upstream-conformance review rather than an incidental dependency update.

The following source-checkout benchmark commands remain available for the
specific questions they answer. They are not combined into a release score:

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
single-process diagnostic. Its timestamped JSON has no source-bound RunContext,
environment identity, or tamper envelope and must not be cited as research
evidence. The underlying behaviors are enforced by ExUnit.

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

## Debugging Gates

Public surface failure:

```sh
mix public_surface.check
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

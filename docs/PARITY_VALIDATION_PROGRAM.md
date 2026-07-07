# DSEx Parity Validation Program

This document defines the evidence required before DSEx can honestly claim
full philosophical, operational, and performance parity with DSPy.

The old question, "Can DSEx answer the same benchmark rows as DSPy with one
live model?", is useful but insufficient. It mostly measures provider behavior
and prompt/adapter compatibility. DSPy's real thesis is broader: programs are
declared with signatures, evaluated by metrics, compiled by optimizers, traced,
saved, served, and improved. DSEx parity must be measured at those same joints.

## Ground Truth

The validation standard is grounded in current DSPy behavior and docs:

- DSPy's core product claim is metric-driven compilation of programs, not
  hand-written prompts.
- Built-in dataset lineage includes GSM8K, HotPotQA, and Color-style tasks.
- Metrics can return booleans, numbers, or prediction-like values carrying
  feedback; optimizers may pass trace context to metrics.
- `Evaluate` runs a program over examples, handles failures with a failure
  score, and supports parallel execution.
- Optimizers include few-shot bootstrapping, instruction/demo search,
  MIPROv2, SIMBA, COPRO, GEPA, and finetuning-oriented workflows.
- Production behavior includes caching, saving/loading, streaming, async
  execution, tools, retrieval, observability, and deployment concerns.

DSEx intentionally implements these ideas in Elixir terms: behaviours, structs,
supervised concurrency, explicit telemetry, and ReqLLM as the provider boundary.
Parity does not mean copying Python internals. It means matching the semantic
contract and proving any intentional deviation is better, not accidental.

## Lane 1: Golden Trace Parity

Provider-free replay is the foundation. It removes model nondeterminism and
provider latency so we can prove library semantics directly.

Required coverage:

- signatures and field metadata
- `Predict`
- `ChainOfThought`
- JSON/schema/chat adapters
- ReAct/tool-call normalization
- streaming chunk vocabulary
- cache hits and misses
- save/load round trips
- metric return normalization
- trace redaction and serialization
- error/failure scoring

Required artifacts:

- a shared fixture corpus consumed by both Python DSPy and DSEx
- normalized message/prompt traces from both sides
- normalized predictions and traces
- exact-match report for required fields
- intentional-deviation table for non-identical but accepted behavior

Pass condition:

- all required fixtures pass exact normalized parity, or each difference is
  recorded as an intentional Elixir-native deviation with a test and rationale.

Ticket: `de-i4o5`.

Initial executable command:

```sh
mix benchmark.trace.check
```

The current checked-in fixture corpus proves normalized prediction parity for
`Predict`, `ChainOfThought`, typed fields, JSON adapter output, DSPy-style
ReAct lookup, multi-tool ReAct, and ReAct tool-error status normalized against
DSEx's provider-tool loop. It also proves shared missing-field error status
parity and DSEx semantic checks for incremental field streaming, save/load
credential redaction, ReqLLM cache hits, and provider text/tool-call stream
chunk replay. Byte-identical prompt/message templates are not a release
criterion: the lane records both message histories and treats DSEx's
Elixir-native provider-tool prompt shape as an intentional deviation unless a
normalized semantic invariant fails.

## Lane 2: Live Matched-Model Parity

Live parity tests whether DSEx and DSPy behave comparably when they talk to the
same real provider/model under the same constraints.

This lane must not be confused with provider-free correctness. It measures the
full operational path: DSEx through ReqLLM, DSPy through `dspy.LM`, both over
the same rows.

Model lanes:

- low-cost current DSPy-doc lane: used for full-row coverage when practical
- frontier sanity lane: a smaller current flagship slice to detect provider
  drift, schema issues, and tool/stream behavior
- historical/research-style lane: where still available, a model family close
  to models used in DSPy examples/papers, or an explicit unavailable note

These lanes are intentionally cross-provider. Small/mini/nano/Haiku/Flash/Lite
models can satisfy the current low-cost bucket; current flagship GPT,
Claude Sonnet/Opus, and Gemini Pro models can satisfy frontier sanity; legacy
GPT-3.5/Davinci, Claude 3-era, Gemini 1.x, or explicitly research/legacy
models can satisfy the historical/research-style bucket.

Dataset/task lanes:

- GSM8K math with ChainOfThought
- HotPotQA / multi-hop QA with provided context
- Color/classification smoke
- at least one RAG/retrieval task
- at least one tool/ReAct task

Required controls:

- same input rows, offsets, and digests
- same model id and provider
- provider-explicit configuration when the lane is not OpenAI: DSEx uses the
  ReqLLM model spec, DSPy uses the matching LiteLLM/DSPy model name, and the
  artifact records matched wire API families
- current DSEx benchmark prompt/signature contract for every selected model
  lane
- same temperature and token limits, or explicit documented provider limits
- same concurrency level
- one explicit campaign id for every chunk in a fresh full run
- cache disabled unless the lane explicitly tests cache
- row-level answers, pass/fail, errors, and latency recorded
- provider and model identity scoped in aggregation

Initial executable matrix:

```sh
mix benchmark.live_matrix
```

This command does not call providers. It aggregates existing
`dsex-dspy-parity-campaign-*.json` artifacts into a
`live-matched-model-matrix-*.json` report, grouped by provider/model identity.
The matrix marks whether DSEx has release-quality evidence for:

- a current low-cost lane with full accepted canonical coverage
- a frontier sanity lane with a fresh matched research sample
- a historical/research-style lane with a fresh matched research sample, or an
  explicit missing/unavailable note

The dashboard consumes this matrix. A smoke matrix is useful wiring evidence,
but it is not live parity. A lane passes only when its policy is met with
current prompt contracts, matched effective generation, score/error parity,
latency ratios, and cost reporting.
When several models are present in one lane, the lane summary reports the
strongest candidate as the headline `coverage`/`cost` path and keeps
cross-candidate totals under `cumulative`; release blockers should point at the
candidate most likely to close the lane.

Pass condition:

- the current low-cost lane covers every canonical row with accepted row
  evidence, not only attempted provider calls
- frontier and historical/research-style lanes reach the configured research
  sample size with matched generation and strict score/latency parity
- runner/API error rows, including quota/rate-limit rows with null answers, are
  counted as incomplete evidence and remain rerunnable
- aggregate and per-task score gaps are within configured thresholds
- error-rate deltas are within threshold
- latency ratio is reported and meets the threshold for operational parity
- cost estimate is reported
- prompt/signature contract identity is current for every selected model lane
- effective generation settings are complete and matched, not merely requested
  settings
- campaign artifacts include DSEx and DSPy instrumentation summaries sufficient
  to tell whether latency gaps come from provider/model time, prompt/output
  shape, or local DSEx overhead and adapter recovery. DSPy prompt-shape
  summaries must preserve `message_chars_sources` so exact LM-history evidence
  can be separated from deterministic row-shape estimates. The matrix selects a
  complete-instrumentation/runtime-shape artifact over a larger incomplete
  artifact for the same provider/model identity; nominal coverage from
  quota-tainted chunks is not release proof.
  and deterministic row-estimated fallback evidence remain distinguishable.

Ticket: `de-ztx7`.

## Lane 3: Optimizer Lift Parity

This is the heart of DSP-style programming. A baseline model-quality benchmark
does not prove optimizer parity. The question is whether DSEx can compile a
program against a metric and improve it with comparable or better efficiency.

Required optimizers:

- `LabeledFewShot`
- `BootstrapFewShot`
- `KNNFewShot`
- `RandomSearch`
- `InstructionSearch`
- `COPRO`
- `MIPROv2`
- `SIMBA`
- `GEPA`
- `BootstrapFinetune` / `GRPO` trainer workflow where the provider surface is
  claimed

Required tasks:

- deterministic reward-coded task where the true optimum is known
- GSM8K subset
- HotPotQA/RAG subset
- tool/ReAct task
- structured extraction or classification task

Required artifacts:

- baseline score
- optimized score
- lift over baseline
- number of trials/candidates
- number of LM calls
- token/cost estimate where live
- wall-clock time
- optimizer trace
- selected instructions/demos
- failure and convergence information

Initial executable command:

```sh
scripts/setup_dspy_parity_env.sh
mix benchmark.optimizer_lift.check
```

The current artifact runs a deterministic provider-free optimizer lift task. It
directly compares DSEx and DSPy `LabeledFewShot`, `BootstrapFewShot`,
`RandomSearch`, `COPRO`, `MIPROv2`, `SIMBA`, and `GEPA` when the installed DSPy
sidecar exposes the optimizer. It records DSEx lift/non-regression plus explicit
deviation notes for `InstructionSearch`, finetuning, and GRPO where the
installed DSPy sidecar lacks a stable provider-free equivalent. The artifact
includes Python package versions and detected DSPy optimizer capabilities so
stale assumptions become visible.

Pass condition:

- DSEx achieves non-regression versus baseline on every optimizer lane
- DSEx matches DSPy lift within threshold for equivalent optimizers, or an
  intentional algorithmic deviation is documented
- DSEx reports enough trace/evidence to debug every optimizer decision

Ticket: `de-vge9`.

## Lane 4: RAG, Tools, Agents, and Production Semantics

DSPy parity includes program composition, retrieval, tools, tracing, and
production behavior. These paths need their own evidence because they fail in
different ways than simple QA.

Required coverage:

- retriever contract and document normalization
- RAG answer quality with deterministic and live retrievers
- ReAct tool call shape, observation handling, and final-answer handling
- MCP/tool adapter behavior
- ProgramOfThought and CodeAct execution/error policy
- streaming output and incremental field parsing
- async/concurrent execution
- save/load/rebind of programs
- observability and redaction

Initial executable command:

```sh
mix benchmark.rag_tool_agent.check
```

The current artifact directly compares DSEx and DSPy on deterministic RAG
retrieval/answering and ReAct lookup-tool semantics. It also records DSEx
production-semantics proofs for HTTP retriever protocol shape, MCP import
through agents, agent tool policy denial traces, ReAct error traces, CodeAct,
ProgramOfThought success and sandbox rejection, streaming incremental fields,
BEAM async execution, and save/load credential redaction. This is full
provider-free production evidence; live matched-model campaigns remain the
separate provider-behavior lane.

Pass condition:

- deterministic replay proves trace/tool semantics
- live matched slices prove provider-facing paths
- all production traces redact secrets and include enough metadata for audit

Ticket: `de-t0c8`.

## Lane 5: Provider-Free Performance

Provider latency can hide language-runtime differences. To claim Elixir
performance improvements, DSEx must measure work that actually happens inside
DSEx and DSPy.

Required benchmarks:

- signature parsing/loading
- adapter message formatting
- adapter response parsing
- JSON/schema validation
- evaluation loop throughput
- metric normalization
- optimizer trial scheduling
- trace construction/redaction/serialization
- cache hit and miss overhead
- concurrent orchestration overhead

Required controls:

- no live provider calls
- fixed fixture corpus
- warmup and repeated measurements
- CPU/runtime metadata
- memory where practical
- Python and Elixir versions recorded

Initial executable command:

```sh
mix benchmark.overhead.check
```

The current provider-free lane emits a DSEx/DSPy overhead artifact for signature
parsing, adapter format/parse, schema validation, evaluation loop throughput,
metric normalization, optimizer trial scheduling, trace redaction/serialization,
cache hit/miss overhead, and concurrent orchestration.
The production gate uses a conservative ratio threshold and the artifact must
be consulted before making any path-specific speed claim.

Pass condition:

- DSEx performance claims name the benchmark they come from
- provider-free overhead is lower than DSPy for the claimed paths, or the claim
  is not made
- regressions have tickets before release

Ticket: `de-dd3k`.

## Lane 6: Evidence Dashboard and Release Gate

The validation program must end in a single truth surface. Humans can read
details, but release decisions need machine-readable artifacts.

Required outputs:

- `benchmarks/results/parity-dashboard-*.json`
- lane status: `missing`, `smoke`, `sample`, `full`, `passing`, `failing`
- links to source artifacts
- dataset digests
- runtime versions
- model/provider identities
- score, lift, latency, cost, error, and throughput summaries
- live runtime instrumentation summaries, including DSEx LM-duration share,
  local overhead, fallback/retry counts, DSPy history coverage, and
  prompt/output size diagnostics with DSPy message-size provenance
- explicit full-parity boolean
- explicit performance-claim boolean

Initial executable commands:

```sh
mix benchmark.dashboard
mix benchmark.dashboard.full
```

`mix benchmark.dashboard` writes the latest machine-readable truth surface even
when lanes are incomplete. `mix benchmark.dashboard.full` is the release gate:
it reads the same artifacts and fails unless every required lane has fresh,
passing, full-evidence status. This is intentionally stricter than
`production.check`; a green deterministic gate is not a full DSPy-parity claim.

Pass condition:

- release docs consume the dashboard
- full parity cannot be claimed unless required lanes pass
- performance improvement cannot be claimed unless provider-free benchmarks
  support it
- live latency conclusions identify whether observed gaps are provider/model
  dominated, prompt/output-shape dominated, or DSEx local-overhead dominated

Ticket: `de-m27t`.

## What Counts As Done

DSEx has full parity evidence only when:

1. Golden trace parity is complete.
2. Live matched-model parity has at least one full current low-cost lane, one
   matched research-sample frontier sanity lane, and one matched
   research-sample historical/research-style lane.
3. Optimizer lift parity passes for every optimizer DSEx exposes as production
   surface.
4. RAG/tool/agent production semantics pass deterministic and live slices.
5. Provider-free performance benchmarks support any speed claims.
6. The dashboard reports `full_parity: true`.
7. The release criteria link to the exact dashboard artifact.

Until then, honest language is narrower: DSEx may have a passing smoke lane,
deterministic parity for specific surfaces, or performance wins on specific
provider-free paths.

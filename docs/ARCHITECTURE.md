# Architecture

The library is organized around a single flow:

```text
Example / inputs
  -> Signature
  -> Program module
  -> Adapter.format/3
  -> LM.generate/2 or stream
  -> Adapter.parse/3
  -> Prediction
  -> Metric / Optimizer / Save / Stream
```

## Public Facade

`Imp` in `lib/imp.ex` is the canonical public entry point:

- settings: `Imp.configure/1`, `Imp.settings/0`, `Imp.context/2`
- data: `Imp.signature/2`, `Imp.example/1`, `Imp.with_inputs/2`, `Imp.inputs/1`, `Imp.labels/1`, `Imp.prediction/1`, `Imp.get/3`, `Imp.to_map/1`, `Imp.majority/2`
- history: `Imp.history/1`, `Imp.append_history/2`
- programs: `Imp.predict/2`, `Imp.chain_of_thought/2`, `Imp.multi_chain_comparison/2`, `Imp.best_of_n/3`, `Imp.refine/3`, `Imp.assertion/3`, `Imp.assert/3`, `Imp.parallel/3`, `Imp.knn/3`, `Imp.nearest/2`
- sandbox and recursive programs: `Imp.program_of_thought/2`, `Imp.code_act/3`, `Imp.rlm/2`, `Imp.rlm_serializable/3`
- tools and agents: `Imp.tool/4`, `Imp.react/3`, `Imp.react_v2/3`, `Imp.avatar/3`
- retrieval: `Imp.memory/2`, `Imp.retrieve/3`, `Imp.rag/3`
- execution: `Imp.call/2`, `Imp.stream/3`, `Imp.collect/3`, `Imp.with_demos/2`, `Imp.with_playbook/2`, `Imp.with_lm/2`
- evaluation and metrics: `Imp.evaluate/4`, `Imp.exact_match/1`, `Imp.extractive_qa/3`, `Imp.classification/3`, `Imp.classification_report/2`
- optimization: `Imp.optimize!/3`, `Imp.optimize!/4`, `Imp.optimize!/5`, `Imp.train/4`, `Imp.optimizer_capabilities/1`
- persistence: `Imp.dump/1`, `Imp.dump/2`, `Imp.load/1`, `Imp.load/2`, `Imp.save!/2`, `Imp.save!/3`, `Imp.load!/1`, `Imp.load!/2`
- observability: `Imp.inspect_history/2`, `Imp.trace/2`, `Imp.subscribe_optimizer_progress/1`, `Imp.unsubscribe_optimizer_progress/1`, `Imp.enable_logging/0`, `Imp.disable_logging/0`
- provider helper: `Imp.req_llm/2`

Use the facade for application code. Use deeper modules when you need direct
control in tests, docs, or advanced systems.

## Core Data

### `Imp.Signature`

Defines input and output fields. The string DSL supports typed flat fields,
descriptions, arrays, and enum/class constraints with position-aware parse
errors. String field names from external data remain strings unless the atom
already exists, which prevents atom exhaustion.

Important functions:

- `new/2`
- `ensure/1`
- `input_names/1`, `output_names/1`
- `extend/3`, `prepend_output/2`
- `dump/1`, `load/1`
- `json_schema/1`

### `Imp.Example`

Stores train/dev/test rows and optional input keys.

Important functions:

- `new/1`
- `with_inputs/2`
- `inputs/1`, `labels/1`
- `get/3`, `fetch!/2`, `put/3`, `delete/2`

### `Imp.Prediction`

Stores model outputs plus completions, score, and metadata.

Important functions:

- `new/2`
- `get/3`, `fetch!/2`, `put/3`
- `to_map/1`
- `from_example/2`

## Program Modules

All major program structs implement the `Imp.Module` behaviour.

| Module | Purpose |
| --- | --- |
| `Imp.Predict.Predict` | Basic signature-to-output LM call. |
| `Imp.Predict.ChainOfThought` | Prepends `reasoning` before signature outputs. |
| `Imp.Predict.ReAct` | Canonical iterative provider-tool-call ReAct with reserved `submit`. |
| `Imp.Predict.ProgramOfThought` | LM emits a safe expression or tool action plan. |
| `Imp.Predict.CodeAct` | Iterates tool observations and BEAM-safe sandbox execution with trace metadata. |
| `Imp.Predict.RLM` | Recursive language model loop over metadata, sandbox actions, tools, sub-LM calls, and submit. |
| `Imp.Predict.MultiChainComparison` | Compares multiple chain-of-thought outputs. |
| `Imp.Predict.BestOfN` | Runs a program N times and keeps best by metric. |
| `Imp.Predict.Refine` | Repeated attempts with reward threshold. |
| `Imp.Predict.Search` | Request-local candidate execution, selection, budgets, and provenance shared by BestOfN and Refine. |
| `Imp.Predict.Parallel` | Parallel map helpers. |

### Request-Local Search Boundary

BestOfN and Refine provide an immutable orchestration boundary for one
inference request. They do not read optimizer state, cache search results,
register a process, or persist state between calls. Their facade contracts
cover scoring, threshold stopping, deterministic tie selection, failure
isolation, and provenance.

Finite multidimensional budgets decide up front, in request order, how much
work may start. `admitted_budget` is the sum of the projections the budget let
start, while `observed_budget` is the sum of projections attached to completed
outcomes.
Neither field is actual provider usage. Sequential evaluators receive prior
ordered outcomes, which Refine uses for feedback history. Concurrent evaluators
run under Imp's supervised task runtime, bounded by `max_concurrency`, and
receive no causal prior outcomes. Concurrent threshold stopping may therefore
include completed speculative work; incomplete work is
cancelled and represented in full-list provenance.

Repository-only search benchmarks record deterministic quality, ordering,
projected cost, failure-free completion, and observed concurrency bounds. They
record latency samples as measurements only and do not turn local scheduler
timing into a release assertion.

## Adapters

Adapters implement:

```elixir
format(signature, inputs, opts) :: messages
parse(signature, raw, opts) :: {:ok, prediction} | {:error, reason}
```

Available adapters:

- `Imp.Adapter.Chat`
- `Imp.Adapter.JSON`
- `Imp.Adapter.XML`
- `Imp.Adapter.SingleField` (Imp-native strict value-only protocol for exactly
  one output field)
- `Imp.Adapter.TwoStep` (DSPy TwoStepAdapter port; extraction LM via the
  `two_step_extraction_lm` setting)
- `Imp.Adapter.PlanFirst` (Imp extension: plan-prepend over Chat)

`JSON` and schema-constrained signatures are the best fit when the output shape
matters more than prose flexibility.

## LMs And Providers

`Imp.LM` is a small behaviour. Tests usually use:

```elixir
Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)
```

The preferred production client is:

- `Imp.Clients.ReqLLM`

`Imp.Clients.ReqLLM` delegates provider/model lookup, Req/Finch transport,
streaming, tool/schema option translation, and response normalization to the
Elixir `req_llm` ecosystem. Imp keeps the declarative programming layer:
signatures, adapters, modules, optimizers, evaluation, traces, persistence, and
redacted telemetry.

Production provider access goes through ReqLLM. Imp does not maintain a
parallel OpenAI-compatible provider client stack; deterministic provider tests
use ReqLLM test modules or the live ReqLLM-backed gates.

Provider streaming is client-dependent. The ReqLLM-backed client streams through
ReqLLM's Finch/SSE machinery and maps `ReqLLM.StreamChunk` values into the Imp
streaming vocabulary. Direct `Imp.HTTP` transports that implement `stream/4`
can also deliver incremental chunks. Transports that only implement `post/4`,
including the default `:httpc` transport, expose a buffered body that Imp can
parse as stream events but cannot make incrementally arrive.

Runtime dependencies are deliberately justified and production-oriented:

- `Jason` is the JSON boundary for providers, adapters, datasets, reports, and
  saved state.
- `NimbleOptions` validates network-facing and provider-facing constructor
  options so typos fail before a live request or training job is submitted.
- `ReqLLM` is the provider ecosystem boundary. It brings Req/Finch transport,
  streaming, provider registries, model metadata, structured-output support, and
  provider-specific option translation so Imp does not need to own those
  fast-moving concerns itself.
- `:telemetry` is the stable observability boundary. Imp keeps a tiny wrapper
  in `Imp.Telemetry` so tests can also attach process-local handlers.
- `ExDoc` is dev/test only and is part of the production gate because generated
  docs are treated as release artifacts.

### Dependency Posture

Imp is intentionally not autarkic. It brings in ecosystem dependencies when
the dependency owns a fast-moving or operationally specialized boundary better
than Imp can:

- provider APIs, model catalogs, transport, retries, streaming, and structured
  output negotiation belong to `ReqLLM`;
- JSON, option validation, and telemetry use established libraries;
- test-only dependencies may be added for stronger contracts, property tests,
  static analysis, and local-service harnesses.

Imp keeps code in core when the behavior is part of declarative
self-improving programming itself: signatures, adapters, prediction structs,
module composition, evaluation, optimization, traces, saving, sandbox policy,
and the Elixir-facing public API. A dependency should either remove operational
risk, align Imp with normal OTP practice, or provide test evidence that would
be hard to maintain in bespoke code.

Production application code should use `Imp.req_llm/2`. Provider APIs,
transport pooling, streaming, retries, model metadata, and structured output
belong to ReqLLM, not to a parallel Imp-owned client stack.

### OTP Runtime Boundary

Imp is an OTP application, but most program values are ordinary immutable
structs. The supervised runtime boundary currently owns:

- `Imp.Settings`, an Agent for global defaults plus process-local overrides;
- `Imp.Cache`, an ETS-backed cache process and table;
- `Imp.TaskSupervisor`, the named task supervisor used by linked provider
  async and parallel prediction fan-out;
- `Imp.UnlinkedTaskSupervisor`, the named task supervisor used by unlinked
  event workers such as agent event streaming.

In production releases, start the `:imp` application under the host
supervision tree. Mix does this automatically for normal applications, but
embedded or script-style users should call `Application.ensure_all_started(:imp)`
before relying on global settings or cache behavior. Imp keeps lazy-start
fallbacks for library ergonomics, but the supervised path is the production
posture.

Long-running or fan-out work should have an OTP owner. Imp routes its built-in
async helpers through supervised task owners. If the `:imp` application is not
running yet, the internal task dispatcher starts it before submitting work; it does not
fall back to unsupervised plain tasks. That keeps cancellation, crash reporting,
telemetry context, and shutdown behavior visible to the host system in
production and in script-style use.

The built-in cancellation helper terminates a supervised task with a bounded
wait.
`Imp.Streaming.Messages.StreamListener.attach/2` observes normalized stream
events while yielding the original chunks, including terminal and error events,
unchanged. `Imp.Cache.configure/1` controls enablement, TTL, and maximum entry
count; `Imp.Cache.stats/0` reports atomic hit, miss, write, bypass, expiration,
and eviction counters. Cache reads and writes remain ETS hot paths while the
owner process controls policy and table lifecycle.

Runtime boundaries emit redacted telemetry events for LM calls, streaming
chunks, adapter parse retries/failures, cache hits/misses, tool calls,
retrievers, MCP requests, training jobs, and optimizer trials.

## Retrieval And Datasets

Retrievers:

- `Imp.Retrieve.Memory`
- `Imp.Retrievers.KNN`
- `Imp.Retrievers.HTTP`
- `Imp.Retrievers.Weaviate`
- `Imp.Retrievers.Databricks`

Datasets:

- `Imp.Datasets.from_records/3`
- `jsonl/3`, `csv/3`
- `GSM8K`, `HotPotQA`, `MATH`, `Colors`
- `Imp.Datasets.Dataset` split container

## Evaluation

`Imp.Evaluate` runs a program over a dev set with a metric.

Built-in metrics live in `Imp.Metrics`:

- exact match
- semantic-ish F1 helpers

Metric returns are normalized by `Imp.Metrics.normalize_result/1`. Metrics may
return booleans, numbers, maps with score/feedback, or predictions. Evaluation
rows preserve normalized score, pass/fail state, feedback, metric metadata, and
program errors. Arity-3 metrics receive the prediction trace as their third
argument.
- custom functions of arity 2 or 3

## Optimization

`Imp.Optimizer` is the canonical execution behaviour. Implementations expose
`__optimizer__/0` capability metadata and a single `run/3` callback. Dispatch
does not inspect legacy `compile` arities to decide what arguments mean. The
capability declaration contains:

- `kind`: `:program`, `:training`, `:constructor`, or `:workflow`;
- `datasets`: named splits mapped to `:required`, `:optional`, or
  `:unsupported`;
- `result`: `:program`, `:training_result`, `:constructed_program`, or a
  `{:workflow_result, module}` contract.

`Imp.Optimizer.run/3` validates the capability shape, keyword invocation
options, declared dataset presence or absence, and the outer result shape. The
optimizer implementation validates dataset contents, split relationships, and
its own options. This keeps split routing centralized without claiming that the
behaviour can validate optimizer-specific data semantics.

The facade enforces lifecycle separation. `Imp.optimize!/3-5` accepts only
`:program` optimizers and returns the compiled program, raising `ArgumentError`
for contract failures. Validation-required optimizers use `optimize!/4` or
`optimize!/5`; optional-validation optimizers can use `optimize!/3` or supply the
split. `Imp.train/3` and `Imp.train/4` accept only `:training` optimizers and
return `{:ok, %Imp.Optimizer.TrainingResult{}} | {:error, reason}`.
Constructor and workflow kinds retain their explicit module APIs rather than being routed
through either facade function. Optimizer-specific `compile` functions also
remain available when advanced callers need native return values or direct
checkpoint orchestration.

The metric-driven optimizers — `LabeledFewShot`, `BootstrapFewShot`,
`RandomSearch`, `InstructionSearch`, `COPRO`, `MIPROv2`, `SIMBA`, `GEPA`, and
`BetterTogether` — live under `Imp.Optimizer.*`, and the
[API Guide](API_GUIDE.md) optimizer table is the single home for when to reach
for each. Training optimizers (`BootstrapFinetune`, `GRPO`) run through
`Imp.train/3` with an explicit trainer backend, and Fast-Slow training has its
own provider-neutral runner; both are detailed in
[Operations Reference](OPERATIONS_REFERENCE.md).

Arbitrary artifact optimization lives under `Imp.Optimize.*`:

- `Imp.Optimize.Anything`

## Agents, Tools, MCP

`Imp.Tool` wraps callable functionality; the react-family programs compose
tools under explicit policies. An explicit agent runtime exists internally,
but the packaged surface is the react/rlm spectrum plus your own supervised
Elixir around `Imp.Tool.call/2`.

`Imp.MCP` imports in-process, HTTP, stdio, or Streamable HTTP tool catalogs
into `Imp.Tool` values. Transport clients use JSON-RPC 2.0 envelopes,
initialize before discovery, and expose remote `tools/list` / `tools/call`
style flows through ordinary tools. Stdio clients spawn trusted local MCP
server executables; they are not a sandbox for untrusted commands.

## RLM

`Imp.Predict.RLM` is intentionally not RAG. It gives the controller LM:

- signature metadata
- variable metadata and previews
- observations
- tools
- remaining budget

The controller normally returns reasoning plus constrained Elixir code. One
interpreter instance persists for the complete call, so assignments and
subquery results survive across turns. Code can call `llm_query/1` and
`llm_query_batched/1` from comprehensions, invoke `recurse/2`, load lazy values,
call registered tools, inspect bounded output, and terminate through
`submit/1`. The controller surface is code plus typed interpreter effects; map-
shaped discrete actions are rejected.

The implementation is BEAM-native and does not call `Code.eval_*`. It parses
Elixir syntax with atom-safe identifier handling, interprets an explicit AST
allowlist, rejects arbitrary module/function execution, and enforces source,
AST, execution, value, effect, output, recursion, call, and time limits. The
interpreter is a deterministic symbolic component: it yields typed effects, and
the RLM runtime executes them under OTP supervision before resuming through
transactional replay. External closures never execute inside the evaluator.
Batched subqueries use supervised BEAM tasks with deterministic ordering and
atomically lease the complete call capacity before fan-out. Each lease unit is
charged only when its worker starts; unstarted units are released. Recursive
children carry immutable branch depth and share the same call/deadline ledger.
Malformed submits and safe interpreter errors return to the controller as
observations; normal iteration exhaustion invokes an extract pass.

Large trace terms are redacted and replaced with bounded type, size, and digest
metadata before storage. A single absolute deadline governs controller calls,
effects, batches, and recursive children; timed effects are registered with the
execution coordinator so cancellation terminates in-flight tasks.

Large or expensive values can enter the loop as bounded serializable handles.
The first controller prompt sees only their metadata; `context = load("context")`
materializes the value into variable space when needed. The RLM facade keeps
its action, extract, and subquery machinery private while exposing the behavior
needed by callers.

## Persistence

`Imp.Saving` saves portable program state for `Predict`, `ChainOfThought`,
`ProgramOfThought`, and memory-backed `RAG`. It does not persist secrets.
Loading an HTTP LM requires explicit credential rebinding rather than silently
capturing ambient environment credentials. Programs that embed function tools,
such as ReAct and CodeAct, should be rebuilt with their tool catalogs instead
of deserialized from disk.

## Maintainer verification

Release, integration, and live-provider gates remain in the
[source repository](https://github.com/deepfates/imp/blob/main/docs/maintainers/GATES.md).
They validate this runtime behavior before release but are not installed as
consumer Mix tasks.

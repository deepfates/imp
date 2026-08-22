# Imp Parity Validation Program

This document defines the evidence required before Imp can honestly claim
full philosophical, operational, and performance parity with DSPy.

This is a maintainer document for an Imp source checkout. Its Mix commands and
artifact paths are not package-consumer APIs.

The old question, "Can Imp answer the same benchmark rows as DSPy with one
live model?", is useful but insufficient. It mostly measures provider behavior
and prompt/adapter compatibility. DSPy's real thesis is broader: programs are
declared with signatures, evaluated by metrics, compiled by optimizers, traced,
saved, served, and improved. Imp parity must be measured at those same joints.

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

Imp intentionally implements these ideas in Elixir terms: behaviours, structs,
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

- a shared fixture corpus consumed by both Python DSPy and Imp
- normalized message/prompt traces from both sides
- normalized predictions and traces
- exact-match report for required fields
- intentional-deviation table for non-identical but accepted behavior

Pass condition:

- all required fixtures pass exact normalized parity, or each difference is
  recorded as an intentional Elixir-native deviation with a test and rationale.

Initial executable command:

```sh
mix benchmark.trace.check
```

The current checked-in fixture corpus proves normalized prediction parity for
`Predict`, `ChainOfThought`, typed fields, JSON adapter output, DSPy-style
ReAct lookup, multi-tool ReAct, and ReAct tool-error status normalized against
Imp's provider-tool loop. It also proves shared missing-field error status
parity and Imp semantic checks for incremental field streaming, save/load
credential redaction, ReqLLM cache hits, and provider text/tool-call stream
chunk replay. Byte-identical prompt/message templates are not a release
criterion: the lane records both message histories and treats Imp's
Elixir-native provider-tool prompt shape as an intentional deviation unless a
normalized semantic invariant fails.

## Lane 2: Live Matched-Model Parity

Live parity tests whether Imp and DSPy behave comparably when they talk to the
same real provider/model under the same constraints.

This lane must not be confused with provider-free correctness. It measures the
full operational path: Imp through ReqLLM, DSPy through `dspy.LM`, both over
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
- provider-explicit configuration when the lane is not OpenAI: Imp uses the
  ReqLLM model spec, DSPy uses the matching LiteLLM/DSPy model name, and the
  artifact records matched wire API families
- current Imp benchmark prompt/signature contract for every selected model
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
`imp-dspy-parity-campaign-*.json` artifacts into a
`live-matched-model-matrix-*.json` report, grouped by provider/model identity.
The matrix marks whether Imp has release-quality evidence for:

- a current low-cost lane with full accepted canonical coverage
- a frontier sanity lane with a fresh matched research sample
- a historical/research-style lane with a fresh matched research sample, or an
  explicit missing/unavailable note

The matrix is a research result. A smoke matrix is useful wiring evidence, but
it is not live parity. A lane passes only when its policy is met with
current prompt contracts, matched effective generation, score/error parity,
latency ratios, and cost reporting.
When several models are present in one lane, the lane summary reports the
strongest candidate as the headline `coverage`/`cost` path and keeps
cross-candidate totals under `cumulative`; release blockers should point at the
candidate most likely to close the lane.
If legacy/research endpoints are no longer available, an operator may record
that decision explicitly:

```sh
mix benchmark.live_matrix \
  --historical-unavailable-note "GPT-3.5 quota exhausted; Gemini 1.x credential invalid; Claude 3 endpoints unavailable on this account."
```

That note satisfies only the historical/research availability requirement. It
does not create `full_evidence`, does not count zero-row failed endpoint probes
as parity evidence, and does not satisfy the current low-cost or frontier
evidence lanes.

Pass condition:

- the current low-cost lane covers every canonical row with accepted row
  evidence, not only attempted provider calls
- frontier and historical/research-style lanes reach the configured research
  sample size with matched generation; measurement completion is reported
  separately from the strict score/latency parity outcome
- runner/API error rows, including quota/rate-limit rows with null answers, are
  counted as incomplete evidence and remain rerunnable
- selected live campaign artifacts record a single consistent `max_concurrency`
  setting; mixed serial/concurrent chunks are diagnostic evidence only until
  rerun or reaggregated into a comparable campaign lineage
- aggregate and per-task score gaps are within configured thresholds
- error-rate deltas are within threshold
- latency ratio is reported and meets the threshold for operational parity
- cost estimate is reported
- prompt/signature contract identity is current for every selected model lane
- effective generation settings are complete and matched, not merely requested
  settings
- campaign artifacts include Imp and DSPy instrumentation summaries sufficient
  to tell whether latency gaps come from provider/model time, prompt/output
  shape, or local Imp overhead and adapter recovery. DSPy prompt-shape
  summaries must preserve `message_chars_sources` so exact LM-history evidence
  can be separated from deterministic row-shape estimates. The matrix selects a
  complete-instrumentation/runtime-shape artifact over a larger incomplete
  artifact for the same provider/model identity; nominal coverage from
  quota-tainted chunks is not release proof, and deterministic row-estimated
  fallback evidence must remain distinguishable from exact LM-history evidence.

## Lane 3: Optimizer Lift Parity

This is the heart of DSP-style programming. A baseline model-quality benchmark
does not prove optimizer parity. The question is whether Imp can compile a
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
- `GEPA`-style reflection
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

The current artifact runs a deterministic provider-free matched-mechanism
lift task: the winning instruction/demo is planted in both sides' candidate
pools and scoring reuses the selection devset, so it demonstrates that Imp
optimizers select and apply an injected winner identically to DSPy — not
held-out lift (dee-5y5u). It
directly compares Imp and DSPy `LabeledFewShot`, `BootstrapFewShot`,
`RandomSearch`, `COPRO`, `MIPROv2`, `SIMBA`, and GEPA-style optimizer rows when
the installed DSPy sidecar exposes a compatible GEPA path. It records Imp
lift/non-regression plus explicit deviation notes for `InstructionSearch`,
finetuning, and GRPO where the installed DSPy sidecar lacks a stable
provider-free equivalent. The artifact includes Python package versions and
detected DSPy optimizer capabilities so stale assumptions become visible. It
also includes Imp natural user-story lanes for classification, QA,
retrieval/KNN few-shot, and instruction following. Each natural lane reports
baseline score, optimized score, lift, LM calls, estimated fixture cost, and
selected demos or instructions.

Research-scale GEPA claims use a separate lane:

```sh
mix benchmark.gepa_replication.check
```

That lane runs deterministic smoke rows and validates GEPA paper-family
artifact shape rather than generic optimizer lift. Full evidence requires
non-smoke campaign rows for AIME, HotpotQA, HoVer, IFBench,
LiveBench-Math, and Papillon/privacy delegation, with baseline, DSPy GEPA,
Imp GEPA, MIPROv2, metric-call budget, token/cost, wall-clock, seed variance,
and train/dev/test gap. Full rows must include campaign provenance, dataset
source and split checksums, DSPy/Imp/GEPA-artifact commits, concrete
non-placeholder comparator sources, distinct train/dev/test split digests, and
positive live token/cost accounting. Full rows must come from dataset roots
exported with `dataset.scope == "full"`; capped `--max-per-split` roots are
accepted only as engineering proof runs and are rejected for full research
claims. SIMBA is optional extra comparator evidence, not a required optimizer
in the upstream GEPA artifact.

A full campaign conversion is source-shaped, not a generic six-task harness.
Required rows are `AIMEBench/CoT` (`problem -> answer`),
`HotpotQABench/HotpotMultiHop` (`question -> answer`),
`hoverBench/HoverMultiHop` (`claim -> retrieved_docs`),
`IFBench/IFBenchCoT2StageProgram` (`prompt -> response`),
`LiveBenchMathBench/CoT` (`question -> answer`), and
`Papillon/PAPILLON` (`user_query -> llm_request, llm_response, response`). The two `CoT`
rows remain separate family contracts with their own metrics, splits,
instructions, and budgets.

HotPot, HoVer, and IFBench use strict component-specific GEPA feedback.
HotPot's map covers `summarize1`, `create_query_hop2`, `summarize2`, and
`final_answer`; HoVer's covers `summarize1`, `create_query_hop2`,
`summarize2`, and `create_query_hop3`; IFBench's covers
`generate_response_module` and `ensure_correct_response_module`. Each map must
exactly match the program predictor graph. A callback receives the selected
predictor invocation plus example, program result, metric result, and trace,
and must return non-empty feedback text; a mismatch or callback failure stops
optimization. The AIME, LiveBenchMath, and Papillon rows currently rely on
metric-level feedback rather than a custom component map. Campaign metadata
records the installed component-feedback identity.

For source-checkout campaigns, use `mix imp.benchmark.gepa_replication
--from-gepa-artifact ... --upstream-evidence ... --imp-input ...
--protocol-classification exact_paper_replication` to convert upstream GEPA artifact
`Baseline`, `GEPA`, and `MIPROv2-Heavy` outputs into retained result rows. The
`--imp-input` file must come from Imp's own GEPA run and provide the
`imp_gepa` result plus provenance fields; the converter does not synthesize
Imp scores.
The explicit classification is reserved for a separately frozen
paper-authority protocol. The adapted current-model no-merge table must omit it
and cannot enter the exact C4 lane.

Produce canonical Imp input with `mix imp.benchmark.gepa_campaign --manifest
benchmarks/config/gepa-paper-campaign-v2.json`. The immutable manifest binds the
full dataset hash, model roles, families, seeds, budgets, source commits,
request policy, source-exact environment, semantic-progress threshold, and
output/checkpoint paths. Five consecutive reflection proposal errors stop the
run with a checkpointed machine-readable reason before any claim artifact is
written. The v1 manifest remains available for exact reproduction of campaigns
started before this fail-fast contract. Legacy
partial runs remain path-driven: the dataset root must include a `families.json` contract and
`train.jsonl` / `dev.jsonl` / `test.jsonl` files for every GEPA family. The
runner records Imp GEPA candidate/frontier metadata, seed variance, split
digests, dataset scope, split counts, source commits, and explicit provider
token/cost accounting. It writes partial `imp-gepa-rows-*.json` artifacts;
only the replication converter can turn full-scope partial rows plus upstream
comparator outputs into a full public claim artifact.

Build the dataset root with `mix imp.benchmark.gepa_dataset --gepa-root
path/to/gepa-artifact --out benchmarks/data/gepa-campaign`. This imports the
upstream GEPA artifact benchmark classes and writes source-derived split JSONL
plus a `families.json` manifest. The manifest records upstream metric names,
dataset scope, optional max-per-split cap, split counts, and split checksums.
Imp ports AIME integer exact match, HotPotQA answer exact match, HoVer
supporting-title retrieval, IFBench IFEval-style constraints, Papillon LLM-judge
quality/leakage scoring, and the deterministic LiveBenchMath AMC/AIME parser
paths plus `imo`/`usamo` proof-rearrangement edit-distance scoring. GEPA
HotPot and HoVer rows must carry provenance for the same upstream
`wiki.abstracts.2017` BM25 corpus/index checksums. The campaign task requires
`IMP_HOVER_UPSTREAM_BM25=1` for either family and executes both through the
pinned upstream Python BM25S index; generic retrieved-document outputs or the
native Elixir BM25 approximation cannot satisfy source-exact campaign evidence.
The native implementation does not reproduce the upstream English stopword
tokenizer or PyStemmer stemming. Validate fixed top-k title fixtures in a GEPA
source checkout at commit
`cbefbc1aa0f43dd39874ec4bf42211365dbda42e` with
`IMP_HOVER_UPSTREAM_PARITY=1 mix test test/hover_bm25_parity_test.exs` after
setting `IMP_GEPA_PYTHON` to an environment with `bm25s==0.2.12` and
`pystemmer==2.2.0.3`.
IFBench imports the larger AllenAI extended registry; Imp ports those registry
checks in Elixir and keeps unknown ids fail-closed. Four IFBench NLP-dependent
checks have native deterministic fallbacks plus a source-exact Python bridge for
research campaigns. The source-checkout differential covers all 83 active
merged-registry ids and passes against the pinned GEPA artifact, including
language detection and NLP-backed checks. Full IFBench GEPA runs additionally
require `IMP_IFBENCH_UPSTREAM_DESCRIPTIONS=1`, `IMP_GEPA_ROOT`, and
`IMP_GEPA_PYTHON`; the Elixir scorer remains native while reflective feedback
uses the pinned upstream registry's exact human descriptions. Papillon campaigns
must pass a judge LM and include `metric_judge` provenance in research rows.
LiveBenchMath `amps_hard` is guarded by the SymPy/Lark symbolic bridge and must
be validated in the research campaign Python environment before claiming
AMPS_Hard parity.

Upstream comparator evidence is an archive-derived sidecar, not a manually
completed result field. Run `scripts/extract_gepa_upstream_evidence.py` with
the immutable `experiment_runs_data` archive, the matching GEPA artifact
checkout, selected model, and an output path. The extractor requires all six
family/program pairs and `Baseline`, `GEPA`, and `MIPROv2-Heavy` seed-0 runs;
records archive and source identities; reads run configuration, metric JSONL,
and `evaluation_result.txt`; and derives observed optimizer callbacks by
subtracting Baseline final-test callbacks. The replication converter requires
that sidecar, validates its exact key set and the result-file score/SHA-256, and
rejects configured-only budgets, missing enforcement, and test-selected seeds.

Pass condition:

- Imp achieves non-regression versus baseline on every optimizer lane
- Imp matches DSPy lift within threshold for equivalent optimizers, or an
  intentional algorithmic deviation is documented
- Imp reports enough trace/evidence to debug every optimizer decision

## Lane 4: RAG, Tools, Agentic Programs, and Production Semantics

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

Executable checks:

```sh
mix benchmark.rag_tool_failure.check
mix benchmark.rlm.check
mix test test/react_contract_test.exs test/rlm_test.exs \
  test/tool_schema_runtime_test.exs test/mcp_import_test.exs \
  test/task_supervision_test.exs test/telemetry_lineage_contract_test.exs
```

The aggregate RAG/tool/agent evaluator and disconnected generic agent runtime
were removed for 0.3. Product semantics now live in direct tests of the
canonical ReAct/RLM/tool/MCP/task/persistence boundaries. Retained differentials
must add an external comparison, not rebundle already-tested behavior into a
second pass/fail dashboard.

The separate `mix imp.benchmark.rag_tool_failure_differential` lane runs one
six-scenario queued-action schedule through actual Imp ReAct and
source-authenticated DSPy 3.2.1 ReAct. Exact normalized traces cover a
transient retry, injected retriever timeout, fixture idempotency replay,
unknown/failing tools, finish/submit, and max-iteration terminals. This closes
the provider-free matched-schedule mechanics gap at C2 only. Because the LM
does not select actions and fixture tools own retry/idempotency behavior, it is
not recovery effectiveness, wall-clock timeout parity, or native policy parity.

The RLM command produces T0 deterministic contract replay over hand-authored
fixture rows. It is useful for checking harness wiring and inspecting traces,
but gold-derived outputs and non-equivalent scripted executions make it
ineligible for effectiveness, long-context, operational-parity, or uncertainty
claims. T3 paper-protocol evidence is required for the release lane.

`mix benchmark.rlm.contract.check` is the stronger T1 lane. It gates twelve
matched execution contracts against DSPy 3.3.0b1 and records the exact upstream
source hash. T1 remains operational evidence, not model-quality or paper-scale
evidence.

Pass condition:

- deterministic replay proves trace/tool semantics
- live matched slices prove provider-facing paths
- all production traces redact secrets and include enough metadata for audit

## Lane 5: Provider-Free Performance

Provider latency can hide language-runtime differences. To claim Elixir
performance improvements, Imp must measure work that actually happens inside
Imp and DSPy.

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

The provider-free lane emits an Imp/DSPy overhead artifact for signature
parsing, adapter format/parse, schema validation, evaluation loop throughput,
metric normalization, optimizer trial scheduling, trace redaction/serialization,
cache hit/miss overhead, and concurrent orchestration.
Each named operation has an absolute Imp-median guard and a reference-relative
guard with explicit rationale. Cache, schema, and optimizer operations use
matched logical work and configuration. Runtime/environment identity is bound
into the verified artifact. Ratios are diagnostic measurements, not speed or
parity claims.

Pass condition:

- Imp performance claims name the benchmark they come from
- every named operation remains within its declared regression budgets
- no speed claim is inferred from a budget or ratio
- regressions have tracked remediation before release

## Reading Results

There is no aggregate parity or release score. Each lane retains the inputs,
runtime identities, data digests, costs, raw outcomes, and interpretation needed
for its own question. Full parity cannot be claimed unless every named surface
has appropriate evidence; a green product check is not parity evidence.

Performance statements must point to the benchmark that supports them. Live
latency interpretations must distinguish provider/model time, prompt and output
shape, and Imp-local overhead.

## What Counts As Done

Imp has full parity evidence only when:

1. Golden trace parity is complete.
2. Live matched-model parity has at least one full current low-cost lane, one
   matched research-sample frontier sanity lane, and one matched
   research-sample historical/research-style lane.
3. Optimizer lift parity passes for every optimizer Imp exposes as production
   surface.
4. RAG/tool/agent production semantics pass deterministic and live slices.
5. Provider-free performance benchmarks support any speed claims.
6. Every named lane meets its own protocol and the cross-lane interpretation
   survives review of the underlying results.

Until then, honest language is narrower: Imp may have a passing smoke lane,
deterministic parity for specific surfaces, or performance wins on specific
provider-free paths.

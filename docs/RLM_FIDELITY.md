# RLM Fidelity

DSEx implements Recursive Language Models as a BEAM-native inference runtime,
not as RAG and not as a JSON action loop. The semantic references are DSPy
3.3.0b1 `dspy/predict/rlm.py` and *Recursive Language Models*
(arXiv:2512.24601v3).

## Required Semantics

- Large inputs live in an external variable environment instead of being copied
  into every controller prompt.
- One constrained interpreter persists assignments and computed values across
  controller turns.
- Code can invoke single and batched sub-LM calls from loops and
  comprehensions, retain their results symbolically, and submit computed values.
- Recursive children share one call ledger and absolute deadline while carrying
  immutable branch depth.
- Invalid code and submissions remain observable and repairable; exhausted
  iterations use a separate extraction pass.

Legacy discrete RLM action maps remain compatibility inputs. They are not the
primary implementation and do not define the fidelity claim.

## BEAM-Native Design

Controller source uses a deliberately constrained Elixir-shaped language.
`Code.string_to_quoted/2` is used only for parsing with atom-safe encoding;
generated source is never compiled or passed to `Code.eval_*`.

The interpreter is deterministic and external-effect free. An LM, batch, tool,
lazy load, or recursive call yields a typed effect request. The RLM runtime
executes that effect under the shared budget coordinator and OTP task
supervision, then resumes the pure turn through transactional replay of recorded
effect results. This supports effects inside nested expressions without storing
privileged closures in interpreter state.

The runtime enforces:

- source, AST-step, generated-value, cached-effect-data, effect-count, and
  printed-output limits;
- atomic LM call leases, charged only as workers begin;
- deterministic ordered batch results under bounded concurrency;
- one absolute deadline across queued batch waves and recursive children;
- branch-scoped recursion depth;
- cancellation of registered timed effects;
- bounded, redacted traces that replace oversized terms with type, size, and
  digest metadata.

## Evidence Tiers

### T0: Contract Replay

From a source checkout, `mix benchmark.rlm.check` runs two hand-authored
scripted rows. It checks harness
wiring only. Gold-derived outputs, tiny contexts, and intentionally different
traces make it ineligible for parity, effectiveness, latency, or uncertainty
claims.

### T1: Current-Upstream Operational Contract

From a source checkout, `mix benchmark.rlm.contract.check` executes twelve
required matched cases in
DSEx and DSPy 3.3.0b1 using deterministic controller and sub-LM responses. It
gates typed submission, persistent state, transformations, subqueries inside
programmatic loops, ordered batches, exact and atomic call accounting, repair,
extraction fallback, and trajectory retention. The artifact records the
installed DSPy source SHA256. DSEx `recurse/2` is declared as an extension rather
than fabricated as upstream behavior.

The T1 artifact proves operational semantics only.

### T2: Live Sampled Effectiveness

This tier requires preregistered samples from the paper task families, matched
root/submodel settings, no gold leakage, per-row trajectories, complete token
and cost accounting, task metrics, and paired uncertainty. The campaign runner
supports a manifest whose five family counts may be smaller than T3, but the
artifact remains labeled `t2_live_sample` and cannot pass the paper-scale gate.

### T3: Paper-Scale Reproduction

Release completion requires the paper protocol across S-NIAH, BrowseComp+,
OOLONG, OOLONG-Pairs, and LongBench-v2 CodeQA with the paper baselines, context
ranges, recursion depths, model roles, metrics, and documented deviations.

T3 has not been completed. The checked-in manifest and current runner are not
eligible for T3: they do not represent the standalone paper runtime, the exact
Base/CodeAct/iterative-compaction/coding-agent matrix, or separate RLM depths
0--3 across the paper's model blocks.
In addition, the paper's frozen S-NIAH instances, BrowseComp+ query/document
selection, and promised OOLONG-Pairs scorer are not public. Operator-generated
substitutes are useful T2 protocols but cannot satisfy the paper-exact T3 gate.
The upstream-fidelity ledger and dashboard therefore keep RLM red even when T0,
T1, deterministic tests, and live provider workflows pass.

## T2/T3 Campaign Runner

`benchmarks/config/rlm-paper-protocol-v3.json` is the preregistration authority
for ticket `de-m7aa`. It pins arXiv:2512.24601v3,
`alexzhang13/rlm@72d6940142ddfb84ee6be573dc999a37e633e671`, DSPy
3.3.0b1, audited source hashes, model roles, approach settings, budgets, seeds,
timeouts, and the paper context grid.

The checked-in manifest intentionally contains `ACQUIRE_AND_PIN_SHA256` and
`ACQUIRE_AND_FREEZE_IDS` for unavailable families. Planning, dry-run, and live
execution reject a selected unavailable family. A pinned family remains
runnable when unavailable families are excluded explicitly.

```console
mix dsex.benchmark.rlm_campaign --plan
mix dsex.benchmark.rlm_campaign --dry-run
mix dsex.benchmark.rlm_campaign --runtime dsex
mix dsex.benchmark.rlm_campaign --runtime dspy
mix dsex.benchmark.rlm_campaign --runtime both
mix dsex.benchmark.rlm_campaign --plan --family oolong \
  --approach direct,simple_retrieval,rlm --runtime both --row-limit 1
```

`--family` and `--approach` accept repeated or comma-separated values.
`--runtime` accepts `dsex`, `dspy`, or `both`. `--row-limit` is a positive,
per-family limit over frozen normalized row order; `--sample-limit` is an
alias. Plan output contains the exact ordered job keys and always reports zero
provider calls. The same normalized selection controls execution, checkpoint
identity, and artifact metadata. Changing any family, approach, runtime, or
limit fails checkpoint identity validation. Any filtered selection is labeled
`t2_live_sample` even when its source manifest requests T3.

There is no fixture/oracle execution mode. Before each external row dispatch,
the runner atomically writes an intent. It atomically replaces that intent with
the complete outcome only after validated output returns. A surviving intent
has an ambiguous external outcome, so resume fails closed instead of replaying
the row. Committed rows are checksum and identity bound and are never replayed.

Budgets are independent for every runtime/approach pair. Reservations happen
before every DSEx provider call, and the DSPy sidecar snapshots its remaining
ceiling inside the serialized budget section. Each wrapped DSPy LM permits one
in-flight dispatch through history capture, so a concurrent caller cannot read
another request's shared `history[-1]`. Root and submodel wrappers still share
active input/output/USD reservations. The DSPy LM constructor satisfies the
GPT-5 reasoning-model 16,000-token validation floor, while the budget wrapper
preserves the smaller manifest and remaining-output ceilings on every actual
dispatch through the provider-supported `max_completion_tokens` parameter.
The wrapper is a DSPy `BaseLM`, cache is disabled, and manifest reasoning
settings are passed explicitly.

Every dispatched request records its role, observed input and output dimensions,
USD, cost authority, and the exact pinned input/output rates. A positive,
finite provider cost is `provider_reported`; an absent or zero provider cost is
`pricing_derived` from observed dimensions. Zero USD is accepted only with an
explicit `free` authority. Invalid, inconsistent, or otherwise unprovable cost
is `unavailable` and cannot pass row validation or the mechanical gate. A
structured ReqLLM `cost` object is billing metadata rather than a scalar cost
alias; scalar aliases remain authoritative and conflicting scalar costs fail
closed. The row audit must reconcile request/root/sub counts, tokens, and USD
exactly to its totals. Usage-bearing provider errors remain charged terminal
rows even when only one token dimension is reported, and resume reconstructs
spend from successful and failed charged rows. Aggregate spend includes those
terminal rows. Missing usage or malformed output is terminal row evidence. Campaign
concurrency and row timeouts are manifest bounded; timeout or task failure
leaves the intent for an explicit operator audit.

Each successful row records answer score, wall latency, total provider calls,
root calls, subcalls, configured/observed depth, input and output tokens, USD
cost, trace shape, bounded trace data, and manifest/dataset provenance.
Aggregation is family scoped so unlike metrics are never pooled. OOLONG uses
the official numeric `0.75^abs(gold-prediction)` contract with exact matching
for nonnumeric answers. OOLONG-Pairs uses normalized unordered pair-set F1 and
bootstraps logical queries as clusters across context sizes. BrowseComp+ cannot
fall back to exact match: it requires the pinned official LLM answer judge plus
`trec_eval` evidence/gold retrieval provenance. The current runner does not yet
execute that judge contract, so `official_scorers` remains red.

### 2026-07-13 bounded live preflight

The first paid `v1` attempt used OOLONG `trec_coarse` sample `17000206` and
pinned `gpt-5-mini-2025-08-07`. It failed closed on structured ReqLLM cost
metadata and DSPy's GPT-5 constructor output-token validation. Its durable
intent was never resumed or replayed. Each subsequent semantic change used an
explicit campaign identity/version; no ambiguous intent was silently reused.

The resolved `v7` plan selected the same single frozen row, direct,
`simple_retrieval`, and RLM on both runtimes: exactly six jobs and zero provider
calls during `--plan`. The completed artifact is
`benchmarks/results/rlm-preflight/rlm-benchmark-parity-20260713T233641Z.json`;
its manifest, checkpoint, and audit use the `v7` campaign identity in the same
directory.

| Runtime | Approach | Score | Calls | Input | Output | USD | Latency ms | Cost authority |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| DSEx | direct | 0.0 | 1 | 92,567 | 128 | 0.00260400 | 2,806.564 | provider reported |
| DSEx | simple retrieval | 0.0 | 1 | 92,567 | 109 | 0.00256600 | 2,584.200 | provider reported |
| DSEx | RLM | 0.0 | 1 | 301 | 468 | 0.00101100 | 3,487.324 | provider reported |
| DSPy | direct | 0.0 | 1 | 92,571 | 88 | 0.02331875 | 4,907.162 | pricing derived |
| DSPy | simple retrieval | 0.0 | 1 | 92,571 | 152 | 0.02344675 | 5,052.278 | pricing derived |
| DSPy | RLM | 0.0 | 5 | 25,209 | 4,097 | 0.01449625 | 37,865.839 | pricing derived |

The six valid scored rows used 10 calls, 395,786 input tokens, 5,042 output
tokens, and $0.06744275 recorded cost. DSEx minus DSPy deltas were 0 score for
every approach; -2,100.598 ms and -$0.02071475 for direct; -2,468.078 ms and
-$0.02088075 for simple retrieval; and -34,378.515 ms, -$0.01348525, and four
fewer calls for RLM. The USD comparison is not billing parity: ReqLLM reported
DSEx cost directly, while DSPy cost was derived from the manifest's uncached
pinned rates.

This is valid T2 operational evidence only. Every answer scored zero, one row
cannot establish effectiveness, and the bootstrap interval is mechanically
zero-width. Simple retrieval selected effectively the full context on this
row, and neither RLM made recursive subcalls. The runtimes also expose different
`max_llm_calls` scopes. Traces are bounded and usage/cost audits reconcile, but
these limitations make expansion unjustified. The campaign was not expanded;
unavailable families and exact T3 remain red.

## Mechanical T3 Gate

Neither the runner nor dashboard trusts `paper_protocol_complete`. The shared
gate recomputes all of these conditions from artifact content:

- 50 S-NIAH, 150 BrowseComp+ rows with exactly 1,000 documents and evidence,
  50 OOLONG `trec_coarse`, 20 OOLONG-Pairs queries at all 11 context sizes, and
  50 LongBench-v2 CodeQA rows;
- the paper table's exact model-by-method matrix: Base, CodeAct+BM25,
  CodeAct+subcalls, iterative compaction agent, OpenCode with and without
  context offloading, and RLM depth 0--3 for GPT-5 and
  Qwen3-Coder-480B-A35B, plus Claude Code with and without context offloading
  for Claude Opus 4.1;
- both DSEx and the pinned standalone `alexzhang13/rlm` runtime, rather than a
  DSPy substitute;
- pinned paper/RLM/DSPy authorities and root, submodel, and compaction roles;
- exact unique dataset-key sets in every lane, pinned BrowseComp+ judge and
  `trec_eval` provenance, official OOLONG decay/exact scoring, OOLONG-Pairs
  pair-set F1, positive provider usage, reconciled per-request cost authority,
  valid bounded traces, and manifest/dataset provenance;
- explicit root/subcall/total-call/depth semantics with matched
  `max_llm_calls` scope, plus cache, reasoning, model-tree, and output-limit
  pins; and
- explicit deviation records.

The OOLONG-Pairs condition means 20 logical queries and 220 evaluated rows.
Duplicate rows cannot substitute for missing keys, and zero-usage rows cannot
count as provider evidence. Any partial family, missing context, malformed row,
unrepresented paper method, or false completion flag keeps the lane below full
evidence.

BrowseComp+ scorer metadata is insufficient by itself. Every row must bind the
pinned judge model and prompt hash to a judge-input digest and raw verdict, and
must carry qrels/run digests plus `trec_eval` version, evidence recall, gold
recall, and nDCG. Paper-exact authority additionally requires published frozen
S-NIAH instances, published BrowseComp+ IDs and document lists, and the
published OOLONG-Pairs `run_all.py` scorer with a pinned source hash. Those
sources are unavailable. Operator-generated RULER instances, BrowseComp+
samples, gold reconstructions, or scorer reimplementations must be disclosed as
T2 evidence and cannot satisfy T3.

## Recorded Deviations

- DSEx uses its constrained BEAM-native interpreter rather than Python syntax.
- The simple retrieval lane is deterministic lexical top-k and is not the
  paper's CodeAct+BM25 or CodeAct+subcalls baseline.
- The chunk-and-summarize lane is not the paper's iterative threshold-based
  compaction agent.
- The campaign currently runs one configured RLM depth and does not execute the
  paper's depth 0--3 matrix. DSEx bounds RLM-loop calls and separately meters a
  possible answer-extraction call; the campaign budget bounds their total.
  DSPy 3.3.0b1 counts subcalls. These scopes are recorded separately and
  mechanically fail equivalence.
- Rows use bounded campaign concurrency although the paper reports blocking,
  sequential calls; campaign wall time is therefore not paper-runtime parity.
- Python comparison uses the pinned DSPy 3.3.0b1 `dspy.RLM`, not the standalone
  reference package. It is operational comparison evidence only and cannot
  satisfy the T3 reference-runtime condition.

## Executable Evidence

- `test/rlm_interpreter_test.exs`
- `test/rlm_budget_test.exs`
- `test/rlm_test.exs`
- `test/rlm_contract_artifact_test.exs`
- `test/live_provider_e2e_test.exs`
- Source checkout: `mix benchmark.rlm.contract.check`
- Source checkout: `mix dsex.benchmark.rlm_campaign --plan`
- Source checkout: `LIVE_PROVIDER=1 mix live.check`

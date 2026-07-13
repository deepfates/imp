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

T3 has not been completed. The upstream-fidelity ledger and dashboard therefore
keep RLM red even when T0, T1, deterministic tests, and live provider workflows
pass.

## T2/T3 Campaign Runner

`benchmarks/config/rlm-paper-protocol-v3.json` is the preregistration authority
for ticket `de-m7aa`. It pins arXiv:2512.24601v3,
`alexzhang13/rlm@72d6940142ddfb84ee6be573dc999a37e633e671`, DSPy
3.3.0b1, audited source hashes, model roles, approach settings, budgets, seeds,
timeouts, and the paper context grid.

The checked-in manifest intentionally contains `ACQUIRE_AND_PIN_SHA256` and
`ACQUIRE_AND_FREEZE_IDS` for ignored/local datasets. Those values are accepted
only by `--plan`. Dry-run and live execution reject them.

```console
mix dsex.benchmark.rlm_campaign --plan
mix dsex.benchmark.rlm_campaign --dry-run
mix dsex.benchmark.rlm_campaign --runtime dsex
mix dsex.benchmark.rlm_campaign --runtime dspy
mix dsex.benchmark.rlm_campaign --runtime both
```

There is no fixture/oracle execution mode. Before each external row dispatch,
the runner atomically writes an intent. It atomically replaces that intent with
the complete outcome only after validated output returns. A surviving intent
has an ambiguous external outcome, so resume fails closed instead of replaying
the row. Committed rows are checksum and identity bound and are never replayed.

Budgets are independent for every runtime/approach pair. Reservations happen
before every DSEx provider call, observed provider token/cost usage is required,
and the DSPy sidecar independently applies the remaining ceiling. Missing usage
or malformed output is terminal row evidence. Campaign concurrency and row
timeouts are manifest bounded; timeout or task failure leaves the intent for an
explicit operator audit.

Each successful row records answer score, wall latency, request count, input and
output tokens, USD cost, trace shape, and bounded trace data. Aggregation uses a
deterministic paired nonparametric bootstrap over shared family/example keys.

## Mechanical T3 Gate

Neither the runner nor dashboard trusts `paper_protocol_complete`. The shared
gate recomputes all of these conditions from artifact content:

- 50 S-NIAH, 150 BrowseComp+ rows with exactly 1,000 documents and evidence,
  50 OOLONG `trec_coarse`, 20 OOLONG-Pairs queries at all 11 context sizes, and
  50 LongBench-v2 CodeQA rows;
- direct, simple retrieval/CodeAct-equivalent, compaction, and RLM outcomes for
  every selected runtime;
- both DSEx and DSPy RLM coverage for a cross-runtime T3 claim;
- pinned paper/RLM/DSPy authorities and root, submodel, and compaction roles;
- complete row usage, latency, score, and trace shapes; and
- explicit deviation records.

The OOLONG-Pairs condition means 20 logical queries and 220 evaluated rows.
Any partial family, missing context, malformed row, or false completion flag
keeps the lane below full evidence.

## Recorded Deviations

- DSEx uses its constrained BEAM-native interpreter rather than Python syntax.
- The simple retrieval lane is deterministic lexical top-k and is labeled a
  CodeAct equivalent, not exact paper CodeAct parity.
- Rows use bounded campaign concurrency although the paper reports blocking,
  sequential calls; campaign wall time is therefore not paper-runtime parity.
- Python comparison uses the pinned DSPy 3.3.0b1 `dspy.RLM`, not the standalone
  reference package, so prompt and interpreter trajectories are not asserted to
  be identical.

## Executable Evidence

- `test/rlm_interpreter_test.exs`
- `test/rlm_budget_test.exs`
- `test/rlm_test.exs`
- `test/rlm_contract_artifact_test.exs`
- `test/live_provider_e2e_test.exs`
- Source checkout: `mix benchmark.rlm.contract.check`
- Source checkout: `mix dsex.benchmark.rlm_campaign --plan`
- Source checkout: `LIVE_PROVIDER=1 mix live.check`

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
and cost accounting, task metrics, and paired uncertainty.

### T3: Paper-Scale Reproduction

Release completion requires the paper protocol across S-NIAH, BrowseComp+,
OOLONG, OOLONG-Pairs, and LongBench-v2 CodeQA with the paper baselines, context
ranges, recursion depths, model roles, metrics, and documented deviations.

T3 has not been completed. The upstream-fidelity ledger and dashboard therefore
keep RLM red even when T0, T1, deterministic tests, and live provider workflows
pass.

## Executable Evidence

- `test/rlm_interpreter_test.exs`
- `test/rlm_budget_test.exs`
- `test/rlm_test.exs`
- `test/rlm_contract_artifact_test.exs`
- `test/live_provider_e2e_test.exs`
- Source checkout: `mix benchmark.rlm.contract.check`
- Source checkout: `LIVE_PROVIDER=1 mix live.check`

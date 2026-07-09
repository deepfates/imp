# Upstream Fidelity Audit

This file tracks the current DSEx audit against modern DSPy, GEPA, and
optimize_anything. It is not a claim that every row is complete. It is the
working map for finding gaps before making production or research-comparison
claims.

## Source Anchors

- DSPy public docs and API reference: <https://dspy.ai/>
- DSPy RLM docs: <https://dspy.ai/diving-deeper/rlm/>
- DeepWiki `stanfordnlp/dspy`, indexed 2026-06-14:
  <https://deepwiki.com/stanfordnlp/dspy>
- DSP paper: `arXiv:2212.14024`
- DSPy paper: `arXiv:2310.03714`
- DSPy Assertions paper: `arXiv:2312.13382`
- MIPROv2 paper: `arXiv:2406.11695`
- GEPA paper: `arXiv:2507.19457`
- RLM paper: `arXiv:2512.24601`
- optimize_anything paper: `arXiv:2605.19633`
- GEPA / optimize_anything repo: <https://github.com/gepa-ai/gepa>

## Audit Rule

Every upstream surface must land in exactly one state:

- `implemented`: DSEx has code, docs, tests, and appropriate evidence.
- `needs-work`: a ticket exists with source references and acceptance criteria.
- `intentional-omission`: DSEx explicitly does not claim the surface, with a
  reason and public-claim guardrail.

Unmapped upstream surfaces are release blockers for comparative claims.

The source checkout enforces this with:

```sh
mix upstream_fidelity.check
```

The underlying task writes a JSON artifact and fails when any tracked upstream
surface is unmapped:

```sh
mix dsex.upstream_fidelity --out tmp/upstream-fidelity/upstream-fidelity.json --require-mapped
```

The current generated maintainer-readable map is
[Upstream Surface Map](UPSTREAM_SURFACE_MAP.md).

## Current Open Blockers

| Area | Current finding | Ticket |
| --- | --- | --- |
| GEPA research evidence | DSEx now has a strict GEPA paper-replication artifact lane and dashboard claim gate for AIMEBench, HotpotQABench, hoverBench, IFBench, LiveBenchMathBench, and Papillon rows with optimizer, budget, cost, seed, and split-gap fields. Fresh paid/source-checkout campaign rows are still required before making GEPA dominance claims. | `de-izej` |
| GEPA canonical data and adapters | The GEPA dataset exporter and metric adapters exist, but source-exact closure waits on IFBench upstream parity and HoVer BM25/wiki retrieval-corpus parity. | `de-4k3l`, `de-m5o2`, `de-izg6`, `de-7f6h` |
| GEPA campaign runner | DSEx can produce strict `dsex_gepa` rows from a dataset root, but the ticket requires a fresh six-family provider campaign artifact, not fixture/static-LM evidence. | `de-8nbo`, `de-b10z` |
| optimize_anything evidence | DSEx has arbitrary artifact optimization APIs, but not replication across non-prompt artifact classes. | `de-16fo` |
| Multimodal | DSEx has encoding primitives and operations stress, but not live multimodal quality benchmarks. | `de-ezg9` |
| Optimizer completeness | InferRules and exact semantics for less-emphasized optimizer variants need explicit mapping. | `de-9x31` |
| ReAct/CodeAct/PoT | Existing implementations need a current-source fidelity audit, including ReActV2 behavior. | `de-3uxx` |
| Runtime | Settings, cache, async, streaming, and performance semantics need a current DSPy comparison. | `de-tt5j` |
| Persistence/deployment | Save/load, compiled artifacts, credential rebinding, package usage, and deployment semantics need source-level parity mapping. | `de-g3wa` |
| Observability | `inspect_history`, status messages, optimizer tracking, logging controls, and DSEx telemetry/dashboard need a user-facing equivalence audit. | `de-xt9k` |
| Tutorials/examples | The dspy.ai tutorial and real-world-example surface needs mapping to DSEx docs, Livebooks, examples, benchmarks, or omissions. | `de-lof6` |

## Closed Evidence

Recent closed tickets established the generated upstream surface gate, RLM
semantic and benchmark coverage, assertions/refinement behavior, history
serialization, native reasoning metadata, tool-call primitives, adapter parity,
evaluation/metric helpers, and retrieval/vector protocol mappings. Those rows
remain important evidence, but they are no longer listed as open blockers here.

## Execution Order

1. Build the generated upstream surface diff (`de-0mhi`).
2. Use it to complete the no-blind-spots audit (`de-9mcw`).
3. Start semantic implementation work on the highest-risk surfaces:
   RLM (`de-ciht`), GEPA replication (`de-izej`), optimize_anything replication
   (`de-16fo`), and assertions (`de-b79l`).
4. Add benchmark lanes only after the underlying semantic surface is honest.
5. Let dashboard/public claims pass only from fresh evidence artifacts.

## Claim Discipline

Until the open blockers above are closed, DSEx can claim broad product-quality
parity for the already-gated surface, but it should not claim complete modern
DSPy, GEPA, RLM, or optimize_anything research dominance.

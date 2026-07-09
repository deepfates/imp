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

## Current High-Risk Gaps

| Area | Current finding | Ticket |
| --- | --- | --- |
| Upstream diffing | DSEx now has a generated 120-surface upstream-fidelity artifact and a local gate; future work should automate manifest refresh from upstream docs/source. | `de-0mhi` |
| No-blind-spots audit | The previous audit missed RLM depth until prompted. Every dspy.ai and DeepWiki category needs explicit mapping. | `de-9mcw` |
| RLM semantics | DSEx now covers the upstream RLM semantic checklist: persistent variable-space loop, explicit lazy loading, `llm_query_batched`, sub-LM call budgets, invalid-submit retry, extract fallback, and optimizer-visible internal predictors. | `de-ciht` |
| RLM benchmarks | DSEx now has a provider-free HotPotQA-shaped RLM benchmark lane comparing DSEx RLM, Python DSPy RLM, direct prompting, and simple RAG. Live model-quality RLM campaigns remain a separate scale-up question. | `de-m7aa` |
| GEPA research evidence | DSEx has GEPA-style optimizer coverage, but not paper-level GEPA replication against DSPy GEPA on public tasks/models/budgets. | `de-izej` |
| optimize_anything evidence | DSEx has arbitrary artifact optimization APIs, but not replication across non-prompt artifact classes. | `de-16fo` |
| Assertions | Schema validation is not equivalent to DSPy Assertions and self-refinement behavior. | `de-b79l` |
| History | DSEx has a `History` type, but not yet a fully audited conversation-management surface. | `de-vm37` |
| Native reasoning/BaseLM | DSEx has LM behaviours and reasoning types, but needs explicit parity around typed LM surfaces and provider-native reasoning fields. | `de-erg0` |
| ToolCalls | DSEx has tool-call structs and ReAct paths, but primitive-level provider-native tool-call round trips need explicit tests/evidence. | `de-e84o` |
| Multimodal | DSEx has encoding primitives and operations stress, but not live multimodal quality benchmarks. | `de-ezg9` |
| Optimizer completeness | InferRules and exact semantics for less-emphasized optimizer variants need explicit mapping. | `de-9x31` |
| ReAct/CodeAct/PoT | Existing implementations need a current-source fidelity audit, including ReActV2 behavior. | `de-3uxx` |
| Adapters | Chat/JSON/XML/TwoStep behavior is now audited against current DSPy docs, including delimiter formatting, JSON fallback, demos/history, provider-native tool-call ownership, and intentional DSEx deviations. | `de-t3uh` |
| Evaluation/metrics | Evaluate, SemanticF1, CompleteAndGrounded, feedback-rich metrics, and aggregate behavior need source-level parity mapping. | `de-bova` |
| Retrieval/vector DBs | ColBERTv2, embeddings, KNN, KNNFewShot, external stores, and multi-hop RAG need explicit mapping and evidence. | `de-c2we` |
| Runtime | Settings, cache, async, streaming, and performance semantics need a current DSPy comparison. | `de-tt5j` |
| Persistence/deployment | Save/load, compiled artifacts, credential rebinding, package usage, and deployment semantics need source-level parity mapping. | `de-g3wa` |
| Observability | `inspect_history`, status messages, optimizer tracking, logging controls, and DSEx telemetry/dashboard need a user-facing equivalence audit. | `de-xt9k` |
| Tutorials/examples | The dspy.ai tutorial and real-world-example surface needs mapping to DSEx docs, Livebooks, examples, benchmarks, or omissions. | `de-lof6` |

## Execution Order

1. Build the generated upstream surface diff (`de-0mhi`).
2. Use it to complete the no-blind-spots audit (`de-9mcw`).
3. Start semantic implementation work on the highest-risk surfaces:
   RLM (`de-ciht`), GEPA replication (`de-izej`), optimize_anything replication
   (`de-16fo`), and assertions (`de-b79l`).
4. Add benchmark lanes only after the underlying semantic surface is honest.
5. Let dashboard/public claims pass only from fresh evidence artifacts.

## Claim Discipline

Until the tickets above are closed, DSEx can claim broad product-quality parity
for the already-gated surface, but it should not claim complete modern DSPy,
GEPA, RLM, or optimize_anything research dominance.

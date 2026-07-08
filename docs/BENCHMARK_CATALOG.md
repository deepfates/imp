# Benchmark Catalog

This catalog is the outside-view map for DSEx benchmark evidence. It answers a
different question than the release dashboard:

- the dashboard asks whether current evidence is enough for a release claim;
- this catalog asks whether DSEx is sampling the right task families from the
  DSPy literature, docs, and examples.

The goal is broad, cheap, repeatable sanity first. Full campaigns are reserved
for lanes where the smoke and research tiers show that DSEx is in the same
effectiveness ballpark as Python DSPy.

## Workflow

Each benchmark family should move through the same four stages.

| Stage | Meaning | Expected cost |
| --- | --- | --- |
| Cataloged | Source, dataset, metric, DSEx surface, and DSPy surface are named. | Free |
| Sampled | DSEx can fetch or materialize a deterministic `jsonl` sample with a manifest. | Free or cheap network |
| Matched smoke | DSEx and Python DSPy run the same 2-20 rows with the same provider/model or provider-free oracle. | Cheap |
| Research slice | DSEx and Python DSPy run enough rows to catch systematic failures, usually 100-300 examples or a task-specific equivalent. | Moderate |
| Full lane | A full split or paper-scale run is executed only when it supports a release or paper-quality claim. | Expensive |

The sampling harness must preserve:

- source URL and dataset/config/split;
- offset, length, and SHA256 digest;
- input fields and label fields;
- metric contract;
- program shape, such as `Predict`, `ChainOfThought`, ReAct, RAG, or optimizer
  compile;
- whether the lane is provider-free, live matched DSEx-vs-DSPy, DSEx-only
  production semantics, or intentionally unavailable.

## Current Coverage

| Family | Source lineage | DSEx status | Runner evidence | Next useful step |
| --- | --- | --- | --- | --- |
| Math word problems | DSPy paper and docs use GSM8K-style chain-of-thought examples. | Implemented | `mix benchmark.truth.check`, `mix benchmark.parity.check`, `mix benchmark.parity.full` | Keep as canonical low-cost/full lane. |
| Multi-hop QA | DSPy/DSP lineage centers retrieval-heavy HotPotQA and Baleen-style QA. | Implemented for provided-context HotPotQA; provider-free RAG smoke exists. | `mix benchmark.truth.check`, `mix benchmark.rag_tool_agent.check`, live parity campaigns | Add at least one retrieval-indexed HotPotQA/Baleen-style sampled lane, not only provided-context QA. |
| Color/classification | DSPy public dataset lineage includes simple Colors-style classification. | Loader exists; not a benchmark gate. | Dataset contract tests only | Add cheap matched smoke and optimizer-lift classification lane. |
| RAG/retrieval | DSP and DSPy papers emphasize retrieval + generation for knowledge-intensive QA. | Provider-free deterministic RAG and retriever protocol gates exist. | `mix benchmark.rag_tool_agent.check`, `mix protocol.retriever.check` | Add real small corpus retrieval benchmark with recall/F1, then matched DSEx/DSPy generation. |
| Tool and ReAct agents | DSPy docs present tools and agents as first-class programming workflows. | Provider-free parity and local integration exist. | `mix benchmark.trace.check`, `mix benchmark.rag_tool_agent.check`, `mix integration.check` | Add sampled task set with measurable tool-use success, not just fixture replay. |
| RLM recursive control | DSEx-native recursive controller inspired by DSP-style modular inference, distinct from RAG. | Deterministic public-surface, budget, recursion, tool, sandbox, redaction, and integration coverage exists. | `mix test test/rlm_test.exs`, `mix benchmark.rag_tool_agent.check`, `mix integration.check` | Add sampled controller tasks that measure action success, budget use, and answer quality across larger contexts. |
| Program composition and orchestration | DSPy modules compose predictors, ensembles, comparison, refinement, parallel fan-out, and retrieval-aware variants. | Provider-free sampled orchestration benchmark exists for BestOfN, Refine, MultiChainComparison, Ensemble, KNN, and Parallel; selected live orchestration coverage also exists. | `mix dsex.benchmark.fetch --tasks composition_orchestration --full --out benchmarks/data`, `mix dsex.benchmark.run --composition-orchestration benchmarks/data/composition_orchestration-test-0-3.jsonl`, `mix test test/public_surface_test.exs test/refine_feedback_test.exs` | Extend sampled orchestration to matched DSEx/DSPy live-provider comparison once cost and model policy are selected. |
| Adapters, streaming, and structured I/O | DSPy adapters and Ax-style signatures make parsing, schema negotiation, retries, and streaming part of the programming contract. | Provider-free trace, deterministic schema, ReqLLM, and live streaming coverage exists. | `mix benchmark.trace.check`, `mix test test/schema_constraints_test.exs test/req_llm_client_test.exs`, `LIVE_PROVIDER=1 mix live.check` | Add adversarial structured-output samples with malformed JSON/XML/chat, partial streams, and provider-native schema fallbacks. |
| Persistence, cache, telemetry, and OTP operations | Production DSP-style systems need save/load, cache behavior, redaction, observability, and supervised concurrency outside notebooks. | Deterministic production, integration, and overhead coverage exists. | `mix production.check`, `mix integration.check`, `mix benchmark.overhead.check` | Add lifecycle stress scenarios that combine save/load, cache, telemetry, streaming, and parallel execution in one sampled workflow. |
| Multimodal primitives | Modern provider surfaces include image, audio, file, document, and code content blocks. | Deterministic encoding/decoding primitive coverage exists. | `mix test test/multimodal_adapter_test.exs` | Keep as primitive proof until DSEx claims live multimodal reasoning. |
| Optimizer lift | DSPy optimizer docs cover few-shot bootstrapping, instruction/demo search, MIPROv2, GEPA, and finetuning workflows. | Provider-free deterministic lift implemented. | `mix benchmark.optimizer_lift.check` | Add real sampled classification/QA optimizer lift lanes so improvement is tested on natural data. |
| Hallucination/factuality classification | DSPy optimizer comparison papers use CovidQA, PubMedQA, DROP, FinanceBench, and similar labeled QA/factuality tasks. | Not implemented as fetchable benchmark lanes. | None | Add a generic classification/QA sampler and metric adapters for exact/F1/macro-F1. |
| MIPRO tabular classification | MIPRO optimizer benchmarks include Iris, Iris-Typo, and Heart Disease. | Not implemented as benchmark lanes. | None | Add tiny full-split samplers and optimizer-lift runs. |
| ScoNe logical classification | MIPRO optimizer benchmarks include ScoNe. | Not implemented as benchmark lane. | None | Pin a public dataset source and add accuracy metric. |
| HoVer claim verification | MIPRO and GEPA benchmark lineage includes HoVer multi-hop verification. | Not implemented as benchmark lane. | None | Add HoVer sampler and retrieval-aware metric after source/license check. |
| IFBench instruction following | GEPA benchmark lineage includes verifiable instruction following. | Not implemented as benchmark lane. | None | Add IFBench sampler and verifier-backed metric. |
| Hard math/competition reasoning | GEPA and modern optimizer work often uses AIME/MATH-style tasks. | `DSEx.Datasets.MATH` loader exists; no benchmark fetch or parity runner. | Loader tests only | Add MATH/AIME-style sampler and small CoT matched smoke. |
| Privacy-conscious delegation | GEPA/PAPILLON/PUPA lineage evaluates useful delegation without leaking private information. | Not implemented as benchmark lane. | None | Start with synthetic PII smoke before adopting licensed research data. |
| LiveBench-Math | GEPA benchmark lineage includes date-versioned LiveBench-Math. | Deferred. | None | Adopt only with a frozen dated snapshot to avoid moving-target evidence. |
| Long-form writing / STORM-style research | DSPy-related paper list includes writing Wikipedia-like articles from scratch. | Out of current product proof. | None | Track as deferred; do not block production unless DSEx claims long-form writing optimization. |
| Extreme multi-label classification | DSPy-related paper list includes in-context learning for XML classification. | Out of current product proof. | None | Track as deferred; useful after core classification sampler exists. |
| Finetuning / BetterTogether / GRPO | DSPy paper list and docs include finetuning plus prompt optimization. | Protocol-compatible trainer lifecycle exists; paid provider training is not claimed. | `mix protocol.training.check`, optimizer deviation notes | Add explicit external-provider training benchmark only if DSEx claims paid training parity. |

## Prioritized Additions

1. **Generic benchmark catalog artifact.** Add a machine-readable catalog that
   emits the table above as JSON for dashboards and tickets.
2. **Classification/factuality sampler.** Support Colors, Iris/Iris-Typo,
   Heart Disease, PubMedQA/CovidQA-like binary or multiclass rows, and macro-F1
   metrics.
3. **Retrieval-indexed QA and verification sampler.** Add a tiny corpus + query
   + answer/label format for HotPotQA/Baleen-style QA and HoVer-style
   verification
   that can run DSEx retrieval and DSPy retrieval over the same rows.
4. **Tool/ReAct/RLM task sampler.** Add measurable tool-use and recursive
   controller tasks so ReAct and RLM are tested by outcomes, traces, budget
   adherence, and policy behavior rather than only fixture replay.
5. **Structured I/O and operations stress.** Add adversarial adapter/streaming
   samples plus lifecycle workflows that combine save/load, cache, telemetry,
   redaction, and supervised concurrency.
6. **Natural-data optimizer lift.** Run baseline and compiled programs on
   classification, QA, and instruction-following samples, comparing lift rather
   than exact prompt text.
7. **Hard math sampler.** Add MATH/AIME-style rows for CoT smoke and optimizer
   sanity.

## Sources

Primary sources to keep the catalog grounded:

- DSPy repository and paper list:
  <https://github.com/stanfordnlp/dspy>
- DSPy docs:
  <https://dspy.ai/>
- DSPy optimizer docs:
  <https://github.com/stanfordnlp/dspy/blob/main/docs/docs/learn/optimization/optimizers.md>
- DSPy ICLR paper:
  <https://arxiv.org/abs/2310.03714>
- MIPROv2 docs:
  <https://dspy.ai/api/optimizers/MIPROv2/>
- MIPRO paper:
  <https://arxiv.org/abs/2406.11695>
- GEPA paper:
  <https://arxiv.org/abs/2507.19457>
- Demonstrate-Search-Predict paper:
  <https://arxiv.org/abs/2212.14024>

Secondary sources, useful for candidate benchmark families but not release
authority by themselves:

- Comparative DSPy optimizer studies that mention CovidQA, PubMedQA, DROP, and
  FinanceBench-style labeled QA/factuality tasks.
- GEPA and optimize-anything materials for reflective artifact optimization and
  hard reasoning benchmark candidates.

# Benchmark Catalog

This catalog is the outside-view map for Imp benchmark evidence. It answers a
different question than the release dashboard:

- the dashboard asks whether current evidence is enough for a release claim;
- this catalog asks whether Imp is sampling the right task families from the
  DSPy literature, docs, and examples.

The machine-readable public claim inventory lives in `benchmarks/claims.json`;
see `docs/BENCHMARK_CLAIMS.md` for the dashboard claim-gate operating loop.

The commands in this document are source-checkout evidence commands for Imp
maintainers. They are not part of the Hex package API or a normal application
install path.

The goal is broad, cheap, repeatable sanity first. Full campaigns are reserved
for lanes where the smoke and research tiers show that Imp is in the same
effectiveness ballpark as Python DSPy.

## Workflow

Each benchmark family should move through the same four stages.

| Stage | Meaning | Expected cost |
| --- | --- | --- |
| Cataloged | Source, dataset, metric, Imp surface, and DSPy surface are named. | Free |
| Sampled | Imp can fetch or materialize a deterministic `jsonl` sample with a manifest. | Free or cheap network |
| Matched smoke | Imp and Python DSPy run the same 2-20 rows with the same provider/model or provider-free oracle. | Cheap |
| Research slice | Imp and Python DSPy run enough rows to catch systematic failures, usually 100-300 examples or a task-specific equivalent. | Moderate |
| Full lane | A full split or paper-scale run is executed only when it supports a release or paper-quality claim. | Expensive |

The sampling harness must preserve:

- source URL and dataset/config/split;
- offset, length, and SHA256 digest;
- input fields and label fields;
- metric contract;
- program shape, such as `Predict`, `ChainOfThought`, ReAct, RAG, or optimizer
  compile;
- whether the lane is provider-free, live matched Imp-vs-DSPy, Imp-only
  production semantics, or intentionally unavailable.

## Current Coverage

| Family | Source lineage | Imp status | Runner evidence | Next useful step |
| --- | --- | --- | --- | --- |
| Math word problems | DSPy paper and docs use GSM8K-style chain-of-thought examples. | Implemented | `mix benchmark.truth.check`, `mix benchmark.parity.check`, `mix benchmark.parity.full` | Keep as canonical low-cost/full lane. |
| Multi-hop QA | DSPy/DSP lineage centers retrieval-heavy HotPotQA and Baleen-style QA. | Provider-free HotPotQA-shaped QA and deterministic multi-hop RAG evidence exist. | `mix benchmark.truth.check`, `mix benchmark.rag_tool_agent.check`, live parity campaigns | Scale retrieval-indexed HotPotQA/Baleen-style sampled lanes when research-tier model-quality evidence is required. |
| Color/classification | DSPy public dataset lineage includes simple Colors-style classification. | Provider-free Colors/Iris/Iris-Typo/Heart Disease samplers and runner smoke exist with accuracy and macro/micro/weighted F1 reports; optimizer-lift artifact also includes a passing natural classification lane. | `mix imp.benchmark.fetch --tasks colors,iris,iris_typo,heart_disease --full --out benchmarks/data`, `mix imp.benchmark.run --colors benchmarks/data/colors-test-0-6.jsonl --iris benchmarks/data/iris-test-0-6.jsonl --iris-typo benchmarks/data/iris_typo-test-0-3.jsonl --heart-disease benchmarks/data/heart_disease-test-0-4.jsonl`, `mix benchmark.truth.check`, `mix benchmark.optimizer_lift.check` | Scale to larger pinned classification/factuality datasets when research-tier evidence is required. |
| RAG/retrieval | DSP and DSPy papers emphasize retrieval + generation for knowledge-intensive QA. | Provider-free deterministic one-shot RAG, multi-hop RAG, and retriever protocol gates exist; bounded matched-live mode is implemented and fails closed without complete usage/control evidence. | `mix benchmark.rag_tool_agent.check`, `mix imp.benchmark.rag_tool_agent --live ...`, `mix protocol.retriever.check` | Complete the bounded live artifact when provider quota is available, then scale retrieval corpora only for research-tier quality claims. |
| Tool and ReAct agents | DSPy docs present tools and agents as first-class programming workflows. | Provider-free parity, local integration, real-provider HTTP MCP composition, and matched-live artifact controls exist. The current full artifact remains red after provider quota rejection. | `mix benchmark.trace.check`, `mix benchmark.rag_tool_agent.check`, `mix imp.benchmark.rag_tool_agent --live ...`, `mix integration.check`, `LIVE_PROVIDER=1 mix live.check` | Admit the bounded 15/15 live artifact, then add larger measurable tool-use samples only if the public claim requires research-tier scale. |
| RLM recursive control | DSPy RLM docs and paper position recursive controller loops as long-context inference over variable space, distinct from RAG. | BEAM-native symbolic execution and live sub-LM proof exist. T1 gates twelve operational contracts against DSPy 3.3.0b1 with source hashing; T0 remains fixture replay. Neither is effectiveness evidence. | `mix benchmark.rlm.contract.check`, `mix benchmark.rlm.check`, `mix test test/rlm_test.exs`, `LIVE_PROVIDER=1 mix live.check` | Add live sampled effectiveness and complete the T3 paper-scale RLM protocol. |
| Program composition and orchestration | DSPy modules compose predictors, ensembles, comparison, refinement, parallel fan-out, and retrieval-aware variants. | Provider-free sampled orchestration benchmark exists for BestOfN, Refine, MultiChainComparison, Ensemble, KNN, and Parallel; selected live orchestration coverage also exists. | `mix imp.benchmark.fetch --tasks composition_orchestration --full --out benchmarks/data`, `mix imp.benchmark.run --composition-orchestration benchmarks/data/composition_orchestration-test-0-3.jsonl`, `mix test test/public_surface_test.exs test/refine_feedback_test.exs` | Extend sampled orchestration to matched Imp/DSPy live-provider comparison once cost and model policy are selected. |
| Adapters, streaming, and structured I/O | DSPy adapters and Ax-style signatures make parsing, schema negotiation, retries, and streaming part of the programming contract. | Provider-free operations stress now covers malformed JSON/XML/chat, partial streams, and native schema option shape; trace/schema/ReqLLM/live coverage also exists. | `mix benchmark.operations_stress.check`, `mix benchmark.trace.check`, `mix test test/schema_constraints_test.exs test/req_llm_client_test.exs`, `LIVE_PROVIDER=1 mix live.check` | Extend adversarial structured-output stress to matched live-provider drift checks when release policy requires it. |
| Persistence, cache, telemetry, and OTP operations | Production DSP-style systems need save/load, cache behavior, redaction, observability, and supervised concurrency outside notebooks. | Provider-free operations stress covers save/load, cache hit/miss telemetry, and redaction. The repeated T0 failure campaign adds cancellation, bounded admission, terminal partial-stream failures, checkpoint/tamper recovery, flake rates, and leak accounting while keeping two required live lanes red. | `mix benchmark.operations_stress.check`, `mix benchmark.failure_campaign.check`, `mix production.check`, `mix integration.check`, `mix benchmark.overhead.check` | Run the live provider/training recovery lanes, then extend lifecycle stress to long-running supervised service soak tests. |
| Multimodal primitives | Modern provider surfaces include image, audio, file, document, and code content blocks. | Deterministic encoding/decoding primitive coverage exists; operations stress explicitly records that live multimodal reasoning is not claimed. | `mix test test/multimodal_adapter_test.exs`, `mix benchmark.operations_stress.check` | Add a provider-backed multimodal benchmark only if public docs claim live multimodal reasoning. |
| Optimizer lift | DSPy optimizer docs cover few-shot bootstrapping, instruction/demo search, MIPROv2, GEPA, and finetuning workflows. | Provider-free lift and natural-task evidence exist. A pinned DSPy 3.3.0b1 structural differential gate now covers MIPROv2 and SIMBA control flow, but only a fresh passing artifact satisfies T1. Neither lane proves full optimizer parity. | `mix benchmark.optimizer_lift.check`, `mix benchmark.instruction_optimizer.contract.check` | Keep the structural artifact fresh, then run held-out multi-seed effectiveness campaigns under matched provider, metric, and cost budgets. |
| Optimize Anything non-prompt artifacts | Optimize Anything and GEPA generalize reflective optimization from prompts to measurable text artifacts. | Production Imp runner plus executable code, agent-configuration, and scheduling evaluators exist. The live campaign requires three seeds, positive mean lift, a majority of improving runs, provider usage/cost, and checkpoint provenance. | `mix benchmark.optimize_anything.check`, `mix imp.benchmark.optimize_anything --live ...` | Broaden to matched public upstream artifact tasks only when making a paper-scale or implementation-comparison claim. |
| GEPA paper replication | GEPA artifact repo covers AIMEBench, HotpotQABench, hoverBench, IFBench, LiveBenchMathBench, and Papillon. | Artifact contract, dataset exporter, upstream artifact ingestion, pinned source-exact HoVer Python BM25S retrieval, explicitly approximate native HoVer BM25, HoVer LM query generation, and Imp-side capped live campaign rows exist; full claims remain blocked on uncapped Imp rows. The contract rejects capped dataset roots for full research claims. | `mix benchmark.gepa_replication.check`, `mix imp.benchmark.gepa_dataset`, `mix imp.benchmark.gepa_campaign`, `mix imp.benchmark.gepa_replication --from-gepa-artifact ...` | Run full uncapped Imp-vs-DSPy GEPA campaigns with exact model, budget, cost, seed, and split-gap metadata. |
| Hallucination/factuality classification | DSPy optimizer comparison papers use CovidQA, PubMedQA, DROP, FinanceBench, and similar labeled QA/factuality tasks. | Not implemented as fetchable benchmark lanes. | None | Add a generic classification/QA sampler and metric adapters for exact/F1/macro-F1. |
| MIPRO tabular classification | MIPRO optimizer benchmarks include Iris, Iris-Typo, and Heart Disease. | Tiny provider-free samplers and runner smoke exist; MIPRO-specific scaled optimizer evidence is still missing. | `mix imp.benchmark.fetch --tasks iris,iris_typo,heart_disease --full --out benchmarks/data`, `mix imp.benchmark.run --iris benchmarks/data/iris-test-0-6.jsonl --iris-typo benchmarks/data/iris_typo-test-0-3.jsonl --heart-disease benchmarks/data/heart_disease-test-0-4.jsonl` | Add optimizer-lift runs and larger pinned slices when making MIPRO tabular claims. |
| ScoNe logical classification | MIPRO optimizer benchmarks include ScoNe. | Not implemented as benchmark lane. | None | Pin a public dataset source and add accuracy metric. |
| HoVer claim verification | MIPRO and GEPA benchmark lineage includes HoVer multi-hop verification. | GEPA exporter and metric adapter use the upstream `retrieved_docs` contract; source-exact BM25/wiki corpus and index are reproducible locally, with an upstream-python campaign path to avoid loading the full corpus in the BEAM. Imp HoVer campaign rows now generate LM queries and report positive usage accounting, but full GEPA claims still require uncapped rows. | `mix imp.benchmark.gepa_dataset`, `IMP_HOVER_UPSTREAM_BM25=1 mix imp.benchmark.gepa_campaign` | Run uncapped HoVer GEPA campaign rows with source-exact upstream BM25 retrieval and positive usage accounting. |
| IFBench instruction following | GEPA benchmark lineage includes verifiable instruction following. | Provider-free local verifier smoke exists with executable constraint scoring. | `mix imp.benchmark.fetch --tasks ifbench_instruction_following --full --out benchmarks/data`, `mix imp.benchmark.run --ifbench-instruction-following benchmarks/data/ifbench_instruction_following-test-0-3.jsonl`, `mix benchmark.truth.check` | Scale to a pinned IFBench snapshot when research-tier evidence is required. |
| Hard math/competition reasoning | GEPA and modern optimizer work often uses AIME/MATH-style tasks. | Provider-free AIME/MATH-style smoke exists with normalized exact answer scoring. | `mix imp.benchmark.fetch --tasks hard_math --full --out benchmarks/data`, `mix imp.benchmark.run --hard-math benchmarks/data/hard_math-test-0-3.jsonl`, `mix benchmark.truth.check` | Scale to pinned public MATH/AIME snapshots for research-tier evidence. |
| Privacy-conscious delegation | GEPA/PAPILLON/PUPA lineage evaluates useful delegation without leaking private information. | Not implemented as benchmark lane. | None | Start with synthetic PII smoke before adopting licensed research data. |
| LiveBench-Math | GEPA benchmark lineage includes date-versioned LiveBench-Math. | Deferred. | None | Adopt only with a frozen dated snapshot to avoid moving-target evidence. |
| Long-form writing / STORM-style research | DSPy-related paper list includes writing Wikipedia-like articles from scratch. | Out of current product proof. | None | Track as deferred; do not block production unless Imp claims long-form writing optimization. |
| Extreme multi-label classification | DSPy-related paper list includes in-context learning for XML classification. | Out of current product proof. | None | Track as deferred; useful after core classification sampler exists. |
| Finetuning / BetterTogether / GRPO | DSPy paper list and docs include finetuning plus prompt optimization. | Protocol-compatible lifecycle plus pinned local MLX LoRA effectiveness and fused save/load rebinding; paid-provider and matched DSPy parity remain unproved. | `mix protocol.training.check`, `mix imp.benchmark.local_mlx`, `mix benchmark.optimizer_lift.check` | Retain paid-provider and BetterTogether parity as explicit gaps until matched campaigns pass. |

## Prioritized Additions

1. **Catalog-to-dashboard integration.** The machine-readable catalog exists;
   connect it to ticket and dashboard views so stale prose cannot drift from
   executable evidence.
2. **Classification/factuality sampler.** Support Colors, Iris/Iris-Typo,
   Heart Disease, PubMedQA/CovidQA-like binary or multiclass rows, and macro-F1
   metrics.
3. **Retrieval-indexed QA and verification sampler.** Add a tiny corpus + query
   + answer/label format for HotPotQA/Baleen-style QA and HoVer-style
   verification
   that can run Imp retrieval and DSPy retrieval over the same rows.
4. **Tool/ReAct/RLM task sampler.** Add measurable tool-use and recursive
   controller tasks so ReAct and RLM are tested by outcomes, traces, budget
   adherence, and policy behavior rather than only fixture replay.
5. **Scaled optimizer lift.** Extend the current natural classification, QA,
   retrieval, and instruction-following lift lanes to larger sampled datasets
   when Imp needs model-quality claims beyond provider-free product proof.
6. **Research-scale instruction and hard-math data.** Extend the current
   provider-free IFBench and hard-math smoke rows to pinned public snapshots
   when release policy requires research-tier model-quality evidence.

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

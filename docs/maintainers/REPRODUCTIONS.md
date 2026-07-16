# Reproduction Index

`benchmarks/reproductions.json` is the executable index of research-derived Imp surfaces. It links each canonical authority family to implementation files, runnable protocols, artifact validation, and immutable admitted evidence.

The registry is an index, not a current-status ledger. `T0` means deterministic behavior, `T1` a pinned source differential, `T2` a live sample, and `T3` a paper-scale campaign. These artifact tiers are distinct from the C0-C5 claim ladder. Only the dashboard computes whether admitted evidence satisfies a claim.

<!-- reproduction-registry:start -->
| Feature | Class | Protocols | Admitted tier | Admitted artifact |
| --- | --- | --- | --- | --- |
| Package, public API, docs, and livebooks | native_extension | package_gate | NONE | none |
| Signature, Predict, and ChainOfThought | adaptation | core_trace | NONE | none |
| Model/provider normalized runtime | native_extension | live_matrix | NONE | none |
| Structured adapters and multimodal values | adaptation | multimodal_live | T2 | benchmarks/results/multimodal-quality-live-20260713T224355Z.json |
| ReAct | adaptation | rag_agent | NONE | none |
| ReActV2 | adaptation | rag_agent | NONE | none |
| MCP protocol boundary | native_extension | rag_agent | NONE | none |
| CodeAct | adaptation | rag_agent | NONE | none |
| ProgramOfThought | adaptation | rag_agent | NONE | none |
| Recursive Language Models | adaptation | rlm_contract<br>rlm_paper | NONE | none |
| Assertions and evaluation | adaptation | confidence_calibration | NONE | none |
| SemanticF1 auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/results/auto-evaluation-differential-v1.json |
| CompleteAndGrounded auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/results/auto-evaluation-differential-v1.json |
| Best-of-N and refinement | adaptation | confidence_calibration | NONE | none |
| LabeledFewShot | replication | optimizer_lift | NONE | none |
| BootstrapFewShot | replication | optimizer_lift<br>instruction_live | NONE | none |
| BootstrapRS and RandomSearch | replication | optimizer_lift | NONE | none |
| KNNFewShot | replication | optimizer_lift | NONE | none |
| COPRO | replication | optimizer_lift<br>instruction_live | NONE | none |
| InstructionSearch | native_extension | optimizer_lift | NONE | none |
| InferRules | adaptation | optimizer_lift | NONE | none |
| SignatureOptimizer | native_extension | optimizer_lift | NONE | none |
| MIPROv2 | replication | instruction_contract<br>instruction_live | T2 | benchmarks/results/instruction-optimizer-live/instruction-optimizer-preflight-haiku45-bb65994-20260715.json |
| SIMBA | replication | instruction_contract<br>instruction_live | T2 | benchmarks/results/instruction-optimizer-live/instruction-optimizer-preflight-haiku45-bb65994-20260715.json |
| GEPA | replication | gepa_contract<br>gepa_live | NONE | none |
| Avatar actor | adaptation | provider_training | NONE | none |
| AvatarOptimizer | replication | provider_training | NONE | none |
| BootstrapFinetune and training protocol | adaptation | local_mlx<br>provider_training | T2 | benchmarks/results/local-mlx/local-mlx-922a85e-20260714.json |
| GRPO | adaptation | provider_training | NONE | none |
| BetterTogether | adaptation | provider_training | NONE | none |
| Ensemble | replication | optimizer_lift | NONE | none |
| Fast-Slow training and CISPO | adaptation | fast_slow | NONE | none |
| Optimize Anything | adaptation | optimize_anything | T2 | benchmarks/results/optimize-anything-replication-20260713T092840Z.json |
| Retrieval, RAG, embeddings, and datasets | adaptation | rag_agent | NONE | none |
| Async, streaming, cache, telemetry, and overhead | native_extension | operations | NONE | none |
| Persistence and protocol boundaries | native_extension | operations | NONE | none |
| GSM8K | replication | parity | NONE | none |
| HotPotQA and HotpotQABench | replication | parity<br>gepa_live | NONE | none |
| Color and structured classification fixtures | native_extension | benchmark_run | NONE | none |
| AIMEBench | replication | gepa_dataset<br>gepa_live | NONE | none |
| HoVer and hoverBench | adaptation | gepa_dataset<br>gepa_live | NONE | none |
| IFBench | replication | gepa_dataset<br>gepa_live | NONE | none |
| LiveBenchMathBench | replication | gepa_dataset<br>gepa_live | NONE | none |
| Papillon privacy delegation | adaptation | gepa_dataset<br>gepa_live | NONE | none |
<!-- reproduction-registry:end -->

Regenerate with `mix imp.reproductions`; verify with `mix imp.reproductions --check`.

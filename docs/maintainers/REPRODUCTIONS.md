# Reproduction Index

`benchmarks/reproductions.json` is the executable index of research-derived Imp surfaces. It links each canonical authority family to implementation files, runnable protocols, artifact validation, and immutable admitted evidence.

The registry is an index, not a current-status ledger. `T0` means deterministic behavior, `T1` a pinned source differential, `T2` a live sample, and `T3` a paper-scale campaign. These artifact tiers are distinct from the C0-C5 claim ladder. Only the dashboard computes whether admitted evidence satisfies a claim.

<!-- reproduction-registry:start -->
| Feature | Class | Protocols | Admitted tier | Admitted artifact |
| --- | --- | --- | --- | --- |
| Package, public API, docs, and livebooks | native_extension | package_gate | NONE | none |
| Signature, Predict, and ChainOfThought | adaptation | core_trace | NONE | none |
| Model/provider normalized runtime | native_extension | live_matrix | NONE | none |
| Structured adapters and multimodal values | adaptation | multimodal_live | T2 | benchmarks/evidence/admitted/multimodal_live/02d3c35797723e6ce4a7c544a3f602579771430276d6838beb14bcfe091e391e.json |
| BFCL-shaped scorer benchmark infrastructure | adaptation | bfcl_shaped_scorer | T1 | benchmarks/evidence/admitted/bfcl_shaped_scorer/91b95e1d7308dafdfd62c20dbb133179c4722fe5e023ced013341f3c2c0849ea.json |
| ReAct | adaptation | rag_agent<br>rag_failure_differential | NONE | none |
| ReActV2 | adaptation | rag_agent | NONE | none |
| MCP protocol boundary | native_extension | rag_agent | NONE | none |
| CodeAct | adaptation | rag_agent | NONE | none |
| ProgramOfThought | adaptation | rag_agent | NONE | none |
| Recursive Language Models | adaptation | rlm_contract<br>rlm_runtime_differential<br>rlm_paper | T1 | benchmarks/evidence/admitted/rlm_runtime_differential/aa28970c8ed4d7d3b99d4ff0e4b472e878198465b97f31a74e7f7d0519e6333e.json |
| Assertions and evaluation | adaptation | confidence_calibration | NONE | none |
| SemanticF1 auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/evidence/admitted/auto_evaluation_contract/9f7210133747e00ea2f0a187a90babb3ba8d41d558a410735f8185e8013b63c0.json |
| CompleteAndGrounded auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/evidence/admitted/auto_evaluation_contract/9f7210133747e00ea2f0a187a90babb3ba8d41d558a410735f8185e8013b63c0.json |
| Best-of-N and refinement | adaptation | confidence_calibration | NONE | none |
| LabeledFewShot | replication | optimizer_lift | NONE | none |
| BootstrapFewShot | replication | bootstrap_few_shot_differential<br>optimizer_lift<br>instruction_live | T1 | benchmarks/evidence/admitted/bootstrap_few_shot_differential/8afbb2c4d6acf26011c4678df07a5fd058dafe591a103707f57899a34623d692.json |
| BootstrapRS and RandomSearch | replication | random_search_differential<br>optimizer_lift | T1 | benchmarks/evidence/admitted/random_search_differential/da94412070be8943ae0a8b4dab2ba5a13afb21745cbc9cc1af45016a97a23ee9.json |
| KNNFewShot | replication | optimizer_lift | NONE | none |
| COPRO | replication | optimizer_lift<br>copro_isolation<br>instruction_live | T1 | benchmarks/evidence/admitted/copro_isolation/6832262b8bb4ac4ff3c527fbaffb2ab1ce8dba417ea367213bcb3999e9f1534b.json |
| InstructionSearch | native_extension | optimizer_lift | NONE | none |
| InferRules | adaptation | optimizer_lift | NONE | none |
| SignatureOptimizer | native_extension | optimizer_lift | NONE | none |
| MIPROv2 | replication | instruction_contract<br>instruction_live | T2 | benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json |
| SIMBA | replication | instruction_contract<br>instruction_live | T2 | benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json |
| GEPA | replication | gepa_contract<br>gepa_live | NONE | none |
| Avatar actor | adaptation | provider_training<br>avatar_actor_differential | NONE | none |
| Avatar optimizer | adaptation | provider_training<br>avatar_optimizer_differential | NONE | none |
| BootstrapFinetune and training protocol | adaptation | local_mlx<br>provider_training<br>bootstrap_finetune_differential | T2 | benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json |
| GRPO | adaptation | provider_training<br>mmgrpo_differential | NONE | none |
| BetterTogether | adaptation | provider_training<br>better_together_differential | NONE | none |
| Ensemble | adaptation | optimizer_lift<br>ensemble_differential | NONE | none |
| Fast-Slow training and CISPO | adaptation | fast_slow | NONE | none |
| Optimize Anything | adaptation | optimize_anything | T2 | benchmarks/evidence/admitted/optimize_anything/58ff84ac7a0d95bec2238a367ea998347a036565f8284fd71be39a6bd7d4f631.json |
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

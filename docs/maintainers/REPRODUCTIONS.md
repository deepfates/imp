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
| ReAct | adaptation | rag_agent | NONE | none |
| ReActV2 | adaptation | rag_agent | NONE | none |
| MCP protocol boundary | native_extension | rag_agent | NONE | none |
| CodeAct | adaptation | rag_agent | NONE | none |
| ProgramOfThought | adaptation | rag_agent | NONE | none |
| Recursive Language Models | adaptation | rlm_contract<br>rlm_runtime_differential<br>rlm_paper | NONE | none |
| Assertions and evaluation | adaptation | confidence_calibration | NONE | none |
| SemanticF1 auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/evidence/admitted/auto_evaluation_contract/9f7210133747e00ea2f0a187a90babb3ba8d41d558a410735f8185e8013b63c0.json |
| CompleteAndGrounded auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/evidence/admitted/auto_evaluation_contract/9f7210133747e00ea2f0a187a90babb3ba8d41d558a410735f8185e8013b63c0.json |
| Best-of-N and refinement | adaptation | confidence_calibration | NONE | none |
| LabeledFewShot | replication | optimizer_lift | NONE | none |
| BootstrapFewShot | replication | optimizer_lift<br>instruction_live | NONE | none |
| BootstrapRS and RandomSearch | replication | optimizer_lift | NONE | none |
| KNNFewShot | replication | optimizer_lift | NONE | none |
| COPRO | replication | optimizer_lift<br>instruction_live | NONE | none |
| InstructionSearch | native_extension | optimizer_lift | NONE | none |
| InferRules | adaptation | optimizer_lift | NONE | none |
| SignatureOptimizer | native_extension | optimizer_lift | NONE | none |
| MIPROv2 | replication | instruction_contract<br>instruction_live | T2 | benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json |
| SIMBA | replication | instruction_contract<br>instruction_live | T2 | benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json |
| GEPA | replication | gepa_contract<br>gepa_live | NONE | none |
| Avatar actor | adaptation | provider_training | NONE | none |
| AvatarOptimizer | replication | provider_training | NONE | none |
| BootstrapFinetune and training protocol | adaptation | local_mlx<br>provider_training | T2 | benchmarks/evidence/admitted/local_mlx/c7299fa4900557388f86d37d3198b24f520f80238157c6f6a6b92511249a0d16.json |
| GRPO | adaptation | provider_training | NONE | none |
| BetterTogether | adaptation | provider_training | NONE | none |
| Ensemble | replication | optimizer_lift | NONE | none |
| Fast-Slow training and CISPO | adaptation | fast_slow | NONE | none |
| Optimize Anything | adaptation | optimize_anything | T2 | benchmarks/evidence/admitted/optimize_anything/080f41578d725c8841d7484f6953cba419626b36f08043408c1027622ede4653.json |
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

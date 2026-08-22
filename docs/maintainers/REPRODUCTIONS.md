# Reproduction Index

`benchmarks/reproductions.json` is the executable index of research-derived Imp surfaces. It links each canonical authority family to implementation files, runnable protocols, artifact validation, and immutable admitted evidence.

The registry is an index, not a current-status ledger. `T0` means deterministic behavior, `T1` a pinned source differential, `T2` a live sample, and `T3` a paper-scale campaign. These artifact tiers are distinct from the C0-C5 claim vocabulary. Read each admitted result at its declared scope.

<!-- reproduction-registry:start -->
| Feature | Class | Protocols | Admitted tier | Admitted artifact |
| --- | --- | --- | --- | --- |
| Signature, Predict, and ChainOfThought | adaptation | core_trace | NONE | none |
| Model/provider normalized runtime | native_extension | live_matrix | NONE | none |
| Structured adapters and multimodal values | adaptation | multimodal_live | T2 | benchmarks/evidence/admitted/multimodal_live/02d3c35797723e6ce4a7c544a3f602579771430276d6838beb14bcfe091e391e.json |
| BFCL-shaped scorer benchmark infrastructure | adaptation | bfcl_shaped_scorer | T1 | benchmarks/evidence/admitted/bfcl_shaped_scorer/91b95e1d7308dafdfd62c20dbb133179c4722fe5e023ced013341f3c2c0849ea.json |
| ReAct | adaptation | rag_failure_differential | NONE | none |
| ReActV2 | adaptation | none | NONE | none |
| MCP protocol boundary | native_extension | none | NONE | none |
| CodeAct | adaptation | none | NONE | none |
| ProgramOfThought | adaptation | none | NONE | none |
| Recursive Language Models | adaptation | rlm_contract<br>rlm_runtime_differential<br>rlm_paper | T1 | benchmarks/evidence/admitted/rlm_runtime_differential/aa28970c8ed4d7d3b99d4ff0e4b472e878198465b97f31a74e7f7d0519e6333e.json |
| Assertions and evaluation | adaptation | confidence_calibration | NONE | none |
| SemanticF1 auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/evidence/admitted/auto_evaluation_contract/9f7210133747e00ea2f0a187a90babb3ba8d41d558a410735f8185e8013b63c0.json |
| CompleteAndGrounded auto-evaluation | replication | auto_evaluation_contract | T1 | benchmarks/evidence/admitted/auto_evaluation_contract/9f7210133747e00ea2f0a187a90babb3ba8d41d558a410735f8185e8013b63c0.json |
| Best-of-N and refinement | adaptation | confidence_calibration | NONE | none |
| LabeledFewShot | replication | optimizer_lift | NONE | none |
| BootstrapFewShot | replication | bootstrap_few_shot_differential<br>optimizer_lift<br>instruction_live | T1 | benchmarks/evidence/admitted/bootstrap_few_shot_differential/41ebba40108eb4e45e0f333c2af9ee4238d80718168e4d4e1d3074ebf9bfe290.json |
| BootstrapRS and RandomSearch | replication | random_search_differential<br>optimizer_lift | T1 | benchmarks/evidence/admitted/random_search_differential/e66d685218f50d7cf2f74cf4e36bb7aa4ab7d5ad347979eadc1d989de6fa3caa.json |
| KNNFewShot | replication | optimizer_lift | NONE | none |
| COPRO | replication | optimizer_lift<br>copro_isolation<br>instruction_live | T1 | benchmarks/evidence/admitted/copro_isolation/4f2d959d76bde9fb87da8091223232255074a431be2c05e2e757638c0c43870d.json |
| InstructionSearch | native_extension | optimizer_lift | NONE | none |
| InferRules | adaptation | optimizer_lift | NONE | none |
| SignatureOptimizer | native_extension | optimizer_lift | NONE | none |
| MIPROv2 | replication | instruction_contract<br>instruction_live | T2 | benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json |
| SIMBA | replication | instruction_contract<br>instruction_live | T2 | benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json |
| GEPA | replication | gepa_contract<br>gepa_live | T1 | benchmarks/evidence/admitted/gepa_contract/3f188ccdc6e3ad7cd1b9f00f9096e62c3024097d6de654b90364712477ef8cc7.json |
| Avatar actor | adaptation | provider_training<br>avatar_actor_differential | T1 | benchmarks/evidence/admitted/avatar_actor_differential/190b4002bcb3c96f7a0a3bcea442bb58f2999a935bb2c1b0f1e64c37911beb77.json |
| Avatar optimizer | adaptation | provider_training<br>avatar_optimizer_differential | T1 | benchmarks/evidence/admitted/avatar_optimizer_differential/97dbf8ef7518973fc050b4e51d3ce3325f3797d52687e6b810c51c08eab61d4a.json |
| BootstrapFinetune and training protocol | adaptation | local_mlx<br>provider_training<br>bootstrap_finetune_differential | T2 | benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json |
| GRPO | adaptation | provider_training<br>mmgrpo_differential | T1 | benchmarks/evidence/admitted/mmgrpo_differential/e05710b743aa9bac3c65ecbfbcb90fa0b24e6957262564f06e917db4527360f3.json |
| BetterTogether | adaptation | provider_training<br>better_together_differential | T1 | benchmarks/evidence/admitted/better_together_differential/36898d226771e4bf121df661bac365e0a8a9c2fc98270c6e4126073ccdc015c8.json |
| Ensemble | adaptation | optimizer_lift<br>ensemble_differential | T1 | benchmarks/evidence/admitted/ensemble_differential/df73a1f72a241214570e76b7a824ce5472c0dcff4dcc9bcc62c0d984df3866c8.json |
| Fast-Slow orchestration and CISPO handoff | adaptation | fast_slow | NONE | none |
| Optimize Anything | adaptation | optimize_anything | T2 | benchmarks/evidence/admitted/optimize_anything/0aa498b5ae3ab30ae53c74ddafb80e65f50604dd9d4766a1cc324f0b9fb2fd25.json |
| Retrieval, RAG, embeddings, and datasets | adaptation | hotpot_retrieval | NONE | none |
| Async, streaming, cache, telemetry, and overhead | native_extension | operations | NONE | none |
| Persistence and protocol boundaries | native_extension | operations | NONE | none |
| GSM8K | replication | parity | NONE | none |
| HotPotQA and HotpotQABench | replication | parity<br>gepa_live | NONE | none |
| Color and structured classification fixtures | native_extension | benchmark_run | NONE | none |
| AIMEBench | replication | gepa_dataset<br>gepa_live | NONE | none |
| MuSiQue-Ans adapted Select-to-Answer | adaptation | optimizer_lift | NONE | none |
| HoVer and hoverBench | adaptation | gepa_dataset<br>gepa_live | NONE | none |
| IFBench | replication | gepa_dataset<br>gepa_live | NONE | none |
| LiveBenchMathBench | replication | gepa_dataset<br>gepa_live | NONE | none |
| Papillon privacy delegation | adaptation | gepa_dataset<br>gepa_live | NONE | none |
<!-- reproduction-registry:end -->

Regenerate with `mix imp.reproductions`; verify with `mix imp.reproductions --check`.

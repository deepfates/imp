# Reproduction Status

`benchmarks/reproductions.json` is the executable index of research-derived DSEx surfaces. It links each canonical authority family to implementation files, runnable protocols, artifact validation, admitted evidence, and unresolved constraints.

The registry is an index and gate, not evidence. `T0` means deterministic behavior, `T1` a pinned source differential, `T2` a live sample, and `T3` a paper-scale campaign. Only a validated, literal artifact may advance a row. Smoke output cannot authorize effectiveness.

<!-- reproduction-registry:start -->
| Feature | Class | Tier | State | Protocols | Blocking constraints |
| --- | --- | --- | --- | --- | --- |
| Package, public API, docs, and livebooks | native_extension | NONE | red | package_gate | publication |
| Signature, Predict, and ChainOfThought | adaptation | NONE | red | core_trace | manifest |
| Model/provider normalized runtime | native_extension | NONE | red | live_matrix | live_matrix |
| Structured adapters and multimodal values | adaptation | T2 | yellow | multimodal_live | scope |
| ReAct | adaptation | NONE | red | rag_agent | live_behavior |
| ReActV2 | adaptation | NONE | red | rag_agent | unique_campaign |
| MCP protocol boundary | native_extension | NONE | red | rag_agent | protocol_evidence |
| CodeAct | adaptation | NONE | red | rag_agent | runtime_difference |
| ProgramOfThought | adaptation | NONE | red | rag_agent | matched_reproduction |
| Recursive Language Models | adaptation | NONE | red | rlm_contract<br>rlm_paper | dataset_pins<br>historical_models |
| Assertions and evaluation | adaptation | NONE | red | confidence_calibration | effectiveness_campaign |
| SemanticF1 auto-evaluation | replication | NONE | red | confidence_calibration | executable_differential<br>natural_data |
| CompleteAndGrounded auto-evaluation | replication | NONE | red | confidence_calibration | executable_differential<br>natural_data |
| Best-of-N and refinement | adaptation | NONE | red | confidence_calibration | manifest |
| LabeledFewShot | replication | NONE | red | optimizer_lift | real_manifest |
| BootstrapFewShot | replication | NONE | red | optimizer_lift<br>instruction_live | campaign_quality |
| BootstrapRS and RandomSearch | replication | NONE | red | optimizer_lift | real_manifest |
| KNNFewShot | replication | NONE | red | optimizer_lift | real_manifest |
| COPRO | replication | NONE | red | optimizer_lift<br>instruction_live | matched_live |
| InstructionSearch | native_extension | NONE | red | optimizer_lift | upstream_equivalent |
| InferRules | adaptation | NONE | red | optimizer_lift | dedicated_contract |
| SignatureOptimizer | native_extension | NONE | red | optimizer_lift | upstream_equivalent |
| MIPROv2 | replication | T1 | yellow | instruction_contract<br>instruction_live | t3_effectiveness<br>rng_sequences |
| SIMBA | replication | T1 | yellow | instruction_contract<br>instruction_live | primary_paper<br>t3_effectiveness |
| GEPA | replication | NONE | red | gepa_contract<br>gepa_live | campaign_completion |
| Avatar actor | adaptation | NONE | red | provider_training | effectiveness_campaign |
| AvatarOptimizer | replication | NONE | red | provider_training | upstream_tests |
| BootstrapFinetune and training protocol | adaptation | T2 | yellow | local_mlx<br>provider_training | paid_provider<br>matched_dspy |
| GRPO | adaptation | NONE | red | provider_training | reinforcement_campaign |
| BetterTogether | adaptation | NONE | red | provider_training | weight_lifecycle |
| Ensemble | replication | NONE | red | optimizer_lift | manifest |
| Fast-Slow training and CISPO | adaptation | NONE | red | fast_slow | first_party_source<br>provider_effectiveness |
| Optimize Anything | adaptation | T2 | yellow | optimize_anything | paper_scale |
| Retrieval, RAG, embeddings, and datasets | adaptation | NONE | red | rag_agent | external_engine |
| Async, streaming, cache, telemetry, and overhead | native_extension | NONE | red | operations | claim_scope |
| Persistence and protocol boundaries | native_extension | NONE | red | operations | service_equivalence |
| GSM8K | replication | NONE | red | parity | admitted_campaign |
| HotPotQA and HotpotQABench | replication | NONE | red | parity<br>gepa_live | campaign_completion |
| Color and structured classification fixtures | native_extension | NONE | red | benchmark_run | scientific_authority |
| AIMEBench | replication | NONE | red | gepa_dataset<br>gepa_live | live_optimization |
| HoVer and hoverBench | adaptation | NONE | red | gepa_dataset<br>gepa_live | full_campaign |
| IFBench | replication | NONE | red | gepa_dataset<br>gepa_live | full_campaign |
| LiveBenchMathBench | replication | NONE | red | gepa_dataset<br>gepa_live | research_environment |
| Papillon privacy delegation | adaptation | NONE | red | gepa_dataset<br>gepa_live | judge_provenance |
<!-- reproduction-registry:end -->

Regenerate with `mix dsex.reproductions`; verify with `mix dsex.reproductions --check`.

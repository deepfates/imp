# Imp Executable Upstream Conformance

Baseline: DSPy 3.2.1 (`29448ae12756abdd14bd8796c819247ebb83673c`)
Total: 26
Conformant: 14
Elixir-native equivalents: 6
Tracking: 2
Gaps: 4
Claim-specific non-blocking gaps: 4
Invalid evidence: 0
Missing manifest surfaces: 0
Duplicate manifest owners: 0
Release blockers: 0
Passing: true

| ID | Category | Status | Product gate | Upstream surfaces |
| --- | --- | --- | --- | --- |
| programming.contracts | programming_model | conformant | satisfied | Signature, InputField, OutputField, Example, Prediction, History |
| programming.modules | programming_model | conformant | satisfied | Module, Predict, ChainOfThought, MultiChainComparison, Parallel |
| models.runtime | model_runtime | elixir_native_equivalent | satisfied | BaseLM, LM, Embedder, configure, context, Errors |
| models.normalized_runtime_prerelease | model_runtime | tracking | tracked | 3.3 BaseLM normalized requests/responses, LMRequest, LMResponse, LMStream |
| adapters.structured_io | adapters | conformant | satisfied | Adapter, ChatAdapter, JSONAdapter |
| adapters.xml | adapters | conformant | satisfied | XMLAdapter |
| adapters.two_step | adapters | gap | claim-specific gap | TwoStepAdapter |
| primitives.multimodal | primitives | conformant | satisfied | Image, Audio, File, Code, Document, Citations, Reasoning |
| tools.typed_calls | tools_agents | conformant | satisfied | Tool, ToolCalls, ToolCallResults, MCP |
| agents.react_family | tools_agents | elixir_native_equivalent | satisfied | ReAct, ReActV2, CodeAct, ProgramOfThought, PythonInterpreter |
| agents.rlm | tools_agents | elixir_native_equivalent | satisfied | RLM, SandboxSerializable, Recursive Language Models paper |
| composition.refinement | programming_model | conformant | satisfied | BestOfN, Refine, Assertions |
| evaluation.metrics | evaluation | conformant | satisfied | Evaluate, EvaluationResult, answer_exact_match, answer_passage_match, SemanticF1, CompleteAndGrounded |
| optimization.few_shot | optimization | conformant | satisfied | LabeledFewShot, BootstrapFewShot, BootstrapFewShotWithRandomSearch, BootstrapRS |
| optimization.knn | optimization | gap | claim-specific gap | KNN, KNNFewShot |
| optimization.instructions | optimization | gap | claim-specific gap | COPRO, MIPROv2, SIMBA, InferRules, SignatureOptimizer |
| optimization.gepa | optimization | gap | claim-specific gap | GEPA, GEPA advanced, GEPA 0.1.4 standalone API, GEPA 0.1.1 historical result contract |
| optimization.weights | optimization | elixir_native_equivalent | satisfied | Avatar, AvatarOptimizer, BootstrapFinetune, GRPO, BetterTogether, Ensemble |
| optimization.fast_slow | optimization | elixir_native_equivalent | satisfied | Learning, Fast and Slow Algorithm 1, GEPA fast adaptation, CISPO slow updates |
| optimization.anything | optimization | tracking | tracked | optimize_anything, arbitrary text artifacts |
| retrieval.data | retrieval | elixir_native_equivalent | satisfied | Retrieve, Embeddings, ColBERTv2, WeaviateRM, DatabricksRM, built-in datasets, DataLoader |
| runtime.async_stream_cache | runtime | conformant | satisfied | asyncify, syncify, ParallelExecutor, streamify, StreamListener, configure_cache, track_usage |
| runtime.observability | runtime | conformant | satisfied | inspect_history, StatusMessage, StatusMessageProvider, disable_litellm_logging, disable_logging, enable_litellm_logging, enable_logging, optimizer tracking |
| state.persistence_deployment | operations | conformant | satisfied | Module.save, Module.load, load, dump_state, load_state, deployment |
| product.learning_path | product | conformant | satisfied | getting started, tutorials, real-world examples, API reference, production guide |
| product.release | product | conformant | satisfied | installable package, versioned release, security policy, CI, clean-room consumer |

## Executable Contracts

### `programming.contracts`

Status: `conformant`

Upstream source: `dspy/signatures; dspy/primitives`

Imp modules: `Imp.Signature`, `Imp.Example`, `Imp.Prediction`, `Imp.History`
Semantic invariants:

- signatures declare named typed inputs and outputs
- examples distinguish inputs from labels
- predictions retain structured fields and metadata
- history is signature-shaped and serializable

Executable evidence:

- test: `test/imp_test.exs`
- test: `test/schema_constraints_test.exs`
- test: `test/history_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `livebooks/02_programming_not_prompting.livemd`


Missing evidence or behavior:

- none

### `programming.modules`

Status: `conformant`

Upstream source: `dspy/primitives/module.py; dspy/predict`

Imp modules: `Imp.Module`, `Imp.Predict.Predict`, `Imp.Predict.ChainOfThought`, `Imp.Predict.MultiChainComparison`, `Imp.Predict.Parallel`
Semantic invariants:

- programs are composable callable values
- Predict binds a signature to an LM and adapter
- ChainOfThought extends the output contract with reasoning
- parallel execution preserves input order and failures

Executable evidence:

- test: `test/public_surface_test.exs`
- test: `test/property_invariants_test.exs`
- test: `test/live_provider_e2e_test.exs`
- docs: `../README.md`
- docs: `docs/API_GUIDE.md`


Missing evidence or behavior:

- none

### `models.runtime`

Status: `elixir_native_equivalent`

Upstream source: `dspy/clients; dspy/dsp/utils/settings.py; dspy/utils/exceptions.py`

Imp modules: `Imp.LM`, `Imp.Clients.ReqLLM`, `Imp.Embeddings`, `Imp.Settings`
Elixir-native rationale: ReqLLM owns provider transport while Imp owns program semantics; process-local context replaces Python context variables.

Semantic invariants:

- provider transport is injectable and normalized
- request context is isolated across BEAM processes
- credentials never enter portable program state
- provider errors retain actionable categories

Executable evidence:

- test: `test/req_llm_client_test.exs`
- test: `test/otp_state_semantics_test.exs`
- test: `test/live_provider_test.exs`
- docs: `docs/ARCHITECTURE.md`
- docs: `docs/PRODUCTION_OPERATIONS.md`


Missing evidence or behavior:

- none

### `models.normalized_runtime_prerelease`

Status: `tracking`

Upstream source: `dspy/core/types.py; dspy/clients/base_lm.py @ 3.3.0b1`

Imp modules: `Imp.Core.LMRequest`, `Imp.Core.LMResponse`
Semantic invariants:

- stable DSPy remains the release baseline until 3.3 is final

Executable evidence:

- test: `test/req_llm_client_test.exs`
- docs: [docs/internal/UPSTREAM_FIDELITY_AUDIT.md](https://github.com/deepfates/imp/blob/main/docs/internal/UPSTREAM_FIDELITY_AUDIT.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- none

### `adapters.structured_io`

Status: `conformant`

Upstream source: `dspy/adapters`

Imp modules: `Imp.Adapter`, `Imp.Adapter.Chat`, `Imp.Adapter.JSON`
Semantic invariants:

- adapters format signature fields and demonstrations
- structured parsers validate output contracts and return retry feedback
- tool and history messages survive provider normalization

Executable evidence:

- test: `test/production_adapter_persistence_test.exs`
- test: `test/golden_trace_test.exs`
- docs: [docs/internal/ADAPTER_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/ADAPTER_FIDELITY.md) (repository only, not shipped in the package)
- docs: `docs/API_GUIDE.md`


Missing evidence or behavior:

- none

### `adapters.xml`

Status: `conformant`

Upstream source: `dspy/adapters/xml_adapter.py`

Imp modules: `Imp.Adapter.XML`
Semantic invariants:

- Imp.Adapter.XML renders DSPy XMLAdapter's single XML-only dialect: XML-wrapped structure and inputs, no [[ ## ]] markers, no completed sentinel, and the exact XML output-requirements sentence
- parse requires every output field present in tags and rejects tag-free prose with a loud missing-output-fields error; a parse failure falls back to a JSONAdapter-format retry exactly like DSPy's inherited ChatAdapter.__call__
- byte-parity is measured per call against real DSPy 3.2.1 by the golden-trace differential (xml_* cases: template AND envelope parity)

Executable evidence:

- test: `test/golden_trace_test.exs`
- test: `test/production_adapter_persistence_test.exs`
- test: `test/silent_failure_regressions_test.exs`
- docs: [docs/internal/ADAPTER_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/ADAPTER_FIDELITY.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- none

### `adapters.two_step`

Status: `gap`

Upstream source: `dspy/adapters/two_step_adapter.py`

Imp modules: `Imp.Adapter.TwoStep`
Semantic invariants:

- Imp.Adapter.TwoStep is an Imp extension: it prepends a :plan output field and delegates format and parse to the Chat adapter
- the extension does not claim DSPy TwoStepAdapter semantics

Executable evidence:

- test: `test/completion_surface_test.exs`
- docs: [docs/internal/ADAPTER_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/ADAPTER_FIDELITY.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- DSPy TwoStepAdapter port: a free-form main prompt plus a second extraction LM running ChatAdapter over a synthesized text -> outputs signature; no extraction LM exists in Imp's adapter contract (dee-qt5r)
- golden differential fixtures for both stages (dee-1gb9)

### `primitives.multimodal`

Status: `conformant`

Upstream source: `dspy/adapters/types; dspy/experimental`

Imp modules: `Imp.Adapters.Types`
Semantic invariants:

- encoding support is not evidence of model reasoning quality

Executable evidence:

- test: `test/multimodal_adapter_test.exs`
- test: `test/multimodal_quality_benchmark_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: [docs/internal/MULTIMODAL_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/MULTIMODAL_FIDELITY.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- audio quality remains an unsupported claim rather than an implied capability

### `tools.typed_calls`

Status: `conformant`

Upstream source: `dspy/adapters/types/tool.py; dspy/utils/mcp.py`

Imp modules: `Imp.Tool`, `Imp.MCP`
Semantic invariants:

- tool schemas are validated before execution
- provider tool-call ids and results are retained
- MCP discovery creates ordinary Imp tools

Executable evidence:

- test: `test/react_contract_test.exs`
- test: `test/mcp_import_test.exs`
- test: `test/protocol_mcp/provider_mcp_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `livebooks/04_tools_agents_mcp_rlm.livemd`


Missing evidence or behavior:

- none

### `agents.react_family`

Status: `elixir_native_equivalent`

Upstream source: `dspy/predict/react.py; react_v2.py; code_act.py; program_of_thought.py`

Imp modules: `Imp.Predict.ReAct`, `Imp.Predict.ReActV2`, `Imp.Predict.CodeAct`, `Imp.Predict.ProgramOfThought`, `Imp.Sandbox`
Elixir-native rationale: Imp ReAct uses provider-native function calls with a reserved submit tool and fails fast on unknown tools, denied calls, malformed calls, and execution errors; upstream ReAct uses action fields, a finish control tool, and observation-based continuation. ReActV2 and code execution retain their separately documented Imp contracts.

Semantic invariants:

- ReAct exposes provider-native function tools and terminates through a reserved submit tool
- ReAct fails fast on invalid or failed tool calls instead of claiming upstream observation-and-continue semantics
- ReActV2 native history/tool-call semantics are either implemented or explicitly excluded
- code execution uses a documented Elixir security boundary

Executable evidence:

- test: `test/react_v2_test.exs`
- test: `test/react_contract_test.exs`
- test: `test/completion_surface_test.exs`
- test: `test/live_provider_e2e_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: [docs/internal/REACT_V2_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/REACT_V2_FIDELITY.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- none

### `agents.rlm`

Status: `elixir_native_equivalent`

Upstream source: `dspy/predict/rlm.py; arXiv:2512.24601`

Imp modules: `Imp.Predict.RLM`, `Imp.Predict.RLM.SandboxSerializable`
Elixir-native rationale: Imp implements the recursive controller as a bounded BEAM-native effect interpreter with supervised subcalls, shared budgets, transactional replay, and no Python runtime dependency; paper-scale effectiveness remains a separately gated research claim.

Semantic invariants:

- large inputs remain external to the controller prompt
- the controller can inspect, compute, subquery, batch, recurse, and submit
- resource budgets are enforced and observable
- paper-scale effectiveness is compared with upstream

Executable evidence:

- test: `test/rlm_test.exs`
- test: `test/rlm_interpreter_test.exs`
- test: `test/rlm_budget_test.exs`
- test: `test/live_provider_e2e_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `docs/ARCHITECTURE.md`
- docs: [docs/internal/RLM_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/RLM_FIDELITY.md) (repository only, not shipped in the package)
- docs: `livebooks/04_tools_agents_mcp_rlm.livemd`


Missing evidence or behavior:

- paper-scale reproduction

### `composition.refinement`

Status: `conformant`

Upstream source: `dspy/predict/best_of_n.py; dspy/predict/refine.py; tests/predict/test_refine.py @ 3.3.0b1 b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f`

Imp modules: `Imp.Predict.BestOfN`, `Imp.Predict.Refine`, `Imp.Predict.Assertions`
Semantic invariants:

- metrics select or refine predictions
- below-threshold attempts ask the wrapped LM for redacted advice
- advice is propagated as hint_ and explicit feedback callbacks remain compatible
- fail_count bounds provider failures per invocation
- threshold stopping is inclusive and the best successful prediction is retained
- portable state retains callbacks, threshold, and fail_count with an old-artifact default
- strict assertions fail explicitly

Executable evidence:

- test: `test/refine_feedback_test.exs`
- test: `test/saving_best_of_n_refine_test.exs`
- test: `test/assertions_test.exs`
- test: `test/live_provider_e2e_test.exs`
- docs: `docs/API_GUIDE.md`


Missing evidence or behavior:

- matched-model advice quality and token-cost evidence

### `evaluation.metrics`

Status: `conformant`

Upstream source: `dspy/evaluate`

Imp modules: `Imp.Evaluate`, `Imp.Metrics`, `Imp.Evaluate.SemanticF1`, `Imp.Evaluate.CompleteAndGrounded`
Semantic invariants:

- boolean, numeric, and feedback-bearing metrics normalize consistently
- evaluation retains per-row outputs, failures, scores, and traces
- concurrency does not reorder rows or lose process context
- normalize_text matches DSPy's SQuAD pipeline byte-for-byte: NFD, lowercase, punctuation deletion, word-boundary article removal, whitespace collapse
- EM/F1/HotPot-F1 equal DSPy-computed scores on the pinned adversarial table
- answer_passage_match applies DPR has_answer token-sequence matching per passage, never substring or cross-passage

Executable evidence:

- test: `test/metric_contract_test.exs`
- test: `test/imp_test.exs`
- test: `test/property_invariants_test.exs`
- test: `test/metrics_dspy_parity_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `livebooks/03_evaluate_and_optimize.livemd`


Missing evidence or behavior:

- none

### `optimization.few_shot`

Status: `conformant`

Upstream source: `dspy/teleprompt/bootstrap.py; random_search.py`

Imp modules: `Imp.Optimizer.LabeledFewShot`, `Imp.Optimizer.BootstrapFewShot`, `Imp.Optimizer.BootstrapFewShotWithRandomSearch`, `Imp.Optimizer.BootstrapRS`, `Imp.Optimizer.RandomSearch`
Semantic invariants:

- successful traces become module-specific demonstrations
- teacher and student programs remain distinct
- candidate selection scores candidates on a valset distinct from the trainset (mechanism parity; held-out effectiveness lift remains a separately gated C3 target)

Executable evidence:

- test: `test/optimizer_behavioral_corpus_test.exs`
- test: `test/optimizer_lift_artifact_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: [docs/internal/BENCHMARK_TRUTH.md](https://github.com/deepfates/imp/blob/main/docs/internal/BENCHMARK_TRUTH.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- none

### `optimization.knn`

Status: `gap`

Upstream source: `dspy/predict/knn.py; dspy/teleprompt/knn_fewshot.py`

Imp modules: `Imp.Predict.KNN`, `Imp.Optimizer.KNNFewShot`
Semantic invariants:

- Imp.Optimizer.KNNFewShot attaches the k retrieved neighbors as raw demos via LabeledFewShot at call time (a deviation from upstream, declared here)
- retrieval uses token-overlap similarity rather than upstream's required Embedder (declared deviation)

Executable evidence:

- test: `test/public_surface_test.exs`
- test: `test/optimizer_lift_artifact_test.exs`
- docs: `docs/API_GUIDE.md`


Missing evidence or behavior:

- upstream KNNFewShot semantics: a metric/teacher-driven BootstrapFewShot compiled over the k retrieved neighbors on every forward call (dee-bivg)
- embedding-based neighbor retrieval matching upstream's Embedder contract (dee-bivg)
- a behavioral-corpus test exercising KNNFewShot against upstream (dee-bivg)

### `optimization.instructions`

Status: `gap`

Upstream source: `dspy/teleprompt/copro_optimizer.py; mipro_optimizer_v2.py; simba.py; infer_rules.py`

Imp modules: `Imp.Optimizer.COPRO`, `Imp.Optimizer.MIPROv2`, `Imp.Optimizer.SIMBA`, `Imp.Optimizer.InferRules`, `Imp.Optimizer.SignatureOptimizer`
Semantic invariants:

- public names preserve the upstream optimization mechanism
- proposal, bootstrapping, search, and selection stages are independently observable
- optimization demonstrates held-out lift under matched budgets

Executable evidence:

- test: `test/optimizer_behavioral_corpus_test.exs`
- docs: `docs/API_GUIDE.md`


Missing evidence or behavior:

- matched DSPy 3.3.0b1 MIPROv2 differential artifact
- matched DSPy 3.3.0b1 SIMBA differential artifact
- paper-scale lift evidence

### `optimization.gepa`

Status: `gap`

Upstream source: `gepa-ai/gepa@8b0ce6cd99a234f6b74daf37558a2ac0ce18f975 (standalone v0.1.4 structural authority)`

Imp modules: `Imp.Optimizer.GEPA`, `Imp.Optimize.Anything`
Semantic invariants:

- the local engine and adapter contracts track pinned standalone GEPA v0.1.4 structure
- reflective mutation uses per-example feedback and trajectories in focused local tests
- candidate lineage, Pareto state, and source-versioned results are retained locally
- C1 conformance does not establish matched upstream or paper-family outcomes

Executable evidence:

- test: `test/optimize_anything_runner_test.exs`
- test: `test/gepa_engine_test.exs`
- test: `test/gepa_contract_artifact_test.exs`
- test: `test/gepa_replication_artifact_test.exs`
- docs: `docs/ADVANCED.md`
- docs: [docs/internal/RESEARCH_LANDSCAPE.md](https://github.com/deepfates/imp/blob/main/docs/internal/RESEARCH_LANDSCAPE.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- C2 matched upstream differential evidence
- C3 matched live-provider evidence
- C4 full paper-family campaign evidence
- C5 independently reproduced outcome evidence

### `optimization.weights`

Status: `elixir_native_equivalent`

Upstream source: `dspy/predict/avatar; dspy/teleprompt/avatar_optimizer.py; bootstrap_finetune.py; grpo.py; bettertogether.py; ensemble.py`

Imp modules: `Imp.Predict.Avatar`, `Imp.Optimizer.Avatar`, `Imp.Optimizer.BootstrapFinetune`, `Imp.Optimizer.GRPO`, `Imp.Optimizer.BetterTogether`, `Imp.Optimizer.Ensemble`
Elixir-native rationale: BEAM-native optimizer contracts separate program compilation, asynchronous training jobs, completed rebound programs, and composed workflows while keeping provider execution behind explicit trainer boundaries.

Semantic invariants:

- Avatar runs a bounded typed-action loop with recoverable tool observations and a reserved Finish action
- AvatarOptimizer contrasts positive and negative trajectories, rewrites actor instructions, and retains only improving candidates
- BetterTogether composes arbitrary named and repeated optimizer steps in strategy order
- BetterTogether evaluates the baseline and every successful prefix, selects the best validated prefix with earlier ties winning, and otherwise returns the latest successful prefix
- BetterTogether stops at the first failed optimizer step and returns the best candidate found so far
- provider-backed weight steps complete training and rebind trained model state portably

Executable evidence:

- test: `test/avatar_test.exs`
- test: `test/avatar_optimizer_test.exs`
- test: `test/better_together_test.exs`
- test: `test/optimizer_contract_test.exs`
- test: `test/provider_training_lifecycle_test.exs`
- test: `test/protocol_training/provider_training_lifecycle_test.exs`
- test: `test/public_surface_test.exs`
- docs: `docs/ADVANCED.md`
- docs: [docs/internal/COVERAGE_MATRIX.md](https://github.com/deepfates/imp/blob/main/docs/internal/COVERAGE_MATRIX.md) (repository only, not shipped in the package)
- docs: [docs/internal/UPSTREAM_FIDELITY_AUDIT.md](https://github.com/deepfates/imp/blob/main/docs/internal/UPSTREAM_FIDELITY_AUDIT.md) (repository only, not shipped in the package)
- artifact: `benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json`

Missing evidence or behavior:

- paid-provider weight-training execution evidence
- BetterTogether paid-provider lifecycle completion
- matched Avatar and AvatarOptimizer effectiveness
- matched BetterTogether and GRPO effectiveness

### `optimization.fast_slow`

Status: `elixir_native_equivalent`

Upstream source: `arXiv:2605.12484v2; official GEPA Fast-Slow project article`

Imp modules: `Imp.Training.FastSlow.Runner`, `Imp.Training.FastSlow.Backend`, `Imp.Training.FastSlow.Checkpoint`
Elixir-native rationale: No first-party implementation accompanied the paper; Imp provides a BEAM-native, provider-neutral Algorithm 1 orchestrator with durable effect intents, exact advantage-group accounting, and fail-closed recovery. External CISPO execution and paper-scale effectiveness remain separately gated claims.

Semantic invariants:

- each cycle prefetches exactly T slow-learning minibatches under the current policy
- GEPA selects a K-member per-instance Pareto prompt population before slow learning
- each question uses one shared G-rollout advantage group with G / K rollouts per prompt
- the prompt population remains fixed through exactly T token-aligned slow updates
- ambiguous external outcomes are not replayed without provider idempotency proof

Executable evidence:

- test: `test/fast_slow_state_test.exs`
- test: `test/fast_slow_checkpoint_test.exs`
- test: `test/fast_slow_runner_test.exs`
- test: `test/fast_slow_campaign_test.exs`
- docs: [docs/internal/RESEARCH_LANDSCAPE.md](https://github.com/deepfates/imp/blob/main/docs/internal/RESEARCH_LANDSCAPE.md) (repository only, not shipped in the package)
- docs: `docs/API_GUIDE.md`


Missing evidence or behavior:

- external-provider CISPO execution and model-artifact evidence
- matched prompt-only, slow-only, and combined provider effectiveness
- paper-scale performance and concurrent rollout throughput

### `optimization.anything`

Status: `tracking`

Upstream source: `arXiv:2605.19633; gepa-ai optimize-anything`

Imp modules: `Imp.Optimize.Anything`, `Imp.Optimize.Anything.Config`, `Imp.Optimize.Anything.Result`
Semantic invariants:

- artifacts are not limited to prompts
- feedback is per-task and per-metric
- search retains lineage and Pareto trade-offs
- paper tasks reproduce at meaningful scale

Executable evidence:

- test: `test/optimize_anything_runner_test.exs`
- test: `test/optimize_anything_campaign_test.exs`
- test: `test/optimize_anything_code_artifact_test.exs`
- test: `test/optimize_anything_agent_config_test.exs`
- test: `test/optimize_anything_scheduling_heuristic_test.exs`
- test: `test/optimize_anything_refiner_test.exs`
- test: `test/optimize_anything_multimodal_test.exs`
- test: `test/optimize_anything_tracking_test.exs`
- test: `test/gepa_module_selector_test.exs`
- test: `test/gepa_evaluation_cache_backend_test.exs`
- docs: `docs/ADVANCED.md`
- docs: [docs/internal/BENCHMARK_TRUTH.md](https://github.com/deepfates/imp/blob/main/docs/internal/BENCHMARK_TRUTH.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- paper-scale upstream comparison

### `retrieval.data`

Status: `elixir_native_equivalent`

Upstream source: `dspy/retrievers; dspy/datasets`

Imp modules: `Imp.Retrieve`, `Imp.Embeddings`, `Imp.Retrievers.HTTP`, `Imp.Datasets`
Elixir-native rationale: Imp owns retrieval protocols and composition while production indexes remain replaceable services; embedded ColBERT is intentionally omitted.

Semantic invariants:

- retrievers return ranked normalized documents
- external protocols are contract tested
- dataset splits and provenance are explicit

Executable evidence:

- test: `test/external_retriever_test.exs`
- test: `test/datasets_contract_test.exs`
- test: `test/integration/local_service_e2e_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `docs/ARCHITECTURE.md`


Missing evidence or behavior:

- none

### `runtime.async_stream_cache`

Status: `conformant`

Upstream source: `dspy/utils; dspy/streaming; dspy/clients/cache.py`

Imp modules: `Imp.Tasks`, `Imp.Streaming`, `Imp.Cache`
Semantic invariants:

- work is supervised and cancellable
- stream events preserve final results and errors
- cache policy and usage accounting are configurable
- provider-free overhead is measured against upstream

Executable evidence:

- test: `test/runtime_async_stream_cache_test.exs`
- test: `test/task_supervision_test.exs`
- test: `test/production_hardening_test.exs`
- docs: `docs/ARCHITECTURE.md`
- docs: [docs/internal/PARITY_VALIDATION_PROGRAM.md](https://github.com/deepfates/imp/blob/main/docs/internal/PARITY_VALIDATION_PROGRAM.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- none

### `runtime.observability`

Status: `conformant`

Upstream source: `dspy/utils/inspect_history.py; dspy/utils/callback.py; observability docs`

Imp modules: `Imp.Observability`, `Imp.Telemetry`, `Imp.Streaming.Messages`
Semantic invariants:

- developers can inspect model, tool, optimizer, and RLM traces
- progress is observable without parsing internal structs
- all emitted data is redacted

Executable evidence:

- test: `test/observability_test.exs`
- test: `test/support/telemetry_helpers.ex`
- test: `test/history_test.exs`
- docs: `docs/PRODUCTION_OPERATIONS.md`


Missing evidence or behavior:

- none

### `state.persistence_deployment`

Status: `conformant`

Upstream source: `dspy/primitives/base_module.py; dspy/utils/saving.py; deployment docs`

Imp modules: `Imp.Saving`, `Imp.Saving.Registry`
Semantic invariants:

- portable state round-trips transactionally
- credentials are excluded
- compiled optimizer state remains executable
- deployment from a clean package is documented and tested

Executable evidence:

- test: `test/production_adapter_persistence_test.exs`
- test: `test/deployment_reference_test.exs`
- test: `test/package_contract_test.exs`
- docs: `docs/PRODUCTION_OPERATIONS.md`
- docs: `examples/deployment/README.md`


Missing evidence or behavior:

- none

### `product.learning_path`

Status: `conformant`

Upstream source: `dspy/docs/docs`

Imp modules: `Imp`
Semantic invariants:

- one progressive path teaches the complete product
- examples use canonical public APIs
- credential-gated cells prove provider-relevant behavior
- documentation never outruns evidence

Executable evidence:

- test: `test/learning_path_contract_test.exs`
- test: `test/livebook_contract_test.exs`
- test: `test/documentation_contract_test.exs`
- docs: `../README.md`
- docs: `docs/LEARNING_PATH.md`
- docs: `docs/README.md`
- docs: `livebooks/01_real_lm_front_door.livemd`


Missing evidence or behavior:

- none

### `product.release`

Status: `conformant`

Upstream source: `Hex package and canonical GitHub repository`

Imp modules: `Imp`
Semantic invariants:

- documented installation resolves
- license and release metadata ship
- security and quality gates pass
- a clean project consumes the exact artifact

Executable evidence:

- test: `test/package_contract_test.exs`
- test: `test/gate_contract_test.exs`
- test: `test/production_hardening_test.exs`
- test: `test/deployment_reference_test.exs`
- docs: `../README.md`
- docs: `../CHANGELOG.md`
- docs: `../LICENSE`
- docs: [SECURITY.md](https://github.com/deepfates/imp/blob/main/SECURITY.md) (repository only, not shipped in the package)
- docs: [docs/maintainers/RELEASE.md](https://github.com/deepfates/imp/blob/main/docs/maintainers/RELEASE.md) (repository only, not shipped in the package)


Missing evidence or behavior:

- none

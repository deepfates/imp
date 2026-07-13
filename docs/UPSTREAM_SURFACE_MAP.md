# DSEx Executable Upstream Conformance

Baseline: DSPy 3.2.1 (`29448ae12756abdd14bd8796c819247ebb83673c`)
Total: 23
Conformant: 10
Elixir-native equivalents: 3
Tracking: 2
Gaps: 8
Invalid evidence: 0
Missing manifest surfaces: 0
Duplicate manifest owners: 0
Release blockers: 8
Passing: false

| ID | Category | Status | Upstream surfaces | Ticket |
| --- | --- | --- | --- | --- |
| programming.contracts | programming_model | conformant | Signature, InputField, OutputField, Example, Prediction, History |  |
| programming.modules | programming_model | conformant | Module, Predict, ChainOfThought, MultiChainComparison, Parallel |  |
| models.runtime | model_runtime | elixir_native_equivalent | BaseLM, LM, Embedder, configure, context, Errors |  |
| models.normalized_runtime_prerelease | model_runtime | tracking | 3.3 BaseLM normalized requests/responses, LMRequest, LMResponse, LMStream | de-tt5j |
| adapters.structured_io | adapters | conformant | Adapter, ChatAdapter, JSONAdapter, XMLAdapter, TwoStepAdapter |  |
| primitives.multimodal | primitives | gap | Image, Audio, File, Code, Document, Citations, Reasoning | de-ezg9 |
| tools.typed_calls | tools_agents | conformant | Tool, ToolCalls, ToolCallResults, MCP |  |
| agents.react_family | tools_agents | elixir_native_equivalent | ReAct, ReActV2, CodeAct, ProgramOfThought, PythonInterpreter |  |
| agents.rlm | tools_agents | gap | RLM, SandboxSerializable, Recursive Language Models paper | de-c7ui |
| composition.refinement | programming_model | conformant | BestOfN, Refine, Assertions |  |
| evaluation.metrics | evaluation | conformant | Evaluate, EvaluationResult, answer_exact_match, answer_passage_match, SemanticF1, CompleteAndGrounded |  |
| optimization.few_shot | optimization | conformant | LabeledFewShot, BootstrapFewShot, BootstrapFewShotWithRandomSearch, BootstrapRS, KNN, KNNFewShot |  |
| optimization.instructions | optimization | gap | COPRO, MIPROv2, SIMBA, InferRules, SignatureOptimizer | de-9x31 |
| optimization.gepa | optimization | gap | GEPA, GEPA advanced, GEPA 0.1.1 result contract | de-izej |
| optimization.weights | optimization | gap | Avatar, AvatarOptimizer, BootstrapFinetune, GRPO, BetterTogether, Ensemble | de-9x31 |
| optimization.fast_slow | optimization | gap | Learning, Fast and Slow Algorithm 1, GEPA fast adaptation, CISPO slow updates | de-4bkz |
| optimization.anything | optimization | tracking | optimize_anything, arbitrary text artifacts | de-16fo |
| retrieval.data | retrieval | elixir_native_equivalent | Retrieve, Embeddings, ColBERTv2, WeaviateRM, DatabricksRM, built-in datasets, DataLoader |  |
| runtime.async_stream_cache | runtime | conformant | asyncify, syncify, ParallelExecutor, streamify, StreamListener, configure_cache, track_usage | de-tt5j |
| runtime.observability | runtime | conformant | inspect_history, StatusMessage, StatusMessageProvider, disable_litellm_logging, disable_logging, enable_litellm_logging, enable_logging, optimizer tracking |  |
| state.persistence_deployment | operations | conformant | Module.save, Module.load, load, dump_state, load_state, deployment |  |
| product.learning_path | product | gap | getting started, tutorials, real-world examples, API reference, production guide | de-2ia5 |
| product.release | product | gap | installable package, versioned release, security policy, CI, clean-room consumer | de-p29x |

## Executable Contracts

### `programming.contracts`

Status: `conformant`

Upstream source: `dspy/signatures; dspy/primitives`

DSEx modules: `DSEx.Signature`, `DSEx.Example`, `DSEx.Prediction`, `DSEx.History`
Semantic invariants:

- signatures declare named typed inputs and outputs
- examples distinguish inputs from labels
- predictions retain structured fields and metadata
- history is signature-shaped and serializable

Executable evidence:

- test: `test/dsex_test.exs`
- test: `test/schema_constraints_test.exs`
- test: `test/history_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `livebooks/02_programming_not_prompting.livemd`

Missing evidence or behavior:

- none

### `programming.modules`

Status: `conformant`

Upstream source: `dspy/primitives/module.py; dspy/predict`

DSEx modules: `DSEx.Module`, `DSEx.Predict.Predict`, `DSEx.Predict.ChainOfThought`, `DSEx.Predict.MultiChainComparison`, `DSEx.Predict.Parallel`
Semantic invariants:

- programs are composable callable values
- Predict binds a signature to an LM and adapter
- ChainOfThought extends the output contract with reasoning
- parallel execution preserves input order and failures

Executable evidence:

- test: `test/public_surface_test.exs`
- test: `test/property_invariants_test.exs`
- test: `test/live_provider_e2e_test.exs`
- docs: `README.md`
- docs: `docs/API_GUIDE.md`

Missing evidence or behavior:

- none

### `models.runtime`

Status: `elixir_native_equivalent`

Upstream source: `dspy/clients; dspy/dsp/utils/settings.py; dspy/utils/exceptions.py`

DSEx modules: `DSEx.LM`, `DSEx.Clients.ReqLLM`, `DSEx.Embeddings`, `DSEx.Settings`
Elixir-native rationale: ReqLLM owns provider transport while DSEx owns program semantics; process-local context replaces Python context variables.

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

DSEx modules: `DSEx.Core.LMRequest`, `DSEx.Core.LMResponse`
Semantic invariants:

- stable DSPy remains the release baseline until 3.3 is final

Executable evidence:

- test: `test/req_llm_client_test.exs`
- docs: `docs/UPSTREAM_FIDELITY_AUDIT.md`

Missing evidence or behavior:

- none

### `adapters.structured_io`

Status: `conformant`

Upstream source: `dspy/adapters`

DSEx modules: `DSEx.Adapter`, `DSEx.Adapter.Chat`, `DSEx.Adapter.JSON`, `DSEx.Adapter.XML`, `DSEx.Adapter.TwoStep`
Semantic invariants:

- adapters format signature fields and demonstrations
- structured parsers validate output contracts and return retry feedback
- tool and history messages survive provider normalization

Executable evidence:

- test: `test/production_adapter_persistence_test.exs`
- test: `test/golden_trace_test.exs`
- docs: `docs/ADAPTER_FIDELITY.md`
- docs: `docs/API_GUIDE.md`

Missing evidence or behavior:

- none

### `primitives.multimodal`

Status: `gap`

Upstream source: `dspy/adapters/types; dspy/experimental`

DSEx modules: `DSEx.Adapters.Types`
Semantic invariants:

- encoding support is not evidence of model reasoning quality

Executable evidence:

- test: `test/multimodal_adapter_test.exs`
- docs: `docs/API_GUIDE.md`

Missing evidence or behavior:

- live image task
- live document task
- quality and failure artifact

### `tools.typed_calls`

Status: `conformant`

Upstream source: `dspy/adapters/types/tool.py; dspy/utils/mcp.py`

DSEx modules: `DSEx.Tool`, `DSEx.MCP`
Semantic invariants:

- tool schemas are validated before execution
- provider tool-call ids and results are retained
- MCP discovery creates ordinary DSEx tools

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

DSEx modules: `DSEx.Predict.ReAct`, `DSEx.Predict.ReActV2`, `DSEx.Predict.CodeAct`, `DSEx.Predict.ProgramOfThought`, `DSEx.Sandbox`
Elixir-native rationale: DSEx ReAct uses provider-native function calls with a reserved submit tool and fails fast on unknown tools, denied calls, malformed calls, and execution errors; upstream ReAct uses action fields, a finish control tool, and observation-based continuation. ReActV2 and code execution retain their separately documented DSEx contracts.

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
- docs: `docs/REACT_V2_FIDELITY.md`

Missing evidence or behavior:

- none

### `agents.rlm`

Status: `gap`

Upstream source: `dspy/predict/rlm.py; arXiv:2512.24601`

DSEx modules: `DSEx.Predict.RLM`, `DSEx.Predict.RLM.SandboxSerializable`
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
- docs: `docs/RLM_FIDELITY.md`
- docs: `livebooks/04_tools_agents_mcp_rlm.livemd`

Missing evidence or behavior:

- paper-scale reproduction

### `composition.refinement`

Status: `conformant`

Upstream source: `dspy/predict/best_of_n.py; refine.py; assertions paper`

DSEx modules: `DSEx.Predict.BestOfN`, `DSEx.Predict.Refine`, `DSEx.Predict.Assertions`
Semantic invariants:

- metrics select or refine predictions
- feedback is retained and fed into retries
- strict assertions fail explicitly

Executable evidence:

- test: `test/refine_feedback_test.exs`
- test: `test/assertions_test.exs`
- test: `test/live_provider_e2e_test.exs`
- docs: `docs/API_GUIDE.md`

Missing evidence or behavior:

- none

### `evaluation.metrics`

Status: `conformant`

Upstream source: `dspy/evaluate`

DSEx modules: `DSEx.Evaluate`, `DSEx.Metrics`, `DSEx.Evaluate.SemanticF1`, `DSEx.Evaluate.CompleteAndGrounded`
Semantic invariants:

- boolean, numeric, and feedback-bearing metrics normalize consistently
- evaluation retains per-row outputs, failures, scores, and traces
- concurrency does not reorder rows or lose process context

Executable evidence:

- test: `test/metric_contract_test.exs`
- test: `test/dsex_test.exs`
- test: `test/property_invariants_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `livebooks/03_evaluate_and_optimize.livemd`

Missing evidence or behavior:

- none

### `optimization.few_shot`

Status: `conformant`

Upstream source: `dspy/teleprompt/bootstrap.py; random_search.py; knn_fewshot.py`

DSEx modules: `DSEx.Optimizer.LabeledFewShot`, `DSEx.Optimizer.BootstrapFewShot`, `DSEx.Optimizer.BootstrapFewShotWithRandomSearch`, `DSEx.Optimizer.BootstrapRS`, `DSEx.Optimizer.RandomSearch`, `DSEx.Optimizer.KNNFewShot`
Semantic invariants:

- successful traces become module-specific demonstrations
- teacher and student programs remain distinct
- candidate selection uses held-out evaluation

Executable evidence:

- test: `test/optimizer_behavioral_corpus_test.exs`
- test: `test/optimizer_lift_artifact_test.exs`
- docs: `docs/API_GUIDE.md`
- docs: `docs/BENCHMARK_TRUTH.md`

Missing evidence or behavior:

- none

### `optimization.instructions`

Status: `gap`

Upstream source: `dspy/teleprompt/copro_optimizer.py; mipro_optimizer_v2.py; simba.py; infer_rules.py`

DSEx modules: `DSEx.Optimizer.COPRO`, `DSEx.Optimizer.MIPROv2`, `DSEx.Optimizer.SIMBA`, `DSEx.Optimizer.InferRules`, `DSEx.Optimizer.SignatureOptimizer`
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

Upstream source: `dspy/teleprompt/gepa; github.com/gepa-ai/gepa; arXiv:2507.19457`

DSEx modules: `DSEx.Optimizer.GEPA`, `DSEx.Optimize.GEPA`
Semantic invariants:

- reflective mutation uses per-example feedback and trajectories
- candidate lineage and Pareto state are retained
- result shape is source-versioned
- paper families reproduce under matched budgets

Executable evidence:

- test: `test/optimize_gepa_test.exs`
- test: `test/gepa_replication_artifact_test.exs`
- docs: `docs/ADVANCED.md`

Missing evidence or behavior:

- faithful program-level GEPA
- GEPA 0.1.1 result parity
- non-smoke paper-family campaigns

### `optimization.weights`

Status: `gap`

Upstream source: `dspy/predict/avatar; dspy/teleprompt/avatar_optimizer.py; bootstrap_finetune.py; grpo.py; bettertogether.py; ensemble.py`

DSEx modules: `DSEx.Predict.Avatar`, `DSEx.Optimizer.Avatar`, `DSEx.Optimizer.BootstrapFinetune`, `DSEx.Optimizer.GRPO`, `DSEx.Optimizer.BetterTogether`, `DSEx.Optimizer.Ensemble`
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
- test: `test/provider_training_lifecycle_test.exs`
- test: `test/protocol_training/provider_training_lifecycle_test.exs`
- test: `test/public_surface_test.exs`
- docs: `docs/ADVANCED.md`
- docs: `docs/COVERAGE_MATRIX.md`
- docs: `docs/UPSTREAM_FIDELITY_AUDIT.md`

Missing evidence or behavior:

- external-provider weight-training execution evidence
- BetterTogether provider lifecycle completion and trained-model rebinding
- matched Avatar and AvatarOptimizer effectiveness
- matched BetterTogether effectiveness

### `optimization.fast_slow`

Status: `gap`

Upstream source: `arXiv:2605.12484v2; official GEPA Fast-Slow project article`

DSEx modules: `DSEx.Training.FastSlow.Runner`, `DSEx.Training.FastSlow.Backend`, durable state and checkpoint modules
Semantic invariants:

- each cycle prefetches exactly `T` slow-learning minibatches under the current policy
- GEPA selects a `K`-member per-instance Pareto prompt population before slow learning
- each question uses one shared `G`-rollout advantage group with `G / K` rollouts per prompt
- the prompt population remains fixed through exactly `T` token-aligned slow updates
- cached trajectories retain cycle, behavior-policy, prompt, input, token, mask, and old-logprob provenance
- ambiguous external outcomes are not replayed without provider idempotency proof

Executable evidence:

- test: `test/fast_slow_state_test.exs`
- test: `test/fast_slow_checkpoint_test.exs`
- test: `test/fast_slow_runner_test.exs`
- test: `test/fast_slow_campaign_test.exs`
- docs: `docs/RESEARCH_LANDSCAPE.md`
- docs: `docs/API_GUIDE.md`

Missing evidence or behavior:

- first-party source parity because the official implementation is not published
- external-provider CISPO execution and model-artifact evidence
- matched prompt-only, slow-only, and combined provider effectiveness
- measured concurrent rollout throughput and paper-scale performance

### `optimization.anything`

Status: `tracking`

Upstream source: `arXiv:2605.19633; gepa-ai optimize-anything`

DSEx modules: `DSEx.Optimize.Anything`, `DSEx.Optimize.Anything.Config`, `DSEx.Optimize.Anything.Result`
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
- docs: `docs/BENCHMARK_TRUTH.md`

Missing evidence or behavior:

- paper-scale upstream comparison

### `retrieval.data`

Status: `elixir_native_equivalent`

Upstream source: `dspy/retrievers; dspy/datasets`

DSEx modules: `DSEx.Retrieve`, `DSEx.Embeddings`, `DSEx.Retrievers.HTTP`, `DSEx.Datasets`
Elixir-native rationale: DSEx owns retrieval protocols and composition while production indexes remain replaceable services; embedded ColBERT is intentionally omitted.

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

DSEx modules: `DSEx.Tasks`, `DSEx.Streaming`, `DSEx.Cache`
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
- docs: `docs/PARITY_VALIDATION_PROGRAM.md`

Missing evidence or behavior:

- none

### `runtime.observability`

Status: `conformant`

Upstream source: `dspy/utils/inspect_history.py; dspy/utils/callback.py; observability docs`

DSEx modules: `DSEx.Observability`, `DSEx.Telemetry`, `DSEx.Streaming.Messages`
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

DSEx modules: `DSEx.Saving`, `DSEx.Saving.Registry`
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

Status: `gap`

Upstream source: `dspy/docs/docs`

DSEx modules: `DSEx`
Semantic invariants:

- one progressive path teaches the complete product
- examples use canonical public APIs
- credential-gated cells prove provider-relevant behavior
- documentation never outruns evidence

Executable evidence:

- test: `test/livebook_contract_test.exs`
- test: `test/documentation_contract_test.exs`
- docs: `README.md`
- docs: `docs/README.md`
- docs: `livebooks/01_real_lm_front_door.livemd`

Missing evidence or behavior:

- complete upstream tutorial mapping
- faithful optimizer curriculum
- paper reproduction curriculum

### `product.release`

Status: `gap`

Upstream source: `Hex package and canonical GitHub repository`

DSEx modules: `DSEx`
Semantic invariants:

- documented installation resolves
- license and release metadata ship
- security and quality gates pass
- a clean project consumes the exact artifact

Executable evidence:

- test: `test/package_contract_test.exs`
- test: `test/gate_contract_test.exs`
- docs: `README.md`
- docs: `CHANGELOG.md`
- docs: `LICENSE`
- docs: `SECURITY.md`
- docs: `docs/RELEASE_CRITERIA.md`

Missing evidence or behavior:

- canonical public GitHub remote after rename
- Hex release
- release stewardship

# Imp Audited Upstream Conformance Ledger

This generated report audits asserted upstream-conformance statements. It
is not the product release verdict or work queue; the source repository's
maintainer release procedure owns the ordinary consumer finish line and
`tk` owns unfinished work.

Each status below is a maintainer-authored disposition. The generator checks
that named evidence exists and that claim and reproduction registries are
internally valid; it does not infer
semantic conformance merely because the named test files pass.

Baseline: DSPy 3.3.1 (`638e155cf725236fe5d01b5332394a7bc128881d`)
Total: 27
Conformant: 11
Elixir-native equivalents: 10
Tracking: 2
Gaps: 4
Claim-specific non-blocking gaps: 4
Invalid evidence: 0
Invalid aggregate rows: 0
Missing manifest surfaces: 0
Duplicate manifest owners: 0
Asserted conformance blockers: 0
Asserted conformance passing: true

| ID | Category | Maintainer disposition | Product gate | Upstream surfaces |
| --- | --- | --- | --- | --- |
| programming.contracts | programming_model | conformant | satisfied | Signature, InputField, OutputField, Example, Prediction, History |
| programming.modules | programming_model | conformant | satisfied | Module, Predict, ChainOfThought, MultiChainComparison, Parallel |
| models.runtime | model_runtime | elixir_native_equivalent | satisfied | BaseLM, LM, Embedder, configure, context, Errors |
| models.normalized_runtime | model_runtime | elixir_native_equivalent | satisfied | normalized requests/responses, LMRequest, LMResponse, LMStream |
| modules.flex | experimental | tracking | tracked | Flex |
| adapters.structured_io | adapters | conformant | satisfied | Adapter, ChatAdapter, JSONAdapter |
| adapters.xml | adapters | conformant | satisfied | XMLAdapter |
| adapters.two_step | adapters | conformant | satisfied | TwoStepAdapter |
| primitives.multimodal | primitives | gap | claim-specific gap | Image, Audio, File, Code, Document, Citations, Reasoning |
| tools.typed_calls | tools_agents | elixir_native_equivalent | satisfied | Tool, ToolCalls, ToolCallResults, MCP |
| agents.react_family | tools_agents | elixir_native_equivalent | satisfied | ReAct, ReActV2, CodeAct, ProgramOfThought, PythonInterpreter |
| agents.rlm | tools_agents | elixir_native_equivalent | satisfied | RLM, SandboxSerializable, Recursive Language Models paper |
| composition.refinement | programming_model | conformant | satisfied | BestOfN, Refine, Assertions |
| evaluation.metrics | evaluation | conformant | satisfied | Evaluate, EvaluationResult, answer_exact_match, answer_passage_match, SemanticF1, CompleteAndGrounded |
| optimization.few_shot | optimization | elixir_native_equivalent | satisfied | LabeledFewShot, BootstrapFewShot, BootstrapFewShotWithRandomSearch, BootstrapRS |
| optimization.knn | optimization | conformant | satisfied | KNN, KNNFewShot |
| optimization.instructions | optimization | gap | claim-specific gap | COPRO, MIPROv2, SIMBA, InferRules, SignatureOptimizer |
| optimization.gepa | optimization | gap | claim-specific gap | GEPA, GEPA advanced, GEPA 0.1.4 standalone API, GEPA 0.1.1 historical result contract |
| optimization.weights | optimization | elixir_native_equivalent | satisfied | Avatar, AvatarOptimizer, BootstrapFinetune, GRPO, BetterTogether, Ensemble |
| optimization.fast_slow | optimization | elixir_native_equivalent | satisfied | Learning, Fast and Slow Algorithm 1, GEPA fast-adaptation handoff, external slow-weight optimizer handoff |
| optimization.anything | optimization | gap | claim-specific gap | optimize_anything, arbitrary text artifacts |
| retrieval.data | retrieval | elixir_native_equivalent | satisfied | Retrieve, Embeddings, ColBERTv2, WeaviateRM, DatabricksRM, built-in datasets, DataLoader |
| runtime.async_stream_cache | runtime | conformant | satisfied | asyncify, syncify, ParallelExecutor, streamify, StreamListener, configure_cache, track_usage |
| runtime.observability | runtime | conformant | satisfied | inspect_history, StatusMessage, StatusMessageProvider, disable_litellm_logging, disable_logging, enable_litellm_logging, enable_logging, optimizer tracking |
| state.persistence_deployment | operations | elixir_native_equivalent | satisfied | Module.save, Module.load, load, dump_state, load_state, deployment |
| product.learning_path | product | conformant | satisfied | getting started, tutorials, real-world examples, API reference, production guide |
| product.release | product | tracking | tracked | installable package, versioned release, security policy, CI, clean-room consumer |

## Audited Contracts

### `programming.contracts`

Maintainer disposition: `conformant`

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
- docs: `docs/LEARNING_PATH.md`
- docs: `livebooks/02_programming_not_prompting.livemd`


Indexed capability evidence:

- `Signature`: valid; claims: claim.dspy_semantics.golden_trace (blocking), claim.core.history_contract (informational), claim.docs.tutorial_ticket_routing.optimizer_lift (informational); receipts: dspy_programming_model=valid
- `History`: valid; claims: claim.core.history_contract (informational); receipts: dspy_programming_model=valid


Missing evidence or behavior:

- none

### `programming.modules`

Maintainer disposition: `conformant`

Upstream source: `dspy/primitives/module.py; dspy/predict`

Imp modules: `Imp.Module`, `Imp.Predict.Predict`, `Imp.Predict.ChainOfThought`, `Imp.Predict.MultiChainComparison`, `Imp.Predict.Parallel`
Semantic invariants:

- programs are composable callable values
- Predict binds a signature to an LM and adapter
- ChainOfThought extends the output contract with reasoning
- homogeneous and heterogeneous parallel execution preserves nesting, input order, causal lineage, and local failures

Executable evidence:

- test: `test/public_surface_test.exs`
- test: `test/parallel_execution_test.exs`
- test: `test/property_invariants_test.exs`
- test: `test/live_provider_e2e_test.exs`
- docs: `../README.md`
- docs: `docs/LEARNING_PATH.md`


Indexed capability evidence:

- `Predict`: valid; claims: claim.dspy_semantics.golden_trace (blocking), claim.live_matched_model.full_parity (target), claim.docs.tutorial_ticket_routing.optimizer_lift (informational); receipts: dspy_programming_model=valid
- `ChainOfThought`: valid; claims: claim.dspy_semantics.golden_trace (blocking), claim.live_matched_model.full_parity (target); receipts: dspy_programming_model=valid


Missing evidence or behavior:

- none

### `models.runtime`

Maintainer disposition: `elixir_native_equivalent`

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
- docs: `README.md`
- docs: `docs/PRODUCTION_OPERATIONS.md`



Missing evidence or behavior:

- none

### `models.normalized_runtime`

Maintainer disposition: `elixir_native_equivalent`

Upstream source: `dspy/core/types.py; dspy/clients/base_lm.py @ 3.3.1`

Imp modules: `Imp.Core.LMRequest`, `Imp.Core.LMResponse`, `Imp.Adapter.Types`, `Imp.Streaming.Messages.StreamResponse`, `Imp.Streaming.Messages.StreamListener`
Elixir-native rationale: Imp normalizes every ordinary LM call through typed request/response envelopes while retaining existing typed adapter values as multipart content. Lazy StreamResponse enumerables, incremental listeners, and collect/3 provide the BEAM-native stream consumer contract without a mutable LMStream.result object.

Semantic invariants:

- ordinary Imp.LM and ReqLLM calls cross the normalized request/response boundary without changing the legacy raw return contract
- typed multimodal, reasoning, and tool values survive the normalized request boundary and are converted only at the provider edge
- provider streams expose text, reasoning, tool-call, terminal, and error events lazily with early-halt cancellation
- stream listeners and collection preserve final values and failures without requiring a mutable post-enumeration result object

Executable evidence:

- test: `test/normalized_lm_runtime_test.exs`
- test: `test/req_llm_client_test.exs`
- test: `test/runtime_async_stream_cache_test.exs`
- test: `test/stream_listener_incremental_test.exs`
- docs: `README.md`
- docs: `docs/LEARNING_PATH.md`



Missing evidence or behavior:

- none

### `modules.flex`

Maintainer disposition: `tracking`

Upstream source: `dspy/predict/flex @ 3.3.1`

Imp modules: `Imp.Optimize.Anything.Runner`
Semantic invariants:

- Flex is explicitly experimental in DSPy 3.3.1 and cannot substitute for prompt-program parity
- optimizer-authored executable code must run behind a sandbox and explicit tool/predictor bridge
- Imp evaluates reusable code-artifact semantics through Optimize Anything before earning a Flex-shaped public module

Executable evidence:

- test: `test/optimize_anything_code_artifact_test.exs`
- test: `test/optimize_anything_structured_artifact_test.exs`
- docs: [docs/internal/RESEARCH_LANDSCAPE.md](https://github.com/deepfates/imp/blob/main/docs/internal/RESEARCH_LANDSCAPE.md) (repository only, not shipped in the package)



Missing evidence or behavior:

- an ordinary sandboxed code-optimized module user story with held-out evaluation, durable reload, and fresh service

### `adapters.structured_io`

Maintainer disposition: `conformant`

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
- docs: `docs/LEARNING_PATH.md`



Missing evidence or behavior:

- none

### `adapters.xml`

Maintainer disposition: `conformant`

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

Maintainer disposition: `conformant`

Upstream source: `dspy/adapters/two_step_adapter.py`

Imp modules: `Imp.Adapter.TwoStep`
Semantic invariants:

- Imp.Adapter.TwoStep is the faithful DSPy TwoStepAdapter port: the MAIN LM receives a persona/natural-language prompt (field-description system message, plain name: value demos and inputs, no [[ ## ]] markers)
- parse runs a SECOND extraction LM through the ChatAdapter path over the synthesized text -> outputs signature (original output fields and annotations intact, upstream's exact instructions string), with DSPy's JSONAdapter fallback on extraction failure
- the extraction LM threads through settings (two_step_extraction_lm) or parse opts, mapping DSPy's TwoStepAdapter(extraction_model=...) constructor argument; a missing extraction LM is a loud error, never a silent single-step parse
- byte-parity is measured per call (BOTH stages) against real DSPy 3.2.1 by the golden-trace differential (two_step_* cases: template AND envelope parity)
- the former plan-prepend extension keeps its behavior under the honest name Imp.Adapter.PlanFirst

Executable evidence:

- test: `test/golden_trace_test.exs`
- test: `test/completion_surface_test.exs`
- docs: [docs/internal/ADAPTER_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/ADAPTER_FIDELITY.md) (repository only, not shipped in the package)



Missing evidence or behavior:

- none

### `primitives.multimodal`

Maintainer disposition: `gap`

Upstream source: `dspy/adapters/types; dspy/experimental`

Imp modules: `Imp.Adapter.Types`
Semantic invariants:

- Image, Audio, and File values validate and normalize ordinary provider content blocks
- Code fields validate language-aware source inputs and outputs across Chat, JSON, and XML while direct Code content values retain their fenced provider-content behavior
- Imp's Document, Citation, and Reasoning values are useful native content values but do not claim DSPy's provider-native citation semantics
- encoding support is not evidence of model reasoning quality

Executable evidence:

- test: `test/multimodal_adapter_test.exs`
- test: `test/multimodal_quality_benchmark_test.exs`
- test: `test/upstream_exam/adapters_test.exs`
- docs: `docs/LEARNING_PATH.md`
- docs: [docs/internal/MULTIMODAL_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/MULTIMODAL_FIDELITY.md) (repository only, not shipped in the package)



Missing evidence or behavior:

- citation-enabled Document blocks plus native Citations response extraction and streaming
- audio quality remains an unsupported claim rather than an implied capability

### `tools.typed_calls`

Maintainer disposition: `elixir_native_equivalent`

Upstream source: `dspy/adapters/types/tool.py; dspy/utils/mcp.py`

Imp modules: `Imp.Tool`, `Imp.MCP`
Elixir-native rationale: Imp exposes validated provider-native tool schemas, call identities/results, MCP import, and separately exercised ReActV2 history rather than DSPy's Tool/ToolCalls/ToolCallResults signature-field contract and ChatAdapter use_native_function_calling switch.

Semantic invariants:

- tool schemas are validated before execution
- provider tool-call ids and results are retained
- MCP discovery creates ordinary Imp tools
- the BEAM-native provider-tool path is not described as a literal DSPy typed signature-field contract

Executable evidence:

- test: `test/react_contract_test.exs`
- test: `test/mcp_import_test.exs`
- test: `test/protocol_mcp/provider_mcp_test.exs`
- docs: `docs/LEARNING_PATH.md`
- docs: `livebooks/04_tools_agents_mcp_rlm.livemd`


Indexed capability evidence:

- `MCP`: valid; claims: no indexed claim; receipts: mcp=valid


Missing evidence or behavior:

- first-class ToolCalls and ToolCallResults signature-field semantics matching DSPy
- ChatAdapter use_native_function_calling compatibility switch

### `agents.react_family`

Maintainer disposition: `elixir_native_equivalent`

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
- docs: `docs/LEARNING_PATH.md`
- docs: [docs/internal/REACT_V2_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/REACT_V2_FIDELITY.md) (repository only, not shipped in the package)


Indexed capability evidence:

- `ReAct`: valid; claims: claim.dspy_semantics.golden_trace (blocking), claim.agents.failure_injected.runtime_differential (blocking), claim.agents.failure_recovery.effectiveness (target); receipts: react=valid
- `ReActV2`: valid; claims: no indexed claim; receipts: react_v2=valid
- `CodeAct`: valid; claims: no indexed claim; receipts: code_act=valid
- `ProgramOfThought`: valid; claims: no indexed claim; receipts: program_of_thought=valid


Missing evidence or behavior:

- none

### `agents.rlm`

Maintainer disposition: `elixir_native_equivalent`

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
- docs: `docs/LEARNING_PATH.md`
- docs: `README.md`
- docs: [docs/internal/RLM_FIDELITY.md](https://github.com/deepfates/imp/blob/main/docs/internal/RLM_FIDELITY.md) (repository only, not shipped in the package)
- docs: `livebooks/04_tools_agents_mcp_rlm.livemd`


Indexed capability evidence:

- `RLM`: valid; claims: claim.rlm.provider_free_benchmark (target); receipts: rlm=valid


Missing evidence or behavior:

- paper-scale reproduction

### `composition.refinement`

Maintainer disposition: `conformant`

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
- docs: `docs/LEARNING_PATH.md`


Indexed capability evidence:

- `BestOfN`: valid; claims: claim.evaluation.refine_advice.effectiveness (target); receipts: refinement=valid
- `Refine`: valid; claims: claim.evaluation.refine_advice.effectiveness (target); receipts: refinement=valid


Missing evidence or behavior:

- matched-model advice quality and token-cost evidence

### `evaluation.metrics`

Maintainer disposition: `conformant`

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
- docs: `docs/LEARNING_PATH.md`
- docs: `livebooks/03_evaluate_and_optimize.livemd`


Indexed capability evidence:

- `SemanticF1`: valid; claims: claim.evaluation.auto_evaluation.semantic_conformance (informational), claim.evaluation.natural_judge.effectiveness (target); receipts: semantic_f1=valid
- `CompleteAndGrounded`: valid; claims: claim.evaluation.auto_evaluation.semantic_conformance (informational), claim.evaluation.natural_judge.effectiveness (target); receipts: complete_and_grounded=valid


Missing evidence or behavior:

- none

### `optimization.few_shot`

Maintainer disposition: `elixir_native_equivalent`

Upstream source: `dspy/teleprompt/vanilla.py; bootstrap.py; random_search.py`

Imp modules: `Imp.Optimizer.LabeledFewShot`, `Imp.Optimizer.BootstrapFewShot`, `Imp.Optimizer.BootstrapFewShotWithRandomSearch`, `Imp.Optimizer.BootstrapRS`, `Imp.Optimizer.RandomSearch`
Elixir-native rationale: Imp preserves deterministic no-replacement sampling, ordered first-k selection, and one advancing stream across predictors while using explicit serializable BEAM RNG state instead of Python random.Random. The seed is configurable and checkpoint-friendly; exact Python subset ordering for an equal integer seed is intentionally not part of the native contract.

Semantic invariants:

- LabeledFewShot defaults to k=16 and deterministic sampled selection, supports the ordered sample=false path, and replaces demos on every exposed predictor
- successful traces become module-specific demonstrations
- teacher and student programs remain distinct
- candidate selection scores candidates on a valset distinct from the trainset (mechanism parity; held-out effectiveness lift remains a separately gated C3 target)

Executable evidence:

- test: `test/labeled_few_shot_selection_test.exs`
- test: `test/optimizer_behavioral_corpus_test.exs`
- test: `test/classical_optimizer_differential_test.exs`
- test: `test/optimizer_lift_artifact_test.exs`
- docs: `docs/LEARNING_PATH.md`
- docs: [docs/internal/BENCHMARK_TRUTH.md](https://github.com/deepfates/imp/blob/main/docs/internal/BENCHMARK_TRUTH.md) (repository only, not shipped in the package)


Indexed capability evidence:

- `LabeledFewShot`: valid; claims: claim.docs.tutorial_ticket_routing.optimizer_lift (informational); receipts: labeled_few_shot=valid
- `BootstrapFewShot`: valid; claims: claim.optimizer.bootstrap_few_shot.semantic_conformance (informational), claim.optimizer.bootstrap_few_shot.effectiveness (target); receipts: bootstrap_few_shot=valid
- `BootstrapRS`: valid; claims: no indexed claim; receipts: bootstrap_random_search=valid
- `RandomSearch`: valid; claims: claim.optimizer.random_search.semantic_conformance (informational), claim.optimizer.random_search.effectiveness (target); receipts: bootstrap_random_search=valid


Missing evidence or behavior:

- family-specific held-out effectiveness under matched controls

### `optimization.knn`

Maintainer disposition: `conformant`

Upstream source: `dspy/predict/knn.py; dspy/teleprompt/knn_fewshot.py`

Imp modules: `Imp.Predict.KNN`, `Imp.Optimizer.KNNFewShot`
Semantic invariants:

- Imp.Predict.KNN is the faithful upstream KNN: the trainset's INPUT fields embed once at construction through the required Embedder-analog vectorizer, queries embed at call time, and the top-k neighbors return by descending dot product
- Imp.Optimizer.KNNFewShot runs a full metric/teacher-driven BootstrapFewShot compilation of the student over the k retrieved neighbors on EVERY forward call (upstream's patched forward), never attaching raw neighbors
- selections and metric-gated demo sets are proven equal to real DSPy 3.2.1 by a deterministic-embedder differential (test/knn_dspy_differential_test.exs), and unit tests pin neighbor ranking against a hand-computed dot-product expectation
- the former token-overlap retrieval lives on only under the honest non-DSPy name Imp.Retrievers.KNN

Executable evidence:

- test: `test/knn_few_shot_test.exs`
- test: `test/knn_dspy_differential_test.exs`
- test: `test/public_surface_test.exs`
- test: `test/optimizer_lift_artifact_test.exs`
- docs: `docs/LEARNING_PATH.md`


Indexed capability evidence:

- `KNNFewShot`: valid; claims: no indexed claim; receipts: knn_few_shot=valid


Missing evidence or behavior:

- none

### `optimization.instructions`

Maintainer disposition: `gap`

Upstream source: `dspy/teleprompt/copro_optimizer.py; mipro_optimizer_v2.py; simba.py; infer_rules.py`

Imp modules: `Imp.Optimizer.COPRO`, `Imp.Optimizer.MIPROv2`, `Imp.Optimizer.SIMBA`, `Imp.Optimizer.InferRules`, `Imp.Optimizer.SignatureOptimizer`
Semantic invariants:

- public names preserve the upstream optimization mechanism
- proposal, bootstrapping, search, and selection stages are independently observable
- a source-bound T1 differential matches 33 declared DSPy 3.3.0b1 MIPROv2 and SIMBA structural cases while retaining RNG, sampler, and proposer-call-graph deviations
- a provider-free exact DSPy 3.2.1 InferRules differential exercises formatting, rule updates, implicit train/validation splitting, multi-predictor traversal, candidate scoring, and the drop-one-example context recovery schedule while exposing upstream mutable signature aliasing and retaining rollout-ID differences
- the admitted one-seed live AIME preflight is operational T2 evidence only
- on one frozen three-seed strong-model TREC contract, Imp MIPROv2 improved its own baseline by mean 0.1458 held-out accuracy with a positive 95% clustered interval; this is task-specific C3 evidence, not general MIPROv2 or instruction-family effectiveness
- two later modeled-MIPRO Banking77 conditions completed ordinary Result, Artifact, and fresh-service lifecycles but missed their preregistered mean-lift bars; the confirmatory condition improved two of three seeds by mean 0.041667 against a 0.05 requirement, so it is a clean task-scoped negative rather than evidence of broad effectiveness

Executable evidence:

- test: `test/optimizer_behavioral_corpus_test.exs`
- test: `test/instruction_optimizer_contract_artifact_test.exs`
- test: `test/instruction_optimizer_experiment_test.exs`
- test: `test/infer_rules_upstream_differential_test.exs`
- docs: `docs/LEARNING_PATH.md`
- artifact: `benchmarks/evidence/admitted/instruction_contract/0d032ab3266c2eb8aef9ea021a1a445688cbdc4e208d9bde9d57037b1f302a49.json`
- artifact: `benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json`
- artifact: `benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json`

Indexed capability evidence:

- `COPRO`: valid; claims: claim.optimizer.copro.semantic_conformance (informational), claim.optimizer.copro.effectiveness (target); receipts: copro=valid
- `MIPROv2`: valid; claims: claim.optimizer.mipro_v2.matched_trec_effectiveness (informational), claim.gepa_replication.full (target); receipts: optimizer_miprov2=valid
- `SIMBA`: valid; claims: claim.gepa_replication.full (target); receipts: optimizer_simba=valid
- `InferRules`: valid; claims: no indexed claim; receipts: infer_rules=valid
- `SignatureOptimizer`: valid; claims: no indexed claim; receipts: signature_optimizer=valid


Missing evidence or behavior:

- whole-optimizer and held-out effectiveness evidence for InferRules, plus any upstream parity authority for the native SignatureOptimizer extension
- C3 multi-seed held-out SIMBA effectiveness and cross-task MIPROv2 generalization under matched controls
- paper-scale lift evidence

### `optimization.gepa`

Maintainer disposition: `gap`

Upstream source: `gepa-ai/gepa@8b0ce6cd99a234f6b74daf37558a2ac0ce18f975 (standalone v0.1.4 structural authority)`

Imp modules: `Imp.Optimizer.GEPA`, `Imp.Optimize.Anything`
Semantic invariants:

- the local engine and adapter contracts track pinned standalone GEPA v0.1.4 structure
- the admitted provider-free T1 differential matches 15 structural cases against the exact GEPA v0.1.4 checkout and retains its RNG, resume, and release-metadata deviations
- reflective mutation uses per-example feedback and trajectories in focused local tests
- candidate lineage, Pareto state, and source-versioned results are retained locally
- an ordinary local Banking77 workflow optimized two named predictors, retained the better baseline when reflection regressed, persisted the selected parameter artifact, and reproduced it in a fresh OS process
- on one frozen strong-model TREC contract, Imp GEPA improved its own baseline by mean 0.4000 held-out accuracy and cleared a preregistered -0.05 noninferiority margin against pinned DSPy GEPA
- a later three-seed JSON-GEPA HotPotQA treatment completed all ordinary Artifact and fresh-service lifecycles but produced mean held-out F1 lift -0.015256 with zero positive seeds; its earlier Chat treatment was operationally invalid and is not effectiveness evidence
- IFBench remains compatibility-regression evidence only because a task-scorer representation defect invalidated the earlier Imp effectiveness interpretation
- the matched TREC result is task-specific C3 evidence; the clean negatives and invalid IFBench treatment bound rather than erase it, and no result establishes general effectiveness, superiority, or paper-family outcomes

Executable evidence:

- test: `test/optimize_anything_runner_test.exs`
- test: `test/gepa_engine_test.exs`
- test: `test/gepa_parameter_artifact_lifecycle_test.exs`
- test: `test/local_gepa_banking77_example_test.exs`
- test: `test/gepa_contract_artifact_test.exs`
- test: `test/gepa_replication_artifact_test.exs`
- docs: `docs/LEARNING_PATH.md`
- docs: [examples/local_gepa_banking77/README.md](https://github.com/deepfates/imp/blob/main/examples/local_gepa_banking77/README.md) (repository only, not shipped in the package)
- docs: [docs/internal/RESEARCH_LANDSCAPE.md](https://github.com/deepfates/imp/blob/main/docs/internal/RESEARCH_LANDSCAPE.md) (repository only, not shipped in the package)
- docs: [.tickets/imp-88sn.md](https://github.com/deepfates/imp/blob/main/.tickets/imp-88sn.md) (repository only, not shipped in the package)
- artifact: `benchmarks/evidence/admitted/gepa_contract/3f188ccdc6e3ad7cd1b9f00f9096e62c3024097d6de654b90364712477ef8cc7.json`
- artifact: `benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json`

Indexed capability evidence:

- `GEPA`: valid; claims: claim.optimizer.gepa.matched_trec_effectiveness (informational), claim.gepa_replication.full (target); receipts: optimizer_gepa=valid


Missing evidence or behavior:

- cross-task matched effectiveness beyond the frozen TREC contract
- C4 full paper-family campaign evidence is a telos research target, not a v0.1 release claim

### `optimization.weights`

Maintainer disposition: `elixir_native_equivalent`

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
- a completed local TRL job restarts only through an explicit trusted runtime, loads the verified LoRA tensors, and checks artifact identity on every generation
- the same trusted runtime can serve the exact pinned base policy explicitly, so consumers can measure base and trained programs through the same Imp adapter path

Executable evidence:

- test: `test/avatar_test.exs`
- test: `test/avatar_optimizer_test.exs`
- test: `test/better_together_test.exs`
- test: `test/optimizer_contract_test.exs`
- test: `test/provider_training_lifecycle_test.exs`
- test: `test/protocol_training/provider_training_lifecycle_test.exs`
- test: `test/public_surface_test.exs`
- test: `test/trl_protocol_test.exs`
- test: `test/trl_protocol_grpo_lifecycle_test.exs`
- test: `test/local_grpo_opaque_banking77_example_test.exs`
- docs: `docs/LEARNING_PATH.md`
- docs: [docs/internal/COVERAGE_MATRIX.md](https://github.com/deepfates/imp/blob/main/docs/internal/COVERAGE_MATRIX.md) (repository only, not shipped in the package)
- docs: [docs/internal/UPSTREAM_FIDELITY_AUDIT.md](https://github.com/deepfates/imp/blob/main/docs/internal/UPSTREAM_FIDELITY_AUDIT.md) (repository only, not shipped in the package)
- artifact: `benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json`

Indexed capability evidence:

- `Avatar`: valid; claims: claim.optimizer.avatar_actor.api (blocking), claim.optimizer.avatar_actor.semantic_conformance (informational), claim.optimizer.avatar_actor.effectiveness (target); receipts: avatar=valid
- `AvatarOptimizer`: valid; claims: claim.optimizer.avatar_optimizer.api (blocking), claim.optimizer.avatar_optimizer.semantic_conformance (informational), claim.optimizer.avatar_optimizer.effectiveness (target); receipts: avatar_optimizer=valid
- `BootstrapFinetune`: valid; claims: claim.optimizer.bootstrap_finetune.api (blocking), claim.optimizer.bootstrap_finetune.semantic_conformance (informational), claim.optimizer.bootstrap_finetune.provider_effectiveness (target), claim.local_mlx_weight_training.effectiveness (informational); receipts: bootstrap_finetune=valid
- `GRPO`: valid; claims: claim.optimizer.mmgrpo.api (blocking), claim.optimizer.mmgrpo.semantic_conformance (informational), claim.optimizer.mmgrpo.effectiveness (target); receipts: grpo=valid
- `BetterTogether`: valid; claims: claim.optimizer.better_together.api (blocking), claim.optimizer.better_together.semantic_conformance (informational), claim.optimizer.better_together.effectiveness (target); receipts: better_together=valid
- `Ensemble`: valid; claims: claim.optimizer.ensemble.api (blocking), claim.optimizer.ensemble.semantic_conformance (informational), claim.optimizer.ensemble.effectiveness (target); receipts: ensemble=valid


Missing evidence or behavior:

- paid-provider weight-training execution evidence
- BetterTogether paid-provider lifecycle completion
- general or consistently useful model-sampled GRPO learning; the complete local multi-step TRL/MPS treatments changed trainable tensors and reproduced verified artifacts, but the retained source-disjoint outcomes were neutral or regressed on held-out data
- matched Avatar and AvatarOptimizer effectiveness
- matched BetterTogether and GRPO effectiveness

### `optimization.fast_slow`

Maintainer disposition: `elixir_native_equivalent`

Upstream source: `arXiv:2605.12484v2; official GEPA Fast-Slow project article`

Imp modules: `Imp.Training.FastSlow.Runner`, `Imp.Training.FastSlow.Backend`, `Imp.Training.FastSlow.Checkpoint`
Elixir-native rationale: The official code page still says code coming soon. Imp provides a BEAM-native, provider-neutral implementation of Algorithm 1's orchestration order with durable effect intents, enforced operation budgets, ordered events, exact advantage-group accounting, and fail-closed recovery. The slow-weight callback is an external handoff; Imp does not implement or verify CISPO, a gradient step, or resulting model weights.

Semantic invariants:

- each cycle prefetches exactly T slow-learning minibatches under the current policy
- GEPA selects a K-member per-instance Pareto prompt population before slow learning
- each question uses one shared G-rollout advantage group with G / K rollouts per prompt
- the prompt population remains fixed through exactly T token-aligned slow-update handoffs
- ambiguous external outcomes are not replayed without provider idempotency proof

Executable evidence:

- test: `test/fast_slow_state_test.exs`
- test: `test/fast_slow_checkpoint_test.exs`
- test: `test/fast_slow_runner_test.exs`
- test: `test/fast_slow_campaign_test.exs`
- docs: [docs/internal/RESEARCH_LANDSCAPE.md](https://github.com/deepfates/imp/blob/main/docs/internal/RESEARCH_LANDSCAPE.md) (repository only, not shipped in the package)
- docs: `docs/PRODUCTION_OPERATIONS.md`



Missing evidence or behavior:

- external-provider CISPO loss, optimizer execution, and content-bound model-artifact evidence
- matched prompt-only, slow-only, and combined provider effectiveness
- paper-scale performance and concurrent rollout throughput

### `optimization.anything`

Maintainer disposition: `gap`

Upstream source: `arXiv:2605.19633; gepa-ai optimize-anything`

Imp modules: `Imp.Optimize.Anything`, `Imp.Optimize.Anything.Config`, `Imp.Optimize.Anything.Result`
Semantic invariants:

- artifacts are not limited to prompts
- GEPA v0.1.4 text candidates stay distinct from Imp's strict JSON-safe structured-artifact extension
- feedback is per-task and per-metric
- search retains lineage and Pareto trade-offs
- the public lifecycle optimizes, selects, persists, and fresh-loads task-owned text and JSON-safe structured artifacts without implying paper-task reproduction
- the live schema-v2 three-class portfolio keeps train, selection, and untouched test cases distinct and satisfies its declared positive-mean and majority-improving policy for executable retry code, agent configuration, and scheduling artifacts

Executable evidence:

- test: `test/optimize_anything_runner_test.exs`
- test: `test/optimize_anything_structured_artifact_test.exs`
- test: `test/optimize_anything_campaign_test.exs`
- test: `test/optimize_anything_code_artifact_test.exs`
- test: `test/optimize_anything_agent_config_test.exs`
- test: `test/optimize_anything_scheduling_heuristic_test.exs`
- test: `test/optimize_anything_refiner_test.exs`
- test: `test/optimize_anything_multimodal_test.exs`
- test: `test/optimize_anything_tracking_test.exs`
- test: `test/gepa_module_selector_test.exs`
- test: `test/gepa_evaluation_cache_backend_test.exs`
- test: `test/local_optimize_anything_retry_policy_three_seed_evidence_test.exs`
- docs: `docs/LEARNING_PATH.md`
- docs: [docs/internal/BENCHMARK_TRUTH.md](https://github.com/deepfates/imp/blob/main/docs/internal/BENCHMARK_TRUTH.md) (repository only, not shipped in the package)
- docs: [.tickets/imp-88sn.md](https://github.com/deepfates/imp/blob/main/.tickets/imp-88sn.md) (repository only, not shipped in the package)
- artifact: `benchmarks/evidence/archive/optimize_anything/retry-policy-v2/manifest.json`
- artifact: `benchmarks/evidence/admitted/optimize_anything/0aa498b5ae3ab30ae53c74ddafb80e65f50604dd9d4766a1cc324f0b9fb2fd25.json`

Indexed capability evidence:

- `optimize_anything`: valid; claims: claim.optimize_anything.operational_lifecycle (informational), claim.optimize_anything.retry_policy_task_effectiveness (informational), claim.optimize_anything.non_prompt_effectiveness (informational), claim.optimize_anything.upstream_comparative_effectiveness (target); receipts: optimize_anything=valid


Missing evidence or behavior:

- paper-scale upstream comparison

### `retrieval.data`

Maintainer disposition: `elixir_native_equivalent`

Upstream source: `dspy/retrievers; dspy/datasets`

Imp modules: `Imp.Retrieve`, `Imp.Embeddings`, `Imp.Retrievers.HTTP`, `Imp.Datasets`
Elixir-native rationale: Imp owns retrieval protocols and composition while production indexes remain replaceable services. Unlike DSPy's convenience dataset helpers, named Imp loaders require explicit local files and never auto-download; embedded ColBERT is intentionally omitted.

Semantic invariants:

- retrievers return ranked normalized documents
- external protocols are contract tested
- dataset splits and provenance are explicit
- named dataset loaders require explicit local files and never auto-download

Executable evidence:

- test: `test/external_retriever_test.exs`
- test: `test/datasets_contract_test.exs`
- test: `test/integration/local_service_e2e_test.exs`
- docs: `docs/LEARNING_PATH.md`
- docs: `README.md`


Indexed capability evidence:

- `Embeddings`: valid; claims: claim.embeddings.boundary_contract (informational); receipts: retrieval_rag=valid


Missing evidence or behavior:

- none

### `runtime.async_stream_cache`

Maintainer disposition: `conformant`

Upstream source: `dspy/utils; dspy/streaming; dspy/clients/cache.py`

Imp modules: `Imp.Tasks`, `Imp.Streaming`, `Imp.Cache`
Semantic invariants:

- work is supervised and cancellable
- stream events preserve final results and errors
- provider streaming executes real composed control flow and can select intermediate fields by named predictor
- cache policy and usage accounting are configurable
- provider-free overhead is measured against upstream

Executable evidence:

- test: `test/runtime_async_stream_cache_test.exs`
- test: `test/composed_streaming_test.exs`
- test: `test/upstream_exam/streaming_test.exs`
- test: `test/completion_surface_test.exs`
- test: `test/task_supervision_test.exs`
- test: `test/production_hardening_test.exs`
- docs: `README.md`
- docs: `docs/LEARNING_PATH.md`



Missing evidence or behavior:

- none

### `runtime.observability`

Maintainer disposition: `conformant`

Upstream source: `dspy/utils/inspect_history.py; dspy/utils/callback.py; observability docs`

Imp modules: `Imp.Observability`, `Imp.Telemetry`, `Imp.Streaming.Messages`
Elixir-native rationale: Imp emits lifecycle status through StreamListener and module/LM/tool progress through causally linked telemetry. The former passive StatusMessageProvider accumulator was removed because it did not implement DSPy's callback provider and added no capability.

Semantic invariants:

- developers can inspect model, tool, optimizer, and RLM traces
- progress is observable without parsing internal structs
- custom status consumers attach to StreamListener or :telemetry instead of subclassing a callback provider
- all emitted data is redacted

Executable evidence:

- test: `test/observability_test.exs`
- test: `test/support/telemetry_helpers.ex`
- test: `test/history_test.exs`
- docs: `docs/PRODUCTION_OPERATIONS.md`



Missing evidence or behavior:

- none

### `state.persistence_deployment`

Maintainer disposition: `elixir_native_equivalent`

Upstream source: `dspy/primitives/base_module.py; dspy/utils/saving.py; deployment docs`

Imp modules: `Imp.Saving`, `Imp.Saving.Registry`, `Imp.Optimizer.Artifact`
Elixir-native rationale: Supported built-in program graphs round-trip through Imp.Saving; consumer-defined modules use checksummed parameter Artifacts applied into reconstructed trusted code so runtime callbacks and credentials never come from artifact bytes.

Semantic invariants:

- portable state round-trips transactionally
- credentials are excluded
- compiled optimizer state remains executable
- deployment from a clean package is documented and tested
- consumer-defined modules reconstruct trusted code and apply portable parameters rather than claiming arbitrary whole-program serialization

Executable evidence:

- test: `test/production_adapter_persistence_test.exs`
- test: `test/current_dspy_state_boundary_test.exs`
- test: `test/deployment_reference_test.exs`
- test: `test/package_contract_test.exs`
- docs: `docs/PRODUCTION_OPERATIONS.md`
- docs: `examples/deployment/README.md`



Missing evidence or behavior:

- generic whole-program persistence for arbitrary consumer structs; the supported safe substitute is parameter Artifact plus trusted reconstruction

### `product.learning_path`

Maintainer disposition: `conformant`

Upstream source: `dspy/docs/docs`

Imp modules: `Imp`
Semantic invariants:

- one progressive path teaches the stable center and names experimental gaps
- examples use canonical public APIs
- credential-gated cells prove provider-relevant behavior
- documentation never outruns evidence

Executable evidence:

- test: `test/learning_path_contract_test.exs`
- test: `test/livebook_contract_test.exs`
- test: `test/documentation_contract_test.exs`
- docs: `../README.md`
- docs: `docs/LEARNING_PATH.md`
- docs: `README.md`
- docs: `livebooks/01_real_lm_front_door.livemd`



Missing evidence or behavior:

- none

### `product.release`

Maintainer disposition: `tracking`

Upstream source: `Hex package and canonical GitHub repository`

Imp modules: `Imp`
Semantic invariants:

- documented installation resolves
- license and release metadata ship
- security and quality gates pass
- a clean project consumes the exact artifact

Executable evidence:

- test: `test/package_contract_test.exs`
- test: `test/production_hardening_test.exs`
- test: `test/deployment_reference_test.exs`
- docs: `../README.md`
- docs: `../CHANGELOG.md`
- docs: `../LICENSE`
- docs: [SECURITY.md](https://github.com/deepfates/imp/blob/main/SECURITY.md) (repository only, not shipped in the package)
- docs: [docs/maintainers/RELEASE.md](https://github.com/deepfates/imp/blob/main/docs/maintainers/RELEASE.md) (repository only, not shipped in the package)



Missing evidence or behavior:

- a published versioned Hex release; owner publication is intentionally frozen pending explicit check-in

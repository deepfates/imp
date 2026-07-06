# DSEx Coverage Matrix

This matrix is the release truth table for DSEx V3. It maps the concepts from
DSPy, Ax, and optimize_anything into the Elixir-native DSEx surface.

Status values:

- **Implemented**: production surface exists and is covered by deterministic
  tests.
- **DSEx-native**: DSEx intentionally uses a BEAM-shaped design instead of a
  direct Python-shaped API.
- **Release blocker**: the feature is not acceptable for V3 without the linked
  ticket.
- **Intentional omission**: DSEx does not claim this surface for V3.

## Core Programming Model

| Concept | DSEx status | DSEx surface | Deterministic tests | Integration/live proof | Docs | Release decision |
| --- | --- | --- | --- | --- | --- | --- |
| Signatures as semantic contracts | Implemented | `DSEx.Signature`, `DSEx.Signature.Field`, and parser internals | `test/dsex_test.exs`, `test/schema_constraints_test.exs`, `test/production_hardening_test.exs` | Covered through live `Predict`, JSON, CoT, ReActV2, and PoT tests | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep as canonical contract model |
| Typed fields, descriptions, constraints, JSON schema | Implemented | `DSEx.Signature.Field`, `DSEx.Schema` | `test/schema_constraints_test.exs`, `test/production_adapter_persistence_test.exs` | Live JSON gate exercises generic JSON and provider-native JSON schema output | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep and extend only when provider needs require it |
| Examples and train/dev/test rows | Implemented | `DSEx.Example`, `DSEx.Datasets` | `test/dsex_test.exs`, `test/datasets_contract_test.exs`, `test/completion_surface_test.exs` | Local integration gate is needed for packaged dataset examples: `de-wrnz` | `docs/API_GUIDE.md`, `livebooks/02_evaluate_and_optimize.livemd` | V3 requires integration examples that load from real files |
| Predictions and metadata | Implemented | `DSEx.Prediction` | `test/dsex_facade_test.exs`, `test/public_surface_test.exs` | Covered indirectly in live provider tests | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep as the common output envelope |
| Process-local and global settings | DSEx-native | `DSEx.Settings`, `DSEx.configure/1`, `DSEx.context/2` | `test/dsex_test.exs`, `test/dsex_facade_test.exs` | Covered indirectly through live provider configuration | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep process-local design as the Elixir equivalent of dynamic DSP settings |
| Public facade | Implemented | `DSEx` | `test/dsex_facade_test.exs`, `test/public_surface_test.exs` | Live provider tests use facade constructors for core flows | `README.md`, `docs/API_GUIDE.md` | Keep facade narrow and canonical |

## Model, Adapter, and Provider Layer

| Concept | DSEx status | DSEx surface | Deterministic tests | Integration/live proof | Docs | Release decision |
| --- | --- | --- | --- | --- | --- | --- |
| LM behaviour and injectable clients | Implemented | `DSEx.LM`, `DSEx.Clients.ReqLLM`, `DSEx.Clients.HTTPLM`, provider constructors | `test/req_llm_client_test.exs`, `test/completion_surface_test.exs`, `test/production_hardening_test.exs` | `LIVE_PROVIDER=1 mix live.check` covers both direct and ReqLLM-backed provider paths | `docs/API_GUIDE.md`, `docs/PRODUCTION_OPERATIONS.md` | Keep behaviour-first design; prefer ecosystem-backed provider I/O |
| ReqLLM ecosystem-backed providers | Implemented | `DSEx.req_llm/2`, `DSEx.Clients.ReqLLM` | `test/req_llm_client_test.exs` covers message translation, schema/provider options, tool calls, streaming, and save/load | Live basic prediction through ReqLLM-backed OpenAI model | `README.md`, `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Use ReqLLM for production provider/model transport instead of expanding DSEx-owned clients |
| OpenAI-compatible chat completions | Implemented | `DSEx.Clients.OpenAI`, `DSEx.Clients.HTTPLM` | `test/completion_surface_test.exs`, `test/provider_tool_call_test.exs`, `test/production_hardening_test.exs` | Live basic prediction, JSON, native schema JSON, CoT, streaming, ReActV2 | `README.md`, `docs/API_GUIDE.md` | Keep OpenAI-compatible surface as provider baseline |
| LiteLLM/local/Databricks compatible clients | Implemented | `DSEx.Clients.LiteLLM`, `DSEx.Clients.Local`, `DSEx.Clients.Databricks` | `test/completion_surface_test.exs`, `test/provider_training_lifecycle_test.exs` | External live proof is not required for V3 unless docs claim provider-specific guarantees | `docs/API_GUIDE.md` | Provider-specific live gates are optional unless claims expand |
| Adapters: chat, JSON, XML, two-step/BAML-style | Implemented | `DSEx.Adapter.*` | `test/production_adapter_persistence_test.exs`, `test/schema_constraints_test.exs` | Live JSON and CoT use adapter paths | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep adapters as parse/format behaviours |
| Native structured-output negotiation | Implemented | `DSEx.Adapter.JSON.lm_opts/2`, `DSEx.Schema` | `test/production_adapter_persistence_test.exs`, `test/schema_constraints_test.exs` | Live JSON and CoT with JSON adapter | `docs/API_GUIDE.md`, `docs/PRODUCTION_OPERATIONS.md` | Keep and validate against provider drift through live gate |
| Streaming | Implemented | `DSEx.Streaming`, `DSEx.Clients.ReqLLM.stream/3`, `DSEx.Clients.HTTPLM.stream/3` | `test/req_llm_client_test.exs`, `test/provider_streaming_test.exs`, `test/completion_surface_test.exs` | Live provider streaming test | `docs/API_GUIDE.md`, `docs/PRODUCTION_OPERATIONS.md`, `docs/ARCHITECTURE.md` | Keep enumerable interface; prefer ReqLLM streaming where supported |
| Async/concurrency | DSEx-native | `DSEx.Clients.HTTPLM.generate_async/3`, `DSEx.Predict.Parallel` | `test/production_hardening_test.exs` | Live orchestration test covers `Parallel` | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep Task-based interface; runtime hardening owned by `de-qvwf` |
| Cache | Implemented | `DSEx.Cache`, HTTPLM cache path | `test/production_hardening_test.exs`, `test/public_surface_test.exs` | Live cache behaviour is not required for V3 | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Add observability events under `de-x02m` |
| Multimodal primitives | Implemented | `DSEx.Adapters.Types` | `test/multimodal_adapter_test.exs` | Live multimodal provider proof is not required for V3 unless docs claim it | `docs/API_GUIDE.md` | Keep as encoding/decoding primitives, not a broad multimodal benchmark claim |
| Option validation and runtime dependencies | Implemented | option validation helper, network-facing constructors, runtime deps in `mix.exs` | `test/req_llm_client_test.exs`, `test/production_hardening_test.exs` | Covered by deterministic gate and exercised by integration/live tests | `docs/ARCHITECTURE.md`, `docs/RELEASE_CRITERIA.md` | Keep dependency set justified by ecosystem leverage |

## Program Modules

| Concept | DSEx status | DSEx surface | Deterministic tests | Integration/live proof | Docs | Release decision |
| --- | --- | --- | --- | --- | --- | --- |
| Basic prediction | Implemented | `DSEx.Predict.Predict`, `DSEx.predict/2` | `test/dsex_test.exs`, `test/public_surface_test.exs` | Live basic prediction and JSON prediction | `README.md`, `docs/API_GUIDE.md` | Keep |
| Chain-of-thought style reasoning field | Implemented | `DSEx.Predict.ChainOfThought`, `DSEx.chain_of_thought/2` | `test/dsex_test.exs` | Live CoT with required reasoning | `docs/API_GUIDE.md`, `livebooks/01_programming_not_prompting.livemd` | Keep as a typed field transform |
| ReAct/provider tool loop | Implemented | `DSEx.Predict.ReActV2`, `DSEx.Predict.ReAct` facade | `test/react_v2_contract_test.exs`, `test/provider_tool_call_test.exs` | Live ReActV2 function tools and reserved `submit` | `docs/API_GUIDE.md`, `livebooks/03_agents_tools_mcp_rlm.livemd` | Keep `ReActV2` as canonical; `ReAct` remains a compatibility facade |
| Program of Thought | Implemented | `DSEx.Predict.ProgramOfThought`, `DSEx.Sandbox` | `test/completion_surface_test.exs` | Live PoT drives sandbox execution | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep BEAM-safe expression model |
| CodeAct | Implemented | `DSEx.Predict.CodeAct`, `DSEx.Tool`, `DSEx.Sandbox` | `test/completion_surface_test.exs`, `test/public_surface_test.exs` | Local integration gate should cover tool/service boundary: `de-wrnz` | `docs/API_GUIDE.md`, `livebooks/03_agents_tools_mcp_rlm.livemd` | Keep as explicit tool/sandbox loop |
| Recursive language model loop | Implemented | `DSEx.Predict.RLM` | `test/rlm_test.exs`, `test/dsex_test.exs` | Live RLM is not required for V3 because deterministic action control is the correct oracle | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep as RLM, not RAG; docs must stay precise |
| Multi-chain comparison | Implemented | `DSEx.Predict.MultiChainComparison` | Covered through public-surface and optimizer suites | No live proof required for V3 | `docs/ARCHITECTURE.md` | Keep as composition primitive |
| Best-of-N and Refine | Implemented | `DSEx.Predict.BestOfN`, `DSEx.Predict.Refine` | `test/refine_feedback_test.exs` | Live orchestration test covers both over real provider calls | `docs/API_GUIDE.md` | Keep |
| Parallel map | Implemented | `DSEx.Predict.Parallel` | `test/production_hardening_test.exs` | Live orchestration test covers real concurrent calls | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep |
| KNN prediction | Implemented | `DSEx.Predict.KNN`, `DSEx.Retrievers.KNN` | `test/dsex_test.exs` | Local integration gate should include retrieval flows: `de-wrnz` | `docs/API_GUIDE.md` | Keep as retrieval composition primitive |

## Tools, Agents, MCP, and Retrieval

| Concept | DSEx status | DSEx surface | Deterministic tests | Integration/live proof | Docs | Release decision |
| --- | --- | --- | --- | --- | --- | --- |
| Tools with schema validation | Implemented | `DSEx.Tool`, `DSEx.Schema` | `test/agent_runtime_test.exs`, `test/mcp_import_test.exs`, `test/react_v2_contract_test.exs` | Live ReActV2 tool call test | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep |
| Agents, child agents, policies, traces | Implemented | `DSEx.Agent`, `DSEx.Agent.Runtime` | `test/agent_runtime_test.exs`, `test/public_surface_test.exs` | Local integration gate should cover a deployed agent flow: `de-wrnz` | `docs/API_GUIDE.md`, `livebooks/03_agents_tools_mcp_rlm.livemd` | Keep as BEAM-native composition layer |
| MCP in-process import | Implemented | `DSEx.MCP.InProcess`, `DSEx.MCP.import_tools/1` | `test/mcp_import_test.exs` | Local integration gate required for process/server lifecycle: `de-wrnz` | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep |
| MCP HTTP, stdio, Streamable HTTP transports | Implemented | `DSEx.MCP.HTTP`, `DSEx.MCP.Stdio`, `DSEx.MCP.StreamableHTTP` | `test/mcp_import_test.exs` | `mix integration.check` proves HTTP and stdio local E2E; Streamable HTTP remains deterministic contract coverage | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep |
| Memory retrieval | Implemented | `DSEx.Retrieve.Memory`, `DSEx.Retrieve` | `test/dsex_test.exs` | Local retrieval integration gate needed: `de-wrnz` | `docs/API_GUIDE.md` | Keep |
| External HTTP retrievers | Implemented | `DSEx.Retrievers.HTTP`, `Weaviate`, `Databricks` | `test/external_retriever_test.exs` | `mix integration.check` proves generic HTTP retriever local E2E; Weaviate/Databricks stay payload-contract tested | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep as payload-contract clients; live external retriever gate optional |
| Embeddings | Implemented | `DSEx.Embeddings`, `DSEx.Embeddings.Hash` | `test/completion_surface_test.exs`, `test/public_surface_test.exs` | Live embedding provider proof is not required for V3 | `docs/API_GUIDE.md` | Keep hash embedder as deterministic local baseline |

## Evaluation and Optimization

| Concept | DSEx status | DSEx surface | Deterministic tests | Integration/live proof | Docs | Release decision |
| --- | --- | --- | --- | --- | --- | --- |
| Evaluation loop | Implemented | `DSEx.Evaluate` | `test/dsex_test.exs`, `test/public_surface_test.exs`, `test/metric_contract_test.exs` | No live proof required for V3 | `docs/API_GUIDE.md`, `livebooks/02_evaluate_and_optimize.livemd` | Keep normalized score/feedback rows |
| Metrics | Implemented | `DSEx.Metrics`, `DSEx.Metrics.Result`, metric functions accepted by optimizers | `test/metric_contract_test.exs`, optimizer suites | No live proof required for V3 | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Support boolean, numeric, map, prediction, feedback, and trace-aware returns |
| Auto-evaluation helpers | Implemented | `DSEx.Evaluate.SemanticF1`, `CompleteAndGrounded` | `test/public_surface_test.exs` | No live proof required for V3 | `docs/API_GUIDE.md` | Keep as helper modules, not evaluator LMs |
| LabeledFewShot, BootstrapFewShot, KNNFewShot | Implemented | `DSEx.Optimizer.*FewShot` | `test/dsex_test.exs`, `test/optimizer_effectiveness_test.exs`, `test/public_surface_test.exs` | No live proof required for V3 | `docs/API_GUIDE.md` | Keep |
| RandomSearch and InstructionSearch | Implemented | `DSEx.Optimizer.RandomSearch`, `InstructionSearch`, `InstructionProposer` | `test/optimizer_effectiveness_test.exs`, `test/optimizer_report_test.exs` | No live proof required for V3 | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep |
| COPRO, MIPROv2, SIMBA, GEPA | Implemented | `DSEx.Optimizer.COPRO`, `MIPROv2`, `SIMBA`, `GEPA` | `test/optimizer_behavioral_corpus_test.exs`, `test/v2_benchmark_test.exs` | No live proof required for V3; deterministic reward-encoding controls are the oracle | `docs/V2.md`, `docs/API_GUIDE.md` | Keep with normalized metric signal |
| BetterTogether and Ensemble | Implemented | `DSEx.Optimizer.BetterTogether`, `DSEx.Optimizer.Ensemble` | `test/public_surface_test.exs` | No live proof required for V3 | `docs/API_GUIDE.md` | Keep |
| BootstrapFinetune and GRPO provider jobs | Implemented | `DSEx.Optimizer.BootstrapFinetune`, `DSEx.Optimizer.GRPO`, `DSEx.Clients.Trainer` | `test/provider_training_lifecycle_test.exs`, `test/completion_surface_test.exs` | Optional live training gate needed only for provider-side job claims: `de-i8cc`, `de-wrnz` | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Explicit trainer required; no local training fallback |
| Arbitrary artifact optimization | Implemented | `DSEx.Optimize.Anything`, `DSEx.Optimize.GEPA` | `test/optimize_anything_test.exs`, `test/optimize_gepa_test.exs` | No live proof required for V3 | `docs/V2.md`, `livebooks/02_evaluate_and_optimize.livemd` | Keep as DSEx-native extension of optimize_anything ideas |

## Persistence, Operations, and Release Gates

| Concept | DSEx status | DSEx surface | Deterministic tests | Integration/live proof | Docs | Release decision |
| --- | --- | --- | --- | --- | --- | --- |
| Save/load | Implemented | `DSEx.Saving`, program `dump/1` paths | `test/production_adapter_persistence_test.exs`, `test/production_hardening_test.exs` | `mix integration.check` proves save/load/rebind/deployed-call through local HTTP | `docs/API_GUIDE.md`, `docs/ARCHITECTURE.md` | Keep with explicit credential rebinding |
| Secret redaction | Implemented | `DSEx.Redaction`, trace and telemetry call sites | `test/agent_runtime_test.exs`, `test/production_hardening_test.exs` | Telemetry redaction covered in production hardening tests | `docs/PRODUCTION_OPERATIONS.md` | Keep as non-negotiable security invariant |
| Telemetry and observability | Implemented | `DSEx.Telemetry`, runtime call sites | `test/production_hardening_test.exs`, `test/provider_streaming_test.exs`, `test/mcp_import_test.exs`, `test/external_retriever_test.exs`, `test/provider_training_lifecycle_test.exs`, `test/optimizer_report_test.exs` | Local integration and live provider gates exercise instrumented paths | `docs/PRODUCTION_OPERATIONS.md`, `docs/ARCHITECTURE.md` | Keep event families stable and redacted |
| Production gate | Implemented | `mix production.check` | `test/gate_contract_test.exs` | Runs locally | `docs/PRODUCTION_OPERATIONS.md` | Keep |
| V2 gate | Implemented | `mix v2.check` | `test/gate_contract_test.exs`, `test/v2_benchmark_test.exs` | Runs locally | `docs/PRODUCTION_OPERATIONS.md`, `docs/V2.md` | Keep |
| Live inference gate | Implemented | `mix live.check` | `test/gate_contract_test.exs` | `LIVE_PROVIDER=1 mix live.check` | `README.md`, `docs/PRODUCTION_OPERATIONS.md` | Keep as paid live inference gate |
| Local integration gate | Implemented | `mix integration.check`, `test/integration` | `test/gate_contract_test.exs`, `test/integration/gate_contract_test.exs` | Local service E2E covers provider HTTP, retriever HTTP, MCP HTTP, MCP stdio, and save/load/rebind | `docs/PRODUCTION_OPERATIONS.md`, `docs/RELEASE_CRITERIA.md` | Keep and expand only when the production surface grows |
| Optional live stateful aliases | Reserved | `mix live.training.check`, `mix live.retriever.check`, `mix live.mcp.check` | Gate-contract tests under `test/live_*` | They do not prove external services until real service tests are added | `docs/PRODUCTION_OPERATIONS.md`, `docs/RELEASE_CRITERIA.md` | Keep reserved and do not claim live proof |
| Documentation and Livebooks | Implemented | `docs/*`, `livebooks/*`, ExDoc extras | `mix docs` via `production.check`, `test/livebook_contract_test.exs` | Production Livebook names the complete gate set | `docs/README.md` | Keep contract-tested |

## Intentional Deviations From Python DSPy

| Upstream concept | DSEx decision | Rationale | Guardrail |
| --- | --- | --- | --- |
| Python object mutation and dynamic globals | Use structs plus explicit process-local settings | Elixir code should be inspectable, immutable by default, and process-safe | `test/dsex_test.exs`, `test/dsex_facade_test.exs` |
| Python callbacks with loosely shaped kwargs | Use functions, behaviours, structs, and maps/keywords | Elixir callers expect explicit data shapes and pattern matching | Public constructors and behaviours must be documented and validated under `de-qvwf` |
| Python-side code execution for PoT/CodeAct | Use `DSEx.Sandbox` with an allowlisted expression evaluator | BEAM-safe execution is part of production trust | `test/completion_surface_test.exs`, `test/production_hardening_test.exs` |
| Provider-specific magic as default behaviour | Use explicit provider structs and injected transports | Production Elixir systems should make network and credentials visible | `test/production_hardening_test.exs`, `docs/PRODUCTION_OPERATIONS.md` |
| Treating all external workflows as one live test | Split deterministic, local integration, live inference, and stateful paid gates | Different proof levels have different cost, flake, and safety profiles | `de-i8cc`, `de-wrnz` |

# Production Audit

This audit is intentionally adversarial. Passing `mix production.check` proves
the deterministic gate is green; it does not by itself prove the library is
production-ready. Production readiness requires every `P0` and `P1` requirement
below to be `PROVEN`.

Statuses:

- `PROVEN`: backed by code plus tests or live/contract evidence.
- `PARTIAL`: meaningful implementation exists, but evidence is not broad enough.
- `UNPROVEN`: not implemented or not verified enough for production.

## Requirements

| ID | Priority | Requirement | Status | Evidence | Next action |
| --- | --- | --- | --- | --- | --- |
| API-001 | P0 | Generated upstream public export parity is enforced in CI. | PROVEN | `mix parity.generate`, `mix parity.check`, CI workflow | Keep snapshot current with upstream updates. |
| CORE-001 | P0 | Signatures, examples, predictions, settings, and modules behave as stable public API. | PROVEN | `dspy_elixir_test.exs`, `production_adapter_persistence_test.exs` | Add docs examples before Hex release. |
| ADAPT-001 | P0 | Chat/JSON/XML/two-step adapters parse required fields, type coercion, missing fields, and fenced JSON. | PROVEN | `production_adapter_persistence_test.exs`, `completion_surface_test.exs` | Add multimodal binary fixture tests. |
| LM-001 | P0 | OpenAI-compatible provider supports non-streaming, structured JSON, retries, and provider tool-call normalization. | PROVEN | `live_provider_test.exs`, `provider_tool_call_test.exs`, `production_hardening_test.exs` | Add live streaming once provider/account supports it reliably. |
| STREAM-001 | P1 | Provider SSE streaming is parsed into stable stream events and exposed through program streaming. | PROVEN | `provider_streaming_test.exs` | Add live streaming gate. |
| RET-001 | P1 | In-memory, Weaviate-style, and Databricks-style retrieval contracts are covered. | PROVEN | `external_retriever_test.exs` | Add optional live gates for real Weaviate/Databricks endpoints. |
| TRAIN-001 | P1 | Provider training jobs support submit, status refresh, auth, result-model extraction, and teleprompter integration. | PROVEN | `provider_training_lifecycle_test.exs` | Add real live training gate only with safe small fixtures and user opt-in. |
| OPT-001 | P0 | Optimizers measurably improve score where possible and record candidate reports. | PROVEN | `optimizer_effectiveness_test.exs`, `optimizer_report_test.exs` | Compare against upstream examples for deeper algorithm parity. |
| OPT-002 | P1 | MIPROv2, GEPA, SIMBA, COPRO behavior is faithful enough for production workloads, not only simplified search. | PROVEN | `test/optimizer_behavioral_corpus_test.exs` proves optimizer-specific invariants: MIPROv2 joint instruction/demo search, GEPA feedback/reflection candidates, SIMBA monotonic mini-batch ascent, and COPRO breadth/depth coordinate reports. | Re-run against upstream benchmark fixtures when DSPy publishes stable optimizer behavioral corpora. |
| MULTI-001 | P1 | Multimodal adapter types encode/decode provider-compatible image/audio/file/document payloads. | PROVEN | `test/multimodal_adapter_test.exs` covers OpenAI-compatible image/audio/file/document/code/reasoning encoding, HTTP request payload integration, and provider block decoding. | Keep adding provider-specific fixtures when new provider multimodal schemas are introduced. |
| DATA-001 | P1 | Dataset loaders cover JSONL/CSV/GSM8K/HotPotQA/MATH/Colors and reject malformed rows clearly. | PROVEN | `test/datasets_contract_test.exs` covers malformed JSONL, missing required input keys, ragged CSV rows, and typed GSM8K/HotPotQA/MATH/Colors ingestion. | Extend with fixture snapshots for newly added upstream datasets. |
| SAVE-001 | P0 | Program save/load is JSON-safe, rejects unsupported types, preserves adapter/provider config, and does not persist secrets. | PROVEN | `production_adapter_persistence_test.exs`, `production_hardening_test.exs` | Add versioned state migration tests. |
| ERR-001 | P0 | Provider errors, retryable failures, parse errors, and unsupported operations are explicit. | PROVEN | `production_hardening_test.exs`, adapter tests | Broaden error taxonomy to match every upstream LM error subtype. |
| DOC-001 | P1 | Production docs describe proven gates and do not claim unresolved requirements as complete. | PROVEN | `PRODUCTION.md`, this audit | Keep final answers aligned with audit status. |

## Current Verdict

The project is not yet production-ready. It has many proven production slices,
but production readiness remains `PARTIAL` until every P0 and P1 row above is
`PROVEN`.

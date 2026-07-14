# Adapter Fidelity

Imp adapters follow DSPy's philosophical contract: signatures are rendered into
structured model messages, and raw model output is parsed back into named,
schema-checked fields. Imp keeps the implementation Elixir-native rather than
trying to byte-match Python prompt templates.

## Upstream Anchors

- DSPy `ChatAdapter` uses `[[ ## field_name ## ]]` delimiters, formats demos and
  conversation history as multiturn messages, and defaults to JSON fallback when
  chat parsing fails.
- DSPy `JSONAdapter` requests structured JSON behavior and parses provider JSON
  into signature fields.
- DSPy `XMLAdapter` and `TwoStepAdapter` are alternate formatting/parsing
  strategies over the same signature contract.
- DSPy `ChatAdapter` also has provider-native function-calling flags. In Imp,
  provider-native tool calling belongs to `Imp.Clients.ReqLLM` and ReAct/tool
  modules, not the plain chat adapter.

## Imp Mapping

| Upstream surface | Imp surface | Evidence |
| --- | --- | --- |
| Chat field delimiters | `Imp.Adapter.Chat` renders and parses `[[ ## field ## ]]` blocks | `test/production_adapter_persistence_test.exs` |
| JSON fallback | `Imp.Adapter.Chat.parse/3` falls back to JSON object parsing when labelled parsing fails | `test/production_adapter_persistence_test.exs` |
| JSON structured-output options | `Imp.Adapter.JSON.lm_opts/2` requests JSON object or JSON Schema response formats | `test/schema_constraints_test.exs`, `test/production_adapter_persistence_test.exs` |
| XML fields | `Imp.Adapter.XML` parses `<field>...</field>` and validates through the shared schema path | `test/production_adapter_persistence_test.exs` |
| Two-step planning | `Imp.Adapter.TwoStep` prepends a `plan` field before final outputs | `test/completion_surface_test.exs` |
| Demos/history | `Imp.Adapter.Chat` renders examples and `Imp.History` task turns as user/assistant turns, including partial demos with explicit missing-field markers | `test/production_adapter_persistence_test.exs`, `test/history_test.exs` |
| Tool formatting | Provider-native tools flow through `Imp.Clients.ReqLLM`; iterative tool use flows through `Imp.Predict.ReAct`, `CodeAct`, and `RLM` | `test/req_llm_client_test.exs`, `test/golden_trace_test.exs`, `test/integration/local_service_e2e_test.exs` |
| Streaming chunks | `Imp.Streaming.Messages.StreamListener` incrementally frames Chat, JSON, and XML fields with bounded parser state; custom adapters may provide bounded exact delimiters | `test/stream_listener_incremental_test.exs`, `test/completion_surface_test.exs`, `mix benchmark.operations_stress.check` |

## Intentional Deviations

Imp does not expose Python `ChatAdapter` constructor flags such as
`use_native_function_calling` or `parallel_tool_calls` on `Imp.Adapter.Chat`.
Those are provider transport concerns in Imp and are handled by
`Imp.Clients.ReqLLM` plus module-level tool policies. This keeps adapters as
format/parse behaviours and keeps side-effectful tool execution under explicit
program modules.

Imp prompt text is not byte-identical to DSPy. The benchmark-safe contract is
semantic: field names, delimiter structure, demo/history turn shape, parse
errors, retry feedback, and provider option intent are stable and tested.

Stream listeners select their adapter explicitly because normalized provider
events do not carry adapter identity. JSON framing uses a bounded lexical parser
rather than decoding an incomplete document; XML follows the adapter's exact
tag model rather than claiming namespace-aware XML parsing. Custom framing
accepts data delimiters only, never executable callbacks or regular expressions.

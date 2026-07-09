# Adapter Fidelity

DSEx adapters follow DSPy's philosophical contract: signatures are rendered into
structured model messages, and raw model output is parsed back into named,
schema-checked fields. DSEx keeps the implementation Elixir-native rather than
trying to byte-match Python prompt templates.

## Upstream Anchors

- DSPy `ChatAdapter` uses `[[ ## field_name ## ]]` delimiters, formats demos and
  conversation history as multiturn messages, and defaults to JSON fallback when
  chat parsing fails.
- DSPy `JSONAdapter` requests structured JSON behavior and parses provider JSON
  into signature fields.
- DSPy `XMLAdapter` and `TwoStepAdapter` are alternate formatting/parsing
  strategies over the same signature contract.
- DSPy `ChatAdapter` also has provider-native function-calling flags. In DSEx,
  provider-native tool calling belongs to `DSEx.Clients.ReqLLM` and ReAct/tool
  modules, not the plain chat adapter.

## DSEx Mapping

| Upstream surface | DSEx surface | Evidence |
| --- | --- | --- |
| Chat field delimiters | `DSEx.Adapter.Chat` renders and parses `[[ ## field ## ]]` blocks | `test/production_adapter_persistence_test.exs` |
| JSON fallback | `DSEx.Adapter.Chat.parse/3` falls back to JSON object parsing when labelled parsing fails | `test/production_adapter_persistence_test.exs` |
| JSON structured-output options | `DSEx.Adapter.JSON.lm_opts/2` requests JSON object or JSON Schema response formats | `test/schema_constraints_test.exs`, `test/production_adapter_persistence_test.exs` |
| XML fields | `DSEx.Adapter.XML` parses `<field>...</field>` and validates through the shared schema path | `test/production_adapter_persistence_test.exs` |
| Two-step planning | `DSEx.Adapter.TwoStep` prepends a `plan` field before final outputs | `test/completion_surface_test.exs` |
| Demos/history | `DSEx.Adapter.Chat` renders examples as user/assistant turns, including partial demos with explicit missing-field markers | `test/production_adapter_persistence_test.exs` |
| Tool formatting | Provider-native tools flow through `DSEx.Clients.ReqLLM`; iterative tool use flows through `DSEx.Predict.ReAct`, `CodeAct`, and `RLM` | `test/req_llm_client_test.exs`, `test/golden_trace_test.exs`, `test/integration/local_service_e2e_test.exs` |
| Streaming chunks | Field chunk parsing is handled by `DSEx.Streaming` over adapter delimiters | `test/completion_surface_test.exs`, `mix benchmark.operations_stress.check` |

## Intentional Deviations

DSEx does not expose Python `ChatAdapter` constructor flags such as
`use_native_function_calling` or `parallel_tool_calls` on `DSEx.Adapter.Chat`.
Those are provider transport concerns in DSEx and are handled by
`DSEx.Clients.ReqLLM` plus module-level tool policies. This keeps adapters as
format/parse behaviours and keeps side-effectful tool execution under explicit
program modules.

DSEx prompt text is not byte-identical to DSPy. The benchmark-safe contract is
semantic: field names, delimiter structure, demo/history turn shape, parse
errors, retry feedback, and provider option intent are stable and tested.

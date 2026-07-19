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
- DSPy `XMLAdapter` emits a single XML-only system message and raises
  `AdapterParseError` when required output tags are absent. `Imp.Adapter.XML`
  ports this shape faithfully (dee-ovd3): byte-parity is measured per call in
  the golden differential (`xml_*` cases). DSPy `TwoStepAdapter` sends a
  free-form main prompt, then runs a second extraction LM with `ChatAdapter`
  over a synthesized `text -> outputs` signature. Imp's `Imp.Adapter.TwoStep`
  does NOT port that shape (see Declared Divergences below); it stays
  registered as a gap, not conformant, in the conformance report (dee-qt5r).
- DSPy `ChatAdapter` also has provider-native function-calling flags. In Imp,
  provider-native tool calling belongs to `Imp.Clients.ReqLLM` and ReAct/tool
  modules, not the plain chat adapter.

## Imp Mapping

| Upstream surface | Imp surface | Evidence |
| --- | --- | --- |
| Chat field delimiters | `Imp.Adapter.Chat` renders and parses `[[ ## field ## ]]` blocks | `test/production_adapter_persistence_test.exs` |
| JSON fallback | `Imp.Adapter.Chat.parse/3` falls back to JSON object parsing when labelled parsing fails | `test/production_adapter_persistence_test.exs` |
| JSON structured-output options | `Imp.Adapter.JSON.lm_opts/2` requests JSON object or JSON Schema response formats | `test/schema_constraints_test.exs`, `test/production_adapter_persistence_test.exs` |
| XML fields | `Imp.Adapter.XML` renders DSPy XMLAdapter's single XML-only dialect (XML-wrapped structure/inputs/demo outputs, no `[[ ## ]]` markers, no completed sentinel) and parses `<field>...</field>` through the shared schema path, rejecting missing tags loudly; parse failures retry through the JSON adapter exactly like DSPy's inherited fallback | `test/golden_trace_test.exs` (`xml_*` cases), `test/production_adapter_persistence_test.exs`, `test/silent_failure_regressions_test.exs` |
| Two-step planning | `Imp.Adapter.TwoStep` prepends a `plan` field before final outputs — an Imp extension, not DSPy `TwoStepAdapter` (see Declared Divergences) | `test/completion_surface_test.exs` |
| Demos/history | `Imp.Adapter.Chat` renders examples and `Imp.History` task turns as user/assistant turns, including partial demos with explicit missing-field markers | `test/production_adapter_persistence_test.exs`, `test/history_test.exs` |
| Tool formatting | Provider-native tools flow through `Imp.Clients.ReqLLM`; iterative tool use flows through `Imp.Predict.ReAct`, `CodeAct`, and `RLM` | `test/req_llm_client_test.exs`, `test/golden_trace_test.exs`, `test/integration/local_service_e2e_test.exs` |
| Streaming chunks | `Imp.Streaming.Messages.StreamListener` incrementally frames Chat, JSON, and XML fields with bounded parser state; custom adapters may provide bounded exact delimiters | `test/stream_listener_incremental_test.exs`, `test/completion_surface_test.exs` |

## Declared Divergences (registered as gaps, not conformance)

`Imp.Adapter.TwoStep` (dee-qt5r): this is an Imp extension that prepends a
`:plan` output field and delegates to Chat. It is not a port of DSPy's
TwoStepAdapter — no second extraction LM exists anywhere in
`lib/imp/adapter/`, and the `format/3` + `parse/3` behaviour has no LM
handle to express one. A faithful port is tracked in dee-qt5r.

(`Imp.Adapter.XML` was listed here until dee-ovd3 landed the faithful
XMLAdapter port; its byte-parity is now measured, locked in the golden
differential, and registered as conformant.)

## Intentional Deviations

Imp does not expose Python `ChatAdapter` constructor flags such as
`use_native_function_calling` or `parallel_tool_calls` on `Imp.Adapter.Chat`.
Those are provider transport concerns in Imp and are handled by
`Imp.Clients.ReqLLM` plus module-level tool policies. This keeps adapters as
format/parse behaviours and keeps side-effectful tool execution under explicit
program modules.

Imp prompt text IS byte-identical to DSPy 3.2.1 across the measured surface
(epic dee-8zev, 2026-07-18): 37 of 40 golden differential cases match real DSPy
byte-for-byte on BOTH the rendered messages and the per-call request envelope
(`mix imp.benchmark.trace` vs the pinned `dspy==3.2.1` venv) — predict,
ChainOfThought, typed/enum/list/dict fields, few-shot demos, conversation
history, multi-line/CRLF/unicode instructions, RAG list inputs, DSPy-faithful
ReAct (`mode: :dspy_3_2_1`), the XML adapter (dee-ovd3: basic, typed,
enum, multi-output, and the parse-failure JSON fallback), and capability-gated
`response_format`. The only 3 non-matching cases are Imp's DEFAULT
provider-native ReAct mode, an intentional design choice (native function-tool
calling); the byte-faithful `:dspy_3_2_1` mode ships alongside it. Byte-parity
is enforced per-PR in CI (`mix parity.check`, dee-3e4v) so it cannot silently
regress. Known, ticketed limitations: the two_step adapter is not yet in the
differential (dee-1gb9/dee-qt5r);
real-model `response_format` decisions follow the ReqLLM/LLMDB registry and match
DSPy only where it agrees with litellm (dee-7r2t); parse leniency is stricter
than DSPy's `json_repair` (dee-q2w2); multi-key dict value ordering (dee-1fd0).
Beyond byte-parity, the semantic contract (field names, delimiter structure,
demo/history turn shape, parse errors, retry feedback, provider option intent)
remains stable and tested.

Stream listeners select their adapter explicitly because normalized provider
events do not carry adapter identity. JSON framing uses a bounded lexical parser
rather than decoding an incomplete document; XML follows the adapter's exact
tag model rather than claiming namespace-aware XML parsing. Custom framing
accepts data delimiters only, never executable callbacks or regular expressions.

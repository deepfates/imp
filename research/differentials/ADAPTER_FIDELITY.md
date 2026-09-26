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
- DSPy `XMLAdapter` emits a single XML-only system message, recursively encodes
  typed outputs, and raises `AdapterParseError` when required output tags are
  absent. `Imp.Adapter.XML` retains the historical scalar prompt differential
  and implements DSPy 3.3.1's recursive object/list/mapping/union semantics with
  a real XML parser. DSPy `TwoStepAdapter` sends a
  free-form main prompt, then runs a second extraction LM with `ChatAdapter`
  over a synthesized `text -> outputs` signature. `Imp.Adapter.TwoStep` ports
  that shape faithfully (dee-qt5r): both stages are parity-measured in
  the golden differential (`two_step_*` cases), and the extraction LM threads
  through `two_step_extraction_lm` settings (mapping DSPy's
  `TwoStepAdapter(extraction_model=...)`).
- DSPy `ChatAdapter` also has provider-native function-calling flags. In Imp,
  provider-native tool calling belongs to `Imp.Clients.ReqLLM` and ReAct/tool
  modules, not the plain chat adapter.

## Imp Mapping

| Upstream surface | Imp surface | Evidence |
| --- | --- | --- |
| Chat field delimiters | `Imp.Adapter.Chat` renders and parses `[[ ## field ## ]]` blocks with DSPy `ChatAdapter.parse`'s exact section semantics: line-based headers, first occurrence wins, loud error on any missing output field (no single-output leniency, no label-line parsing — dee-coia); the one Imp exception is a signature-declared `metadata[:text_step]` field, which takes a completion carrying no marker at all | `test/production_adapter_persistence_test.exs`, `test/upstream_exam/adapters_test.exs`, `test/adapter_chat_text_step_test.exs` |
| JSON fallback | A failed chat parse retries through `Imp.Adapter.JSON` with a SECOND LM call in `Imp.Predict` (DSPy `ChatAdapter.__call__`'s fallback; disable with `config: [json_fallback: false]`); JSON parsing itself repairs Python-dict spellings via `Imp.Adapter.JSONRepair` (dee-16qm). Imp extension: a signature that sets `metadata[:text_step]` reads a marker-free completion as that output field instead of failing, so a native tool loop's prose step does not buy a second call in another dialect | `test/upstream_exam/adapters_test.exs`, `test/production_adapter_persistence_test.exs` |
| JSON structured-output options | `Imp.Adapter.JSON.lm_opts/2` requests JSON object or JSON Schema response formats | `test/schema_constraints_test.exs`, `test/production_adapter_persistence_test.exs` |
| XML fields | `Imp.Adapter.XML` renders DSPy XMLAdapter's single XML-only dialect (XML-wrapped structure/inputs/demo outputs, no `[[ ## ]]` markers, no completed sentinel), recursively round-trips typed objects, arrays, repeated mapping values, empty collections, nullable/defaulted fields, and structured unions, preserves legacy JSON-in-tag values, rejects malformed/DTD/entity input, and sends parse failures through the ordinary JSON fallback | `test/upstream_exam/adapters_test.exs`, `test/golden_trace_test.exs` (`xml_*` scalar cases), `test/production_adapter_persistence_test.exs`, `test/silent_failure_regressions_test.exs` |
| Two-step extraction | `Imp.Adapter.TwoStep` renders DSPy TwoStepAdapter's persona main prompt and runs the second extraction LM through the ChatAdapter path over the synthesized `text -> outputs` signature (JSONAdapter fallback included) | `test/golden_trace_test.exs` (`two_step_*` cases), `test/completion_surface_test.exs` |
| Two-step planning (Imp extension) | `Imp.Adapter.PlanFirst` prepends a `plan` field before final outputs — an honest Imp extension, formerly misnamed `Imp.Adapter.TwoStep` | `test/completion_surface_test.exs` |
| Demos/history | `Imp.Adapter.Chat` renders examples and `Imp.History` task turns as user/assistant turns, including partial demos with explicit missing-field markers | `test/production_adapter_persistence_test.exs`, `test/history_test.exs` |
| Tool formatting | Provider-native tools flow through `Imp.Clients.ReqLLM`; iterative tool use flows through `Imp.Predict.ReAct`, `CodeAct`, and `RLM` | `test/req_llm_client_test.exs`, `test/golden_trace_test.exs`, `test/integration/local_service_e2e_test.exs` |
| Streaming chunks | `Imp.Streaming.Messages.StreamListener` incrementally frames Chat, JSON, and XML fields with bounded parser state; custom adapters may provide bounded exact delimiters | `test/stream_listener_incremental_test.exs`, `test/completion_surface_test.exs` |

## Declared Divergences (registered as gaps, not conformance)

The completed current-stable audit repaired output defaults, recursive XML, MCP
result normalization, explicit eager multimodal resource loading, and native
typed reasoning. Exact DSPy 3.3.1 probes and the generated conformance ledger
own those newer semantics; historical scalar prompt byte parity is not evidence
for them. Python class identity, aliases, and mutable `default_factory` objects
remain intentional language-level differences represented by portable map
schemas and immutable literal defaults rather than Python runtime objects.

## Intentional Deviations

Imp does not expose Python `ChatAdapter` constructor flags such as
`use_native_function_calling` or `parallel_tool_calls` on `Imp.Adapter.Chat`.
Those are provider transport concerns in Imp and are handled by
`Imp.Clients.ReqLLM` plus module-level tool policies. This keeps adapters as
format/parse behaviours and keeps side-effectful tool execution under explicit
program modules.

Prompts name types in neutral words, not Python annotations: `` `team` (one
of: atlas, harbor) `` where DSPy writes `` `team` (Literal['atlas', 'harbor']) ``,
"string", "integer", "true or false", "list of strings" and "object" for
`str`, `int`, `bool`, `list[str]` and `dict[str, Any]`, and ReAct's
`:dspy_3_2_1` mode lists tool arguments as JSON. `Imp.Adapter.FieldType`
declares the wording once. DSPy parity means the same behaviour and the same
information in the prompt, not DSPy's text (`decisions.md`). The golden
differential (`mix imp.benchmark.trace` against the pinned `dspy==3.2.1` venv)
compares prompts after putting DSPy's annotations into Imp's words
(`Imp.DSPyWording`), so everything else is still compared byte for byte:
39 of 42 cases match DSPy 3.2.1 on the rendered messages and the per-call
request envelope — predict, ChainOfThought, typed/enum/list/dict fields,
few-shot demos, conversation history, multi-line/CRLF/unicode instructions,
RAG list inputs, ReAct `mode: :dspy_3_2_1`, the XML adapter, the TwoStep
adapter (both calls), and capability-gated `response_format`. The 3 that do
not are Imp's default provider-native ReAct mode, an intentional design
choice. `mix parity.check` runs it; it needs the pinned DSPy environment and
is not part of `mix check`. Known limitations:
real-model `response_format` decisions follow the ReqLLM/LLMDB registry and match
DSPy only where it agrees with litellm (dee-7r2t); parse leniency is stricter
than DSPy's `json_repair` (dee-q2w2); multi-key dict value ordering (dee-1fd0).
Beyond prompt text, the semantic contract (field names, delimiter structure,
demo/history turn shape, parse errors, retry feedback, provider option intent)
remains stable and tested.

Stream listeners select their adapter explicitly because normalized provider
events do not carry adapter identity. JSON framing uses a bounded lexical parser
rather than decoding an incomplete document; XML streaming frames declared
top-level fields while completed responses are parsed by Saxy into recursive
typed values. Custom framing
accepts data delimiters only, never executable callbacks or regular expressions.

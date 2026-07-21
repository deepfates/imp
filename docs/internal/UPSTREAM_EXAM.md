# Upstream Exam: DSPy 3.2.1's own tests vs Imp

Tranche 1: `tests/adapters/` + `tests/signatures/` (below).
Tranche 2: `tests/predict/` (second section of this document).
Tranche 3: `tests/teleprompt/` + `tests/evaluate/` + `tests/streaming/`
(third section).

## Tranche 1 — adapters/ and signatures/

The DSPy authors' own test suite (dspy-3.2.1, `tests/adapters/` — 13 files —
and `tests/signatures/` — 4 files) run against Imp. Every upstream test
function is accounted for below. Ported tests live in
`test/upstream_exam/adapters_test.exs` and
`test/upstream_exam/signatures_test.exs` (`mix test --only upstream_exam`).
The exam landed as a map (PR #68, 14 real divergences tagged
`@tag :upstream_fail` + `:skip`); the fix pass (dee-coia, dee-16qm, dee-jbav,
dee-xyhv, dee-4fuy, dee-pkvp, dee-1nkd) closed all 14 without weakening a
single ported assertion, and the skip tags are gone — every ported test runs
and passes.

## Totals

| Metric | Count |
|---|---|
| Upstream test functions in scope | **243** (adapters 149, signatures 94) |
| Ported | **81** (82 ExUnit tests; one upstream test split in two) |
| — pass | **81** |
| — FAIL (real divergence found by upstream's own test) | **0** (14 found by the exam; all fixed) |
| — unclear | 0 |
| Blocked (behavior should/could exist in Imp; not expressible yet) | **77** |
| Not applicable (Python/pydantic/litellm/asyncio specific, or deliberate Imp design substitution) | **85** |

### The 14 original FAILs, clustered by root cause — all fixed

1. **Chat parse single-output leniency** (4, fixed by dee-coia): `Chat.parse`
   now ports DSPy `ChatAdapter.parse` exactly — line-based
   `[[ ## field ## ]]` section split, first occurrence wins, loud error when
   any output field is missing. The single-output stuffing, the lenient
   `name: value` label parsing, and the in-parse JSON decode are gone; the
   chat→JSON fallback (a second LM call in `Imp.Predict`) now fires exactly
   as upstream's does.
2. **No json-repair** (2, fixed by dee-16qm; closes dee-q2w2):
   `Imp.Adapter.JSONRepair` ports the json_repair/ast.literal_eval ladder
   (strict JSON, then Python-dict spellings: single quotes, True/False/None,
   trailing commas) and the balanced-`{...}`-block extraction
   `JSONAdapter.parse` performs; used by chat field coercion and JSON parse.
3. **parse_value scalar/str semantics** (2, fixed by dee-jbav): str-annotated
   fields render through Python `str()` (`True`→"True", `None`→"None",
   `[1, 2, 3]`→"[1, 2, 3]"); Literal parsing strips `Literal[...]`/`str[...]`
   wrappers and wrapping quotes before enum matching.
4. **Literal rendering of non-string members** (1, fixed by dee-xyhv):
   non-string Literal members render bare via Python `str()`
   (`Literal[1, 'bar']`, `Literal[True, 3, 'foo']`); only string members are
   quoted.
5. **ToolCalls.format wire shape** (2, fixed by dee-4fuy): `ToolCalls.format`
   emits the OpenAI shape `{"type": "function", "function": {"name",
   "arguments"}}` (Imp's stable id rides at the top level when present).
6. **Audio x- format normalization** (1, fixed by dee-pkvp): one leading
   `x-` is stripped from the audio subtype (`audio/x-wav` → `"wav"`).
7. **Signature-surface gaps** (3, fixed by dee-1nkd): duplicate names across
   the arrow raise a ParseError; `infer_prefix` ports DSPy's camelCase/digit
   splitting and Title Case with acronym preservation; the string-spec parser
   accepts the Python spellings `str` and `dict`.

Notable byte-level passes throughout: chat, JSON, and XML
`format_system_message` (full-string equality including type notes and
JSON-schema escapes), conversation-history message shapes for chat and JSON,
the two-step main+extraction round trip, XML parse/cast/missing-field errors,
and Literal quoting across all five scenarios.

## Legend

- **pass** — ported faithfully; passes against Imp.
- **pass (was FAIL)** — the exam found a real divergence here; the fix pass
  closed it without weakening the ported assertion (ticket in the note).
- **blocked** — the behavior should or could exist in Imp but the test cannot
  be expressed (missing type, missing API surface). Includes work deferred to
  the teleprompt tranche.
- **n/a** — Python-specific (pydantic internals, asyncio, litellm plumbing,
  PIL/network, pickle, Python class/frame mechanics) or a feature Imp
  deliberately replaces with a documented design substitution.
- *(partial)* — the portable half is ported and passing; the note names what
  is not expressible.

## tests/adapters/test_adapter_utils.py (6)

| Upstream test | Status | Note |
|---|---|---|
| test_parse_value_str_annotation | pass (was FAIL) | Fixed by dee-jbav: str-annotated fields render through Python `str()` (`True`→"True", `None`→"None", `[1, 2, 3]`→"[1, 2, 3]"). |
| test_parse_value_pydantic_types | n/a | Pydantic BaseModel validation; Imp has no user-defined model field types. |
| test_parse_value_basic_types | pass | int/float/bool/list[int] conversions match, incl. JSON-decoding `"[1, 2, 3]"` for an array field. |
| test_parse_value_literal | pass (was FAIL) | Fixed by dee-jbav: `Literal[...]`/`str[...]` wrappers and wrapping quotes stripped before enum matching, exactly as parse_value does. |
| test_parse_value_union | blocked | Imp signatures have no Optional/Union type surface. |
| test_parse_value_json_repair | pass (was FAIL) | Fixed by dee-16qm: `Imp.Adapter.JSONRepair` ports the json_repair/ast.literal_eval ladder for Python-dict spellings; malformed input still errors loudly. |

## tests/adapters/test_audio.py (1)

| Upstream test | Status | Note |
|---|---|---|
| test_normalize_audio_format | pass (was FAIL) | Fixed by dee-pkvp: ported over `Types.to_openai/1` (mime→format); one leading `x-` is stripped (`x-wav`→`wav`), interior runs preserved. |

## tests/adapters/test_baml_adapter.py (21)

All 21 blocked: **Imp has no BAMLAdapter port** (BAML appears in docs only as
prior-art). Most also require pydantic model schemas. One row each:

| Upstream test | Status | Note |
|---|---|---|
| test_baml_adapter_basic_schema_generation | blocked | No BAMLAdapter in Imp. |
| test_baml_adapter_handles_optional_fields | blocked | No BAMLAdapter. |
| test_baml_adapter_handles_primitive_types | blocked | No BAMLAdapter. |
| test_baml_adapter_handles_lists_with_bracket_notation | blocked | No BAMLAdapter. |
| test_baml_adapter_handles_complex_nested_models | blocked | No BAMLAdapter; pydantic nesting. |
| test_baml_adapter_raise_error_on_circular_references | blocked | No BAMLAdapter. |
| test_baml_adapter_formats_pydantic_inputs_as_clean_json | blocked | No BAMLAdapter; pydantic inputs. |
| test_baml_adapter_handles_mixed_input_types | blocked | No BAMLAdapter. |
| test_baml_adapter_handles_schema_generation_errors_gracefully | blocked | No BAMLAdapter. |
| test_baml_adapter_raises_on_missing_fields | blocked | No BAMLAdapter. |
| test_baml_adapter_handles_type_casting_errors | blocked | No BAMLAdapter. |
| test_baml_adapter_with_images | blocked | No BAMLAdapter. |
| test_baml_adapter_with_tools | blocked | No BAMLAdapter; also typed tool fields (see chat). |
| test_baml_adapter_with_code | blocked | No BAMLAdapter; also Code field type. |
| test_baml_adapter_with_conversation_history | blocked | No BAMLAdapter. |
| test_baml_vs_json_adapter_token_efficiency | blocked | No BAMLAdapter. |
| test_baml_vs_json_adapter_functional_compatibility | blocked | No BAMLAdapter. |
| test_baml_adapter_async_functionality | blocked | No BAMLAdapter (and asyncio). |
| test_baml_adapter_with_field_aliases | blocked | No BAMLAdapter; pydantic aliases. |
| test_baml_adapter_field_alias_without_description | blocked | No BAMLAdapter; pydantic aliases. |
| test_baml_adapter_multiple_pydantic_input_fields | blocked | No BAMLAdapter; pydantic inputs. |

## tests/adapters/test_base_type.py (2)

| Upstream test | Status | Note |
|---|---|---|
| test_basic_extract_custom_type_from_annotation | n/a | Traverses Python type annotations for custom `dspy.Type` classes; Imp has no annotation-based custom type system. |
| test_extract_custom_type_from_annotation_with_nested_type | n/a | Same. |

## tests/adapters/test_chat_adapter.py (26)

| Upstream test | Status | Note |
|---|---|---|
| test_chat_adapter_quotes_literals_as_expected | pass (was FAIL, partial) | Scenarios 1–4 always passed byte-for-byte; scenario 5 fixed by dee-xyhv — non-string Literal members render bare (`Literal[1, 'bar']`). |
| test_chat_adapter_sync_call | pass | Predict + chat adapter + fixture LM returning the marker completion → answer "Paris". |
| test_chat_adapter_async_call | n/a | asyncio variant of the previous test; BEAM concurrency model. |
| test_chat_adapter_with_pydantic_models | n/a | Nested pydantic input/output classes; assertions are on Python class names as annotations. |
| test_chat_adapter_signature_information | pass | System/user message structure assertions all hold. |
| test_chat_adapter_exception_raised_on_failure | pass (was FAIL) | Fixed by dee-coia: a marker-less completion is a loud parse error, matching DSPy's AdapterParseError. |
| test_chat_adapter_formats_image | pass | 3-chunk text/image/text content; Imp keeps the typed struct in adapter output, `Types.to_openai/1` yields the exact image_url block. |
| test_chat_adapter_formats_image_with_few_shot_examples | pass | 6 messages, completed markers in assistant turns, right image in each user turn. |
| test_chat_adapter_formats_image_with_nested_images | n/a | Images nested in pydantic wrapper models; no model-traversal surface in Imp. |
| test_chat_adapter_formats_image_with_few_shot_examples_with_nested_images | n/a | Same. |
| test_chat_adapter_with_tool | blocked | Requires `list[dspy.Tool]`/`dspy.ToolCalls` as typed signature fields (with `ToolCalls.description()` in the system message). Imp renders tools via the ReAct runtime, not signature field types. |
| test_chat_adapter_with_code | blocked | Requires `dspy.Code` as a field type (description in system message; parse to a Code value). Imp's Code struct is a content value only. |
| test_code_output_field_omits_json_schema_in_prompt | blocked | Same missing Code field-type surface. |
| test_citations_output_field_keeps_json_schema_in_prompt | blocked | DSPy `Citations` custom type not modeled (see test_citation.py). |
| test_chat_adapter_formats_conversation_history | pass | Exact-string message contents for both history turns. |
| test_chat_adapter_fallback_to_json_adapter_on_exception | pass (was FAIL) | Fixed by dee-coia + dee-16qm: strict chat parse fails, Imp.Predict's JSON fallback fires a second LM call, and JSONRepair decodes the single-quoted object. |
| test_chat_adapter_respects_use_json_adapter_fallback_flag | pass (was FAIL) | Fixed by dee-coia: with `config: [json_fallback: false]`, "nonsense" is a loud parse error after exactly one LM call. |
| test_chat_adapter_fallback_to_json_adapter_on_exception_async | n/a | asyncio variant. |
| test_chat_adapter_toolcalls_native_function_calling | blocked | Native function-calling adapter option (`use_native_function_calling`) absent. |
| test_chat_adapter_toolcalls_vague_match | blocked | Parsing marker text into a ToolCalls output field requires the typed tool_calls field surface. |
| test_chat_adapter_native_reasoning | blocked | Native `reasoning_content` extraction / `_call_preprocess` signature rewriting absent from Imp adapters. |
| test_chat_adapter_parses_float_with_underscores | n/a | json-repair behavior on a pydantic model output (`123_456.789`). |
| test_format_system_message | pass | Full-string equality, incl. trailing-space, JSON-schema notes, 8-space objective indent. |
| test_null_content_raises_adapter_parse_error | pass | Imp rejects a nil generation at the LM boundary (`{:error, {:invalid_lm_result, nil}}`) — loud error, one seam earlier than DSPy's AdapterParseError. |
| test_empty_string_content_raises_adapter_parse_error | pass | Empty completion on a 2-output CoT is a loud parse error (after Imp's JSON-fallback retry also fails, same as DSPy). |
| test_tool_call_with_null_content_does_not_raise | blocked | `_call_postprocess` with native function calling; surface absent. |

## tests/adapters/test_citation.py (8)

DSPy's `Citations` is the Anthropic citations type (`cited_text`,
`document_index`, `start/end_char_index`, `char_location`).
`Imp.Adapter.Types.Citation` is a different, simpler `{text, source}` struct
— none of the upstream shape is expressible.

| Upstream test | Status | Note |
|---|---|---|
| test_citation_validate_input | blocked | Citation char-location shape not modeled. |
| test_citations_in_nested_type | blocked | Same (plus pydantic nesting). |
| test_citation_with_all_fields | blocked | Same. |
| test_citation_format | blocked | Same. |
| test_citations_format | blocked | Same. |
| test_citations_from_dict_list | blocked | Same. |
| test_citations_postprocessing | blocked | `native_response_types` postprocess hook absent. |
| test_citation_extraction_from_lm_response | n/a | litellm `provider_specific_fields` plumbing. |

## tests/adapters/test_code.py (4)

| Upstream test | Status | Note |
|---|---|---|
| test_code_validate_input | pass (partial) | Code payload carried; invalid (non-binary) code rejected at the provider boundary (`Types.to_openai/1`) rather than at construction. The `dspy.Code["python"]` parameterized-class form has no Imp analog. |
| test_code_in_nested_type | n/a | Pydantic wrapper model. |
| test_code_with_language | pass (partial) | Language rides the struct. `Code.description()` ("Programming language: java") has no Imp surface — that half blocked. |
| test_code_parses_from_dirty_code | blocked | DSPy strips markdown fences/prose at construction; Imp has no parsing constructor for Code (and no Code output-field type to trigger it). |

## tests/adapters/test_document.py (4)

DSPy `Document` renders an Anthropic document block (`source`, `media_type`,
`citations: {enabled: true}`). Imp's Document is a text+metadata wrapper that
renders as a text block.

| Upstream test | Status | Note |
|---|---|---|
| test_document_validate_input | pass (partial) | Text payload carried; non-binary text rejected at the provider boundary. |
| test_document_in_nested_type | n/a | Pydantic wrapper model. |
| test_document_with_all_fields | blocked | title/media_type/context fields not modeled. |
| test_document_format | blocked | Anthropic document block (`citations: {enabled: true}`) not modeled; Imp emits a text block. |

## tests/adapters/test_json_adapter.py (28)

| Upstream test | Status | Note |
|---|---|---|
| test_json_adapter_passes_structured_output_when_supported_by_model | blocked | Needs pydantic model + unannotated output fields; Imp's structured-schema path (`JSON.lm_opts/3` with `response_schema` capability) exists but cannot express this signature. |
| test_json_adapter_not_using_structured_outputs_when_not_supported_by_model | pass | Capability `none` → no response_format option, same contract as DSPy's unsupported-provider path. |
| test_json_adapter_falls_back_when_structured_outputs_fails | n/a | Runtime retry after a provider exception lives in DSPy's litellm call path; Imp resolves capability up front from the model registry (documented substitution in `Imp.Adapter.JSON`). |
| test_json_adapter_with_structured_outputs_does_not_mutate_original_signature | n/a | Python class-mutation regression; Imp signatures are immutable values. |
| test_json_adapter_sync_call | pass | Predict + JSON adapter + strict-JSON completion → answer "Paris". |
| test_json_adapter_async_call | n/a | asyncio variant. |
| test_json_adapter_on_pydantic_model | n/a | Pydantic User/Answer models; exact pydantic-schema prompt strings. |
| test_json_adapter_parse_raise_error_on_mismatch_fields | pass | Loud error confirmed. Since dee-16qm, Imp repairs the single-quoted JSON exactly as DSPy does and then reports the missing `answer` field (`{:missing_output_fields, [:answer]}` — Imp's error tuple in place of upstream's adapter_name/parsed_result exception attributes). |
| test_json_adapter_formats_image | pass | Same 3-chunk structure as chat. |
| test_json_adapter_formats_image_with_few_shot_examples | pass | 6 messages, images in the right user turns. |
| test_json_adapter_formats_image_with_nested_images | n/a | Pydantic wrapper traversal. |
| test_json_adapter_formats_with_nested_documents | n/a | Pydantic wrapper + Anthropic document blocks (see test_document.py). |
| test_json_adapter_formats_image_with_few_shot_examples_with_nested_images | n/a | Pydantic wrapper traversal. |
| test_json_adapter_with_tool | blocked | Typed tool fields + native `tools` request param surface absent. |
| test_json_adapter_with_code | blocked | Code field type absent. |
| test_json_adapter_formats_conversation_history | pass | Exact strings incl. pretty-JSON assistant turns. |
| test_json_adapter_on_pydantic_model_async | n/a | asyncio + pydantic. |
| test_json_adapter_fallback_to_json_mode_on_structured_output_failure | n/a | Same runtime-retry design substitution as above. |
| test_json_adapter_json_mode_no_structured_outputs | pass | `response_format_only` capability → `%{type: "json_object"}`; full call path parses. |
| test_json_adapter_json_mode_no_structured_outputs_async | n/a | asyncio variant. |
| test_json_adapter_fallback_to_json_mode_on_structured_output_failure_async | n/a | asyncio variant. |
| test_error_message_on_json_adapter_failure | pass | Provider errors propagate unchanged through Imp.call as `{:error, exception}`. |
| test_error_message_on_json_adapter_failure_async | n/a | asyncio variant. |
| test_json_adapter_toolcalls_native_function_calling | blocked | Native function calling absent. |
| test_json_adapter_toolcalls_no_native_function_calling | blocked | Typed tool fields absent (the json_object half is covered by json_mode test). |
| test_json_adapter_native_reasoning | blocked | Native reasoning postprocess absent. |
| test_json_adapter_with_responses_api | n/a | litellm Responses-API plumbing. |
| test_format_system_message | pass | Full-string equality incl. escaped JSON-schema notes inside the JSON structure template. |

## tests/adapters/test_reasoning.py (5)

| Upstream test | Status | Note |
|---|---|---|
| test_reasoning_basic_operations | n/a | Python str dunder protocol on the Reasoning type; Elixir has no operator overloading — Imp reasoning values are plain strings/structs. |
| test_reasoning_concatenation | n/a | Same. |
| test_reasoning_string_methods | n/a | Same. |
| test_reasoning_with_chain_of_thought | pass | `result.reasoning` is an ordinary string usable with String functions. |
| test_reasoning_error_message | n/a | Python AttributeError message shape. |

## tests/adapters/test_tool.py (28)

Imp tools are explicitly-schema'd unary functions; DSPy tools introspect
Python type hints, docstrings, and pydantic models. Introspection tests are
n/a wholesale.

| Upstream test | Status | Note |
|---|---|---|
| test_basic_initialization | pass | name/desc/args(schema)/func carried. |
| test_tool_from_function | n/a | Type-hint/docstring introspection. |
| test_tool_from_class | n/a | `__call__` introspection. |
| test_tool_from_function_with_pydantic | n/a | Pydantic arg schemas. |
| test_tool_from_function_with_pydantic_nesting | n/a | Pydantic `$defs` resolution. |
| test_tool_callable | pass | Call through `Imp.Tool.call/2` returns "hello 42". |
| test_tool_with_pydantic_callable | n/a | Pydantic model arg. |
| test_invalid_function_call | n/a | Arg-type validation from hints; Imp deliberately places schema checks in the agent/ReAct runtime, not `Tool.call/2`. |
| test_parameter_desc | n/a | arg_desc merge into introspected schema. |
| test_tool_with_default_args_without_type_hints | n/a | Introspection of defaults. |
| test_tool_call_parses_args | n/a | Pydantic coercion of dict→model at call time. |
| test_tool_call_parses_nested_list_of_pydantic_model | n/a | Same. |
| test_tool_call_kwarg | n/a | Python **kwargs convention; Imp tools take one map. |
| test_tool_str | n/a | Python `__str__` format. |
| test_async_tool_from_function | n/a | asyncio (BEAM processes are the Imp concurrency model). |
| test_async_tool_with_pydantic | n/a | asyncio + pydantic. |
| test_async_tool_with_complex_pydantic | n/a | Same. |
| test_async_tool_invalid_call | n/a | asyncio. |
| test_async_tool_with_kwargs | n/a | asyncio + kwargs. |
| test_async_concurrent_calls | n/a | asyncio.gather timing. |
| test_async_tool_call_in_sync_mode | n/a | asyncio/sync conversion flag. |
| test_tool_calls_format_basic | pass (was FAIL) | Fixed by dee-4fuy: `ToolCalls.format` emits the OpenAI wire shape (`type: "function"`, `function: {name, arguments}`). |
| test_tool_calls_format_from_dict_list | pass (was FAIL) | Fixed by dee-4fuy: same wire shape via `from_dict_list`. |
| test_toolcalls_vague_match | pass (partial) | Single dict → ToolCall, list → ToolCalls, invalid raises. The bare `{"tool_calls": [...]}` dict shape has no single validator on the type (it is handled in the chat adapter's history normalizer) — that case blocked. |
| test_tool_convert_input_schema_to_tool_args_no_input_params | blocked | No `convert_input_schema_to_tool_args` equivalent; Imp.MCP keeps schemas as maps. |
| test_tool_convert_input_schema_to_tool_args_lang_chain | blocked | Same. |
| test_tool_call_execute | blocked | No `ToolCall.execute` helper; execution lives in the ReAct/agent runtime. |
| test_tool_call_execute_with_local_functions | n/a | Python locals()/globals() frame walking. |

## tests/adapters/test_two_step_adapter.py (4)

| Upstream test | Status | Note |
|---|---|---|
| test_two_step_adapter_call | pass | Main persona prompt + `name: value` user turn, then extraction call over `text -> outputs`; answer coerces to 12.0 (== 12). Extraction LM configured via `two_step_extraction_lm` setting (DSPy: constructor arg). |
| test_two_step_adapter_async_call | n/a | asyncio variant. |
| test_two_step_adapter_parse | pass | Extraction JSON yields tags list + 0.87 confidence (chat extraction fails on the bare JSON, TwoStep's JSONAdapter retry parses it — DSPy's own fallback path). |
| test_two_step_adapter_parse_errors | pass (was FAIL) | Fixed by dee-coia: strict chat parse rejects the unusable text, the JSON retry also fails, and the loud `two_step_extraction_failed` error matches DSPy's ValueError. |

## tests/adapters/test_xml_adapter.py (12)

| Upstream test | Status | Note |
|---|---|---|
| test_xml_adapter_format_and_parse_basic | pass | `format_field_with_value` is internal in Imp; the identical rendering is asserted via the demo assistant turn (`<answer>\nParis\n</answer>`), plus the parse half verbatim. |
| test_xml_adapter_parse_multiple_fields | pass | |
| test_xml_adapter_parse_raises_on_missing_field | pass | `{:error, {:missing_output_fields, [:explanation]}}` (tuple, not exception — Imp's error contract). |
| test_xml_adapter_parse_casts_types | pass | int/bool cast from tag text. |
| test_xml_adapter_parse_raises_on_type_error | pass | `{:error, %Imp.AdapterParseError{}}` for `<number>not_a_number</number>`. |
| test_xml_adapter_format_and_parse_nested_model | n/a | Pydantic model output. |
| test_xml_adapter_format_and_parse_list_of_models | n/a | Pydantic list output. |
| test_xml_adapter_with_tool_like_output | n/a | Pydantic ToolCall models. |
| test_xml_adapter_formats_nested_images | n/a | Pydantic wrapper traversal. |
| test_xml_adapter_with_code | blocked | Code field type absent. |
| test_xml_adapter_full_prompt | blocked | Requires `context: str \| None` — an Optional/Union input annotation rendered as `UnionType[str, NoneType]`; Imp has no union type surface, so the byte-exact prompt cannot be reproduced. |
| test_format_system_message | pass | Full-string equality (XML structure blocks, no completed sentinel, JSON-schema notes). |

## tests/signatures/test_signature.py (44)

| Upstream test | Status | Note |
|---|---|---|
| test_field_types_and_custom_attributes | pass | Class declaration → Imp map form; untyped output defaults to str. |
| test_no_input_output | n/a | Metaclass TypeError for a bare annotation; Python class mechanics. |
| test_no_input_output2 | n/a | Same for a plain pydantic.Field. |
| test_all_fields_have_prefix | pass | Custom prefix kept; default output prefix "Output:". |
| test_signature_parsing | pass | |
| test_duplicate_input_output_field_names_raise | pass (was FAIL) | Fixed by dee-1nkd: `"value -> value"` raises a ParseError ("...distinct names..."), matching DSPy's ValueError. |
| test_with_signature | pass | `with_instructions` → struct update; immutability inherent to Elixir values. |
| test_with_updated_field | n/a | Immutable-class field-update plumbing; on plain structs this is ordinary map update, nothing to port. |
| test_empty_signature | pass | `Imp.signature("")` raises ParseError. |
| test_instructions_signature | pass | Upstream body identical to test_empty_signature. |
| test_signature_instructions | pass | (Imp has one construction form; both upstream spellings collapse to it.) |
| test_signature_instructions_none | pass | Default instructions string matches byte-for-byte. |
| test_signature_from_dict | pass | Dict-of-fields form; all default to str. |
| test_signature_equality | pass | Structural equality. |
| test_signature_inequality | pass | |
| test_equality_format | n/a | A `format=lambda` field attribute; no Imp counterpart. |
| test_signature_reverse | pass | `to_spec/1` round trip. |
| test_insert_field_at_various_positions | pass | Appends via `extend/3`, output-prepend via `prepend_output/2`, input-prepend via struct update (no dedicated API — noted). |
| test_order_preserved_with_mixed_annotations | pass | |
| test_infer_prefix | pass (was FAIL) | Fixed by dee-1nkd: `Field.new` ports DSPy's infer_prefix (camelCase/digit splitting, Title Case, acronyms preserved). |
| test_insantiating | n/a | Signature classes as instantiable value containers; Python class semantics. |
| test_insantiating2 | n/a | Same. |
| test_multiline_instructions | pass | Multiline instructions + no-input predict flow. |
| test_dump_and_load_state | blocked | DSPy's `dump_state` schema (`fields: [{prefix, description}]`) is not Imp's persistence format; Imp dump/load uses name/kind/type maps. If DSPy-artifact compatibility ever matters, this is the contract to port. |
| test_typed_signatures_basic_types | pass (was FAIL) | Fixed by dee-1nkd: the parser accepts the Python spellings `str` and `dict`; `int`/`float` already parsed. `list[...]` deliberately keeps its guided error pointing at `array[...]`. |
| test_typed_signatures_generics | blocked | `list[int]` is deliberately spelled `array[integer]` in Imp; `dict[str, float]` and `tuple[...]` generics do not exist. |
| test_typed_signatures_unions_and_optionals | blocked | No Optional/Union types. |
| test_typed_signatures_any | blocked | No Any type. |
| test_typed_signatures_nested | blocked | Union/tuple nesting. |
| test_typed_signatures_from_dict | blocked | (type, Field) tuples with dict/tuple generics. |
| test_typed_signatures_complex_combinations | blocked | Same. |
| test_make_signature_from_string | blocked | dict/Union in string specs. |
| test_signature_field_with_constraints | pass (was blocked) | Fixed by de-hzcv gap #4: `Imp.Adapter.FieldConstraints.description/1` renders the machine constraints into DSPy's `json_schema_extra["constraints"]` string (PYDANTIC_CONSTRAINT_MAP phrases; `ge`/`le` are Imp's `:min`/`:max`). |
| test_basic_custom_type | blocked | `custom_types=`/auto-resolution of user classes in string specs; no Imp custom-type system. |
| test_custom_type_from_different_module | n/a | Resolving `Path` from Python module scope. |
| test_pep604_union_type_inline | blocked | No union types. |
| test_pep604_union_type_inline_equivalence | blocked | Same. |
| test_pep604_union_type_inline_nested | blocked | Same. |
| test_pep604_union_type_class_nested | blocked | Same. |
| test_pep604_union_type_class_equivalence | blocked | Same. |
| test_pep604_union_type_insert | blocked | Same. |
| test_pep604_union_type_with_custom_types | blocked | Same + custom types. |
| test_signature_cloudpickle_roundtrip | pass | cloudpickle → `Signature.dump/load` (through JSON) preserving names + instructions. |
| test_predict_cloudpickle_roundtrip | n/a | Pickling program objects; Imp program persistence (Imp.Saving) has its own format and tests. |

## tests/signatures/test_custom_types.py (7)

All resolve user-defined pydantic classes from the Python caller's scope
(frame inspection, dot-notation, aliases). Imp has no user-defined field
types, so the entire file is n/a. Note: the file defines
`test_basic_custom_type_resolution` twice; the second shadows the first, so
pytest itself only runs 6 of the 7.

| Upstream test | Status | Note |
|---|---|---|
| test_basic_custom_type_resolution (first) | n/a | Shadowed by the later duplicate; pydantic class resolution. |
| test_type_alias_for_nested_types | n/a | Caller-scope alias resolution. |
| test_module_level_type_resolution | n/a | Module-scope class resolution. |
| test_recommended_patterns | n/a | Scope-resolution patterns. |
| test_expected_failure | n/a | Unresolvable class name raises; scope mechanics. |
| test_module_type_resolution | n/a | Resolution inside a dspy.Module. |
| test_basic_custom_type_resolution (second) | n/a | Pydantic class resolution. |

## tests/signatures/test_adapter_file.py (28)

Imp files (`Imp.Adapter.Types.File`) carry `path`/`url`/`data`/`mime_type`
and encode at the provider boundary (`Types.to_openai/1`). Not modeled:
`filename`, `file_id`, string-sniffing constructors, Python repr/str.

| Upstream test | Status | Note |
|---|---|---|
| test_file_from_local_path | pass (partial) | Path → `data:text/plain;base64,` file block. `filename` not modeled (blocked half). |
| test_file_from_path_method | pass (partial) | Upstream body identical to the previous test. |
| test_file_from_path_with_custom_filename | blocked | No filename field. |
| test_file_from_bytes | pass | Default mime `application/octet-stream`. |
| test_file_from_bytes_with_filename | blocked | No filename field. |
| test_file_from_file_id | blocked | No file_id field (provider file registry not modeled). |
| test_file_from_file_id_with_filename | blocked | Same. |
| test_file_from_dict_with_file_data | pass (partial) | Data-URI accepted and passed through; filename half blocked. |
| test_file_from_dict_with_file_id | blocked | No file_id. |
| test_file_format_with_file_data | pass (partial) | `{type: "file", file: %{file_data: ...}}`; the `filename` key assertion blocked. |
| test_file_format_with_file_id | blocked | No file_id. |
| test_file_repr_with_file_data | n/a | Python repr format. |
| test_file_repr_with_file_id | n/a | Same. |
| test_file_str | n/a | `<<CUSTOM-TYPE-...-IDENTIFIER>>` split markers are DSPy's serialization mechanism; Imp keeps structs in content lists instead. |
| test_encode_file_to_dict_from_path | pass | Same encoding surface as from_local_path. |
| test_encode_file_to_dict_from_bytes | pass | |
| test_invalid_file_string | n/a | String-sniffing constructor (URL vs path) not an Imp surface — fields are explicit. |
| test_invalid_dict | pass | Payload-less file rejected loudly — at the provider boundary rather than construction (seam noted). |
| test_file_in_signature | pass | One file part reaches the adapter messages; summary flows back. |
| test_file_list_in_signature | pass (adapted) | One part per list element (2). Upstream's second file is from_file_id — substituted with a data-backed file since file_id is blocked. |
| test_optional_file_field | pass | Explicit nil input is skipped; zero file parts. |
| test_save_load_file_signature | blocked | Depends on teleprompt.LabeledFewShot + predictor save/load — deferred to the teleprompt tranche. |
| test_file_frozen | n/a | Pydantic frozen-model mutation guard; Elixir structs are immutable by construction. |
| test_file_with_all_fields | blocked | file_id + filename not modeled. |
| test_file_path_not_found | pass | Loud ArgumentError ("could not read Imp file attachment ..."); upstream message is "File not found" (wording differs). |
| test_file_custom_mime_type | pass | |
| test_file_from_bytes_custom_mime | pass | |
| test_file_data_uri_in_format | pass | |

## tests/signatures/test_adapter_image.py (15)

| Upstream test | Status | Note |
|---|---|---|
| test_basic_image_operations | pass (partial) | 3 of 4 parameterized cases ported (dict outputs → `object`, str output). The bbox case needs `list[Tuple[int,int,int,int]]` — tuple types not modeled (blocked case). |
| test_image_input_formats | n/a | PIL images + live network downloads; the plain dspy.Image-no-download case is covered by basic_image_operations. |
| test_predictor_save_load | n/a | PIL + network + teleprompt. |
| test_save_load_complex_default_types | blocked | teleprompt.LabeledFewShot + save/load — deferred to teleprompt tranche. |
| test_save_load_complex_types | blocked | Same. |
| test_save_load_pydantic_model | n/a | Pydantic model containing images. |
| test_optional_image_field | pass | Explicit nil image skipped; zero image parts. |
| test_pdf_url_support | n/a | Live network download + data-URI sniffing constructor. |
| test_different_mime_types | n/a | Live network downloads. |
| test_mime_type_from_response_headers | n/a | Live network. |
| test_pdf_from_file | n/a | Network download + Image path-sniffing constructor (Imp's Image takes url/data only; files are Types.File). |
| test_image_repr | n/a | Python str/repr + custom-type split markers. |
| test_from_methods_warn | n/a | Python DeprecationWarning API. |
| test_invalid_string_format | n/a | String-sniffing constructor. |
| test_pil_image_with_download_parameter | n/a | PIL. |

## Suite-structure notes for the predict/ and teleprompt/ tranches

- **DummyLM** (`dspy/utils/dummies.py`) is the upstream fixture LM everywhere:
  it takes a list of output dicts and FORMATS them through the active adapter
  (chat markers or JSON) before returning, and records `lm.history` (kwargs
  incl. messages). The Imp equivalent used here is an arity-2 function LM that
  returns `{:ok, map_or_binary}` and sends the messages to the test process;
  for predict/ ports expect to need the history-recording half too.
- **litellm mocking**: most upstream call-path tests `mock.patch
  ("litellm.completion")` and assert on `call_kwargs["messages"]` /
  `response_format` / `tools`. The Imp seam for the same assertions is the
  fn-LM's `(messages, opts)` arguments.
- **conftest**: `tests/conftest.py` provides `clear_settings` (auto-resets
  dspy.settings between tests) and gates `reliability` tests; nothing else
  global. `tests/adapters` and `tests/signatures` have no local conftest.
- **Signature classes inline**: nearly every upstream test declares a
  class-form signature with pydantic annotations. The porting pattern that
  worked here: Imp map form with explicit `type:`/`desc:`/`constraints:`;
  string specs only where upstream used string specs (`str`/`dict` are
  accepted Python spellings since the dee-1nkd fix; `list[...]` still gets
  the guided `array[...]` error).
- **Async twins**: upstream duplicates many tests as `@pytest.mark.asyncio`
  with `acall`/`litellm.acompletion`. These are mechanical asyncio variants —
  counted n/a here; the same policy will cut predict/teleprompt scope roughly
  15-20%.
- **teleprompt dependency leaks into signatures/**: the save/load tests in
  test_adapter_file.py and test_adapter_image.py use
  `dspy.teleprompt.LabeledFewShot` — they are recorded blocked here and
  should be picked up by the teleprompt tranche.

---

# Tranche 2 — predict/

The DSPy authors' `tests/predict/` suite (dspy-3.2.1, 13 files, 198 test
functions including two commented-out artifacts) run against Imp. Every
upstream test function is accounted for below. Ported tests live in
`test/upstream_exam/predict_test.exs` (69 ExUnit tests; one upstream test —
`test_call_predict_with_chat_history` — is split into its two adapter
parameterizations). `mix test --only upstream_exam` runs both tranches.

Owner steer honored: API-boundary behavior first, internals least. Where Imp
carries a documented design substitution (Elixir sandbox for the Deno Python
interpreter; `{:error, reason}` tuples for exceptions; `:history` entries for
the trajectory dict; `majority/2` returning the winning value), the port
asserts the substituted surface at full strength and the seam is named in the
row.

## Totals (tranche 2)

| Metric | Count |
|---|---|
| Upstream test functions in scope | **198** (aggregation 6, best_of_n 3, chain_of_thought 4, code_act 5, knn 3, multi_chain_comparison 1, parallel 7, predict 66, program_of_thought 6, react 9, refine 3, retry 3, rlm 82) |
| Ported | **83** (82 ExUnit tests; several one-port-covers-two rows) |
| — pass | **83** |
| — FAIL (real divergence found by upstream's own test) | **0** |
| Blocked (behavior should/could exist in Imp; not expressible yet) | **12** |
| Not applicable (Python/pydantic/litellm/asyncio/Deno specific, or a documented Imp design substitution) | **103** |

### Gaps the classification surfaced (fix-wave candidates)

No ported assertion failed, but the blocked rows point at real, buildable
surface. Ranked by owner-steer relevance (API boundary first):

1. **FIXED (de-hzcv)** — `n=` multi-completion (test_multi_output,
   test_multi_output2): `config: [n: K]` flows to the LM, which returns one
   output per completion; `Imp.Prediction.completions` holds all K parsed
   predictions (first is primary). Low/unset temperature bumps to 0.7 as
   upstream does. The req_llm client refuses `n > 1` loudly (its canonical
   response drops non-first choices); LMs honoring the list contract
   (`Imp.LM.Static`, custom clients) support it.
2. **FIXED (de-hzcv)** — extra inputs now warn loudly
   (test_extra_fields_warning): `Imp.Predict.Predict.warn_extra_inputs/3`
   matches DSPy's logger.warning-and-proceed semantics.
3. **FIXED (de-hzcv)** — input type-mismatch warnings (the 16-test warning
   family): with the new `warn_on_type_mismatch` setting on (default true,
   as upstream), `Imp.Predict.Predict` soft-validates each provided input
   against its field's declared type/enum/array-items and logs a warning
   ("type mismatch for field '...': expected ...") while the call proceeds —
   DSPy's logger.warning semantics, at the same boundary as the extra-inputs
   warning. Two documented seams: nil values are skipped (upstream skips
   None), and plain `:string` fields without an enum constraint are skipped
   at the field level (Imp defaults untyped fields to :string, so an
   implicit string is indistinguishable from a declared one — the Imp analog
   of upstream's IS_TYPE_UNDEFINED skip; string element types nested in
   `array[...]` are checked strictly). 10 of the 16 rows flip to pass;
   dict/tuple/union generics and custom types stay honestly blocked per row.
4. **FIXED (de-hzcv)** — constraints render into prompts
   (test_field_constraints): `Imp.Adapter.FieldConstraints` renders the
   machine constraints into DSPy's human-readable string
   (dspy/signatures/field.py PYDANTIC_CONSTRAINT_MAP) and the chat, JSON,
   and XML adapters append the upstream `\nConstraints: ...` suffix to the
   field description line (dspy/adapters/utils.py
   get_field_description_string). `ge`/`le` are the pydantic spellings of
   Imp's inclusive `:min`/`:max`; `gt`/`lt`/`multiple_of` are now also
   validated by Imp.Schema so nothing renders unvalidated. Same fix closes
   tranche 1's test_signature_field_with_constraints.
5. **FIXED (de-hzcv)** — BestOfN takes `fail_count`
   (test_refine_module_custom_fail_count, best_of_n variant): the failure
   budget flows through `Imp.Predict.Search`'s `:fail_budget` stop rule; one
   more failure than the budget aborts the run with
   `{:error, {:best_of_n_fail_count_exceeded, reason}}` (defaults to `n`,
   matching upstream's `fail_count or N`).
6. **FIXED (de-hzcv)** — per-prediction usage ledger (test_lm_usage*):
   with the `:track_usage` setting on, `Imp.Predict.Predict.call` runs in an
   `Imp.Usage` tracker and `Imp.Prediction.get_lm_usage/1` returns the
   per-model merged usage, as upstream's `Prediction.get_lm_usage()` does.
7. **FIXED (de-hzcv)** — RLM rejects reserved tool names
   (test_tool_validation_reserved_names): `Imp.Predict.RLM.new/2` raises
   ArgumentError for a tool named after any interpreter builtin (llm_query,
   llm_query_batched, rlm_query, rlm_query_batched, recurse, load, print,
   submit, show_vars, SHOW_VARS), as upstream's `_RESERVED_TOOL_NAMES` does.
8. **FIXED (de-hzcv)** — input-field defaults
   (test_input_field_default_value): a field declared with `default:` fills
   the input when the caller omits it, before the extra/type/missing checks
   (upstream `_forward_preprocess` order). Fields without a default stay
   loudly required — the default machinery cannot mask a missing input.
9. **FIXED (de-hzcv)** — per-call LM kwargs pass-through
   (test_predicted_outputs_piped_from_predict_to_lm_call):
   `Imp.Predict.Predict.call/3` takes a per-call config keyword list merged
   over the program config for that invocation only (the program is not
   mutated); every entry — including a predicted-outputs `prediction`
   payload — reaches the LM request. Signature inputs never do.
10. **FIXED (de-hzcv)** — `Enum.sum/1` and `Enum.product/1` are allowlisted
    (noted while porting test_with_input_variables_e2e; the port now spells
    `Enum.sum(numbers)` directly). `Enum.reduce` stays out: the constrained
    interpreter has no anonymous functions, so a lambda-taking reduce is not
    expressible; sum/product are the function-free aggregations upstream's
    Python `sum()` maps to.
11. **FIXED (de-hzcv)** — datetime field type
    (test_datetime_inputs_and_outputs): `datetime` is a first-class field
    type (`"when: datetime"` in string specs, `type: :datetime` in maps).
    Inputs render as ISO 8601 text (upstream's JSON-serialized datetime
    form); outputs parse ISO 8601 back into `DateTime` (offset present) or
    `NaiveDateTime` (naive), with schema validation and a type-mismatch
    warning for non-datetime inputs. Datetimes nested inside pydantic models
    remain out of scope (no custom-model type system — tranche 1 seam).

### Tranche 1's 78-blocked bucket, re-scrutinized (ticket ask)

Reviewed against predict-level machinery: **none unlock**. The bucket is
dominated by BAMLAdapter (21), pydantic model/typed-field surfaces, Citations
(7), native function calling, and union/generic types — all still absent.
The teleprompt-deferred rows (test_save_load_file_signature,
test_save_load_complex_default_types/_types) still need
teleprompt.LabeledFewShot and stay with the teleprompt tranche.

## tests/predict/test_aggregation.py (6)

Imp's `majority/2` returns the winning value; DSPy returns a Prediction whose
first completion is the winner (no Completions container in Imp — documented
substitution; all ports assert the winning value).

| Upstream test | Status | Note |
|---|---|---|
| test_majority_with_prediction | pass | List of `%Imp.Prediction{}` + `field: :answer` → "2". |
| test_majority_with_completions | n/a | DSPy's `Completions` container type; the same voting path is covered by the list port. |
| test_majority_with_list | pass | Plain maps + `field: :answer` → "2". |
| test_majority_with_normalize | pass | normalize_text analog (trim+downcase) groups " 2" with "2". |
| test_majority_with_field | pass | `field: :other` → "1". |
| test_majority_with_no_majority | pass | Tie keeps the first completion ("2"). |

## tests/predict/test_best_of_n.py (3)

| Upstream test | Status | Note |
|---|---|---|
| test_refine_forward_success_first_attempt | pass | DummyModule port (test struct implementing `Imp.Module`); reward never hits threshold → module runs exactly N=3 times; tie-first keeps "Brussels". |
| test_refine_module_default_fail_count | pass | Always-raising module → loud `{:error, {:no_successful_predictions, _}}` (DSPy: ValueError). |
| test_refine_module_custom_fail_count | pass (was blocked) | Fixed by de-hzcv gap #5: `fail_count: 1` → the second failure aborts (`{:error, {:best_of_n_fail_count_exceeded, _}}`); module called exactly 2 times. |

## tests/predict/test_chain_of_thought.py (4)

| Upstream test | Status | Note |
|---|---|---|
| test_initialization_with_string_signature | pass | Output fields exactly `[:reasoning, :answer]`; call answers "2". |
| test_async_chain_of_thought | n/a | asyncio twin. |
| test_chain_of_thought_with_native_reasoning | pass | Ported with the mocked marker completion verbatim (including upstream's stray `[[ ## completion ## ]]` tail, which parses as an unknown section exactly as in DSPy); answer "Paris", reasoning the exact string. |
| test_chain_of_thought_with_manual_reasoning | n/a | The distinguishing surface is litellm's `Choices.reasoning` attribute; the content-side assertions are identical to the previous row's port. |

## tests/predict/test_knn.py (3)

DummyVectorizer ported as the same algorithm (char-bigram counts bucketed by a
polynomial hash, mean-centered, L2-normalized) with fixed coefficients —
Python's `random.seed(123)` stream is not reproducible on the BEAM; the
geometry the assertions rely on is preserved. The `np.ndarray` type assertion
half is n/a (lists of floats in Imp).

| Upstream test | Status | Note |
|---|---|---|
| test_knn_initialization | pass | k == 2; 3 trainset vectors. |
| test_knn_query | pass | "What is 3+3?" retrieves "What is 2+2?" first (answer "4"), 2 samples. |
| test_knn_query_specificity | pass | "capital of Germany" retrieves the France example ("Paris" among answers). |

## tests/predict/test_multi_chain_comparison.py (1)

| Upstream test | Status | Note |
|---|---|---|
| test_basic_example | pass | Three rationale/answer completions in, `final_pred.rationale == "my rationale"`, `answer == "blue"`. |

## tests/predict/test_parallel.py (7)

`Imp.Predict.Parallel.map/3` is one-program-many-inputs; DSPy's
`Parallel([(predictor, input), ...])` heterogeneous pair list has no Imp
surface. Batch semantics are ported; pair-list shapes are blocked.

| Upstream test | Status | Note |
|---|---|---|
| test_parallel_module | pass (adapted) | Five parallel calls over one program each consume one scripted response; all five outputs come back (order-free set assertion, as upstream). |
| test_batch_module | pass (adapted) | Second batch through an `input -> output, reasoning` program; each result's reasoning number matches its output number. |
| test_nested_parallel_module | blocked | Nested heterogeneous (program, input) pair lists not expressible in `Parallel.map`'s contract. |
| test_nested_batch_method | blocked | A module forward returning nested raw result lists violates `Imp.Module`'s Prediction-only return contract. |
| test_batch_with_failed_examples | pass (adapted) | One raising input → its own `{:error, reason}` slot carrying "test error"; other slots succeed (DSPy: None slot + failed_examples/exceptions lists). |
| test_parallel_timeout_and_straggler_limit_params | blocked | No `straggler_limit` (Python thread-pool machinery); `:timeout` exists but defaults to 30_000 ms, not DSPy's 120 s — parameter surface not mirrored. |
| test_batch_timeout_and_straggler_limit_params | pass (partial) | The timeout half: custom module batch with explicit `timeout:` returns [2, 4, 6] in order. straggler_limit half blocked as above. |

## tests/predict/test_predict.py (66)

| Upstream test | Status | Note |
|---|---|---|
| test_initialization_with_string_signature | pass | Default instructions byte-equal: "Given the fields `input1`, `input2`, produce the fields `output`." |
| test_reset_method | n/a | In-place mutable reset; Imp programs are immutable values. |
| test_lm_after_dump_and_load_state | n/a | litellm LM kwargs dump_state contract; Imp LMs are validated refs / portable ReqLLM clients. |
| test_call_method | pass | |
| test_instructions_after_dump_and_load_state | pass | `Imp.dump/1` → `Imp.load/1` preserves "original instructions". |
| test_demos_after_dump_and_load_state | pass | Demos survive dump → JSON round trip → load with content intact ("¿Qué tal?"). |
| test_typed_demos_after_dump_and_load_state | n/a | pydantic models inside demos. |
| test_typed_demos_after_dump_and_load_state (commented duplicate) | n/a | Commented out upstream (TypedPredictor removed). |
| test_signature_fields_after_dump_and_load_state | pass (adapted) | `Imp.save!/load!` file round trip; loaded signature dump equals the original and differs from a maliciously re-declared one. (Imp.load! returns the program; no merge-into-instance surface.) |
| test_lm_field_after_dump_and_load_state | n/a | pickle + litellm LM state. |
| test_load_ignores_serialized_endpoint_override_by_default | n/a | litellm endpoint-override security plumbing. Imp never serializes provider endpoints — non-portable LMs fail loudly at dump (portable-LM doctrine), so the attack surface does not exist. |
| test_load_allows_serialized_endpoint_override_with_opt_in | n/a | Same. |
| test_load_state_ignores_serialized_endpoint_override_by_default | n/a | Same. |
| test_load_state_allows_serialized_endpoint_override_with_opt_in | n/a | Same. |
| test_load_state_ignores_serialized_model_list_endpoint_override_by_default | n/a | Same. |
| test_load_prevents_serialized_endpoint_override_reaching_litellm | n/a | Same. |
| test_load_blocks_serialized_model_list_unless_opted_in | n/a | Same. |
| test_load_uses_env_api_key_without_honoring_serialized_endpoint_override | n/a | Same (env API keys are provider-client concerns; secret values are owner-only). |
| test_forward_method | pass | |
| test_forward_method2 | pass | |
| test_config_management | n/a | `update_config`/`get_config` mutators; Imp config is plain data on an immutable struct. |
| test_multi_output | pass (was blocked) | `n=` multi-completion landed (de-hzcv, gap #1): `config: [n: 2]`, completions filled, first primary. |
| test_multi_output2 | pass (was blocked) | Same surface; both output fields index per completion. |
| test_datetime_inputs_and_outputs | pass (adapted, was blocked) | Fixed by de-hzcv gap #11: `datetime` field type; input renders ISO 8601 into the prompt, "2024-11-27T14:00:00" output parses to `~N[2024-11-27 14:00:00]`. Adapted: upstream nests datetimes in pydantic models; Imp declares the datetime field directly (no custom-model type system — tranche 1 seam). |
| test_explicitly_valued_enum_inputs_and_outputs | pass (partial) | Enum-constrained output parses "in_progress". Imp enums are string constraints; no Python Enum member identity. |
| test_enum_inputs_and_outputs_with_shared_names_and_values | n/a | Python Enum name/value aliasing semantics. |
| test_auto_valued_enum_inputs_and_outputs | n/a | `enum.auto` value semantics. |
| test_named_predictors | pass (adapted) | `Imp.ProgramParameters.predictors/1` exposes the inner Predict of a composite. The deepcopy half is n/a (immutability inherent). |
| test_output_only | pass | `" -> output"` signature; empty-input call answers. |
| test_load_state_chaining | n/a | Return-self fluent API. |
| test_call_predict_with_chat_history | pass | Both parameterizations ported (chat markers; json with single-quoted json-repair response). 4 messages; history turns and final question land in the right turns. |
| test_lm_usage | pass (was blocked) | Usage ledger landed (de-hzcv, gap #6): `:track_usage` + `Imp.Prediction.get_lm_usage/1`. |
| test_lm_usage_with_parallel | pass (was blocked) | Parallel runs are separate BEAM processes, so each prediction carries only its own usage — the isolation upstream's race-condition fix pins. |
| test_lm_usage_with_async | n/a | asyncio twin. |
| test_positional_arguments | pass (adapted) | Bare-value call → loud `{:error, {:invalid_predict_inputs, _}}` (DSPy: ValueError with keyword-argument guidance; message shape differs). |
| test_error_message_on_invalid_lm_setup | pass (partial) | No LM → `{:error, :lm_not_configured}`. A bogus LM value raises at construction (Imp validates in `new/2`; DSPy at call time). The BaseLM-instance message half has no Imp counterpart. |
| test_field_constraints | pass (was blocked) | Fixed by de-hzcv gap #4: field descriptions carry the upstream `\nConstraints: ...` suffix in chat, JSON, and XML system messages. Both adapter halves ported. |
| test_async_predict | n/a | asyncio twin. |
| test_predicted_outputs_piped_from_predict_to_lm_call | pass (was blocked) | Per-call config landed (de-hzcv, gap #9): `call/3` config reaches the LM request; a signature input named `prediction` does not. Imp's channel is the explicit `call/3` config (upstream shape-sniffs the kwarg). |
| test_dump_state_pydantic_non_primitive_types | n/a | pydantic `serialize_object`. |
| test_trace_size_limit | n/a | Design substitution: no global mutable `settings.trace`; Imp uses optimizer trace capture + telemetry. |
| test_disable_trace | n/a | Same. |
| test_per_module_history_size_limit | n/a | No mutable per-module history on immutable programs; observability owns history. |
| test_per_module_history_disabled | n/a | Same. |
| test_input_field_default_value | pass (was blocked) | Fixed by de-hzcv gap #8: `default:` on an input field fills the omitted input before the checks; the default value reaches the rendered prompt. The port also pins that a field WITHOUT a default stays a loud `{:error, {:missing_input_fields, _}}`. |
| test_extra_fields_warning | pass (was blocked) | Fixed by de-hzcv gap #2: `Imp.Predict.Predict.warn_extra_inputs/3` logs a per-call warning ("not in signature", offending keys, expected keys) and the call proceeds — DSPy's exact semantics (logger.warning, extras ignored). ReActV2 warns at its own entry (it filters inputs before Predict); PoT/CodeAct loop-state carrier keys and RAG-consumed query fields are documented exemptions. |
| test_warning_images | blocked | Warning subsystem now exists (gap #3), but there is no Image SIGNATURE field type to declare a mismatch against (Image is an adapter content type), and the string-sniffing `dspy.Image(...)` constructor is n/a. |
| test_type_mismatch_warning | pass (was blocked) | Fixed by de-hzcv gap #3: string on an `:integer` field logs "type mismatch for field 'count': expected integer" and the call proceeds. |
| test_correct_types_no_warning | pass (was n/a) | Meaningful now the warning subsystem exists: correct types produce no extra-field and no type-mismatch warnings. |
| test_list_type_validation | pass (adapted, was blocked) | Non-list on `array[str]` warns "expected array[string]"; a list of strings does not. Adapted: Imp spells `list[str]` as `array[str]`; one port covers this and the string-signature row below. |
| test_literal_type_validation | pass (adapted, was blocked) | Out-of-set value on an enum-constrained field warns "expected enum[pending, approved, rejected]". Adapted: `Literal[...]` is Imp `enum[...]`; enum values are strings, so integer literals match through their string spelling. One port covers this and the string-signature row below. |
| test_literal_union_type_validation | pass (adapted, was blocked) | `Literal[...] \| None` maps to enum constraint + optional: literals pass, nil is skipped by the check (upstream skips None), out-of-set values warn. No general union types. |
| test_list_string | pass (was blocked) | Covered by the nested-list port: `[1, 2, 3, nil]` on `array[str]` warns "expected array[string]"; a list of strings does not. (The str-annotated-field-with-list half is the documented `:string` field-level skip.) |
| test_nested_list_type_validation | pass (was blocked) | Element types inside `array[int]`/`array[str]` are checked recursively; empty lists are valid. |
| test_nested_dict_type_validation | blocked | Warning subsystem landed, but `:object` has no key/value generics — `dict[str, int]` element mismatches are not expressible. |
| test_nested_tuple_type_validation | blocked | No tuple types. |
| test_literal_type_validation_string_signature | pass (adapted, was blocked) | Same port as test_literal_type_validation (Imp's string spec spells `Literal[...]` as `enum[...]`). |
| test_list_type_validation_string_signature | pass (adapted, was blocked) | Same port as test_list_type_validation/test_nested_list_type_validation (`list[...]` spelled `array[...]`). |
| test_dict_type_validation_string_signature | blocked | No dict[k,v] generics (same as test_nested_dict_type_validation). |
| test_tuple_type_validation_string_signature | blocked | No tuple types. |
| test_union_type_validation_string_signature | blocked | No union syntax in string specs; the nil-acceptance half is covered by the literal-union port (class form). |
| test_basic_types_string_signature | pass (was blocked) | Fixed by de-hzcv gap #3: the `warn_on_type_mismatch` setting (default true) gates the check; off → silent, on → "expected integer" warning. Both parametrizations ported in one test. |
| test_untyped_string_signature | n/a | True by design: untyped fields default to `:string`, and plain `:string` fields are skipped by the check (the documented implicit-string seam). |
| test_untyped_class_signature | n/a | Same. |
| test_string_to_list_signature | n/a | Same seam (upstream's str-accepts-list-of-str special case is subsumed by the `:string` field-level skip). |
| test_custom_signature_types | blocked | Custom pydantic types in string specs — tranche 1 seam (no custom-type system). |

## tests/predict/test_program_of_thought.py (6)

Design substitution throughout: Imp PoT generates a safe **Elixir** expression
executed in `Imp.Sandbox` (no Deno/Python, no `interpreter.deno_process`
assertions), and projects the value directly instead of a second extraction LM
call when it satisfies the declared outputs.

| Upstream test | Status | Note |
|---|---|---|
| test_pot_code_generation | pass (adapted) | Planner emits `1+1`; sandbox executes; answer 2 (direct projection; upstream's "2" is its scripted extraction LM's string). |
| test_old_style_pot | n/a | Legacy Python markdown-fence/no-SUBMIT format compatibility for old finetuned models. |
| test_pot_support_multiple_fields | pass (adapted) | Program yields both outputs (`%{maximum: "6", minimum: "2"}`); both asserted. |
| test_pot_code_generation_with_one_error | pass | First program fails at runtime (unknown variable), regeneration succeeds; answer 2. |
| test_pot_code_generation_persistent_errors | pass | Always-failing program exhausts `max_iters: 3` → loud `{:error, _}` (DSPy: RuntimeError "Max hops reached"). |
| test_pot_code_parse_error | pass (partial) | Unparsable program exhausts max_iters loudly. The `_execute_code`-never-called half is Python mock internals. |

## tests/predict/test_code_act.py (5)

Design substitution: Imp CodeAct plans discrete steps — a tool call OR a safe
Elixir program over the accumulated `observation` — rather than generating
Python that calls tools inline. Trajectory-dict byte assertions map to the
step/trace surface.

| Upstream test | Status | Note |
|---|---|---|
| test_codeact_code_generation | pass (adapted) | Tool step (`add` → 2), then finished program over `observation`, extraction answers "2". |
| test_codeact_support_multiple_fields | pass (adapted) | Tool returns max/min map; extraction produces both outputs. |
| test_codeact_code_parse_failure | pass | Unparsable program is a recoverable observation; the next generation succeeds. |
| test_codeact_code_execution_failure | pass | Unknown-variable failure is recoverable; next generation succeeds. |
| test_codeact_tool_validation | pass (adapted) | Invalid tool entries raise ArgumentError at construction (DSPy: ValueError for callable objects — Imp has no function/callable-object distinction; anything not an `Imp.Tool` is rejected). |

## tests/predict/test_react.py (9)

Ports run ReAct in `:dspy_3_2_1` mode (the faithful reproduction of
dspy/predict/react.py). DSPy's `result.trajectory` dict maps to Imp's
`:history` entries (`%{thought, tool, arguments, result}` per tool call).

| Upstream test | Status | Note |
|---|---|---|
| test_tool_observation_preserves_custom_type | n/a | PIL images + ChatAdapter subclass spying. |
| test_tool_calling_with_pydantic_args | blocked | pydantic-model tool args / typed input fields; the trajectory flow itself is covered by the without_typehint port. |
| test_react_with_tools_skips_native_response_issubclass_for_generic_alias | n/a | Python `issubclass` monkeypatch regression. |
| test_tool_calling_without_typehint | pass | One tool call then finish then extraction; c == 3; history records thought/tool/args, observation 3, and "Completed." for finish — the trajectory contract at full strength. |
| test_trajectory_truncation | n/a | Requires swapping the inner react predictor attribute at runtime (Python mock); Imp's truncation ladder is regression-tested in-repo (`faithful_trajectory_call`). |
| test_context_window_exceeded_after_retries | n/a | Same inner-attribute mocking (+ asyncio half). |
| test_error_retry | pass | Always-raising tool; invocation-local `max_iters: 2`; extraction still answers c == 3; both history entries carry the exact thought/tool/args and an observation containing "tool error". |
| test_async_tool_calling_with_pydantic_args | n/a | asyncio twin. |
| test_async_error_retry | n/a | asyncio twin. |

## tests/predict/test_refine.py (3)

| Upstream test | Status | Note |
|---|---|---|
| test_refine_forward_success_first_attempt | pass | DummyModule port; reward below threshold on all attempts → module runs exactly 3 times; best answer "Brussels"; reward called. |
| test_refine_module_default_fail_count | pass | Always-raising module → loud error. |
| test_refine_module_custom_fail_count | pass | `fail_count: 1`: the second failure aborts (`{:error, {:refine_fail_count_exceeded, _}}`); module called exactly 2 times. |

## tests/predict/test_retry.py (3)

The entire file is commented out at the 3.2.1 pin (dspy.Retry / assertions
retired upstream).

| Upstream test | Status | Note |
|---|---|---|
| test_retry_simple | n/a | Commented out upstream. |
| test_retry_forward_with_feedback | n/a | Commented out upstream. |
| test_retry_forward_with_typed_predictor | n/a | Commented out upstream (doubly: nested comment block). |

## tests/predict/test_rlm.py (82)

Design substitution: Imp RLM's controller writes constrained **Elixir**
(`submit/1`, `print/1`, `llm_query/1`, registered tools) interpreted by an
AST-allowlist interpreter — no Deno/Pyodide, no markdown fences, no Python
REPL type classes. Upstream's MockInterpreter/PythonInterpreter/REPLTypes
strata test its own fixtures and interpreter; the RLM *behavior* stratum is
ported.

| Upstream test | Status | Note |
|---|---|---|
| TestMockInterpreter::test_scripted_responses | n/a | Tests upstream's own mock fixture, not the library. |
| TestMockInterpreter::test_returns_final_output_result | n/a | Same. |
| TestMockInterpreter::test_raises_exception_from_responses | n/a | Same. |
| TestMockInterpreter::test_records_call_history | n/a | Same. |
| test_basic_initialization | pass | max_iterations 5; tools empty; signature input/output fields present. |
| test_custom_signature | pass | |
| test_custom_tools | pass | One user tool registered; internal llm_query tools not counted. |
| test_tool_validation_invalid_identifier | n/a | Python-identifier validity for names injected into a Python sandbox; Imp tool names are atoms, not injected identifiers. |
| test_tool_validation_reserved_names | pass (was blocked) | Fixed by de-hzcv gap #7: tools named after interpreter builtins (llm_query/submit/print and the rest of the reserved set) raise ArgumentError at construction. |
| test_tool_validation_not_callable | pass | Non-tool entries ("not a function", 123) raise ArgumentError at construction. |
| test_tools_dict_rejected | n/a | dict-vs-list tools API affordance; Imp's contract is a list of Imp.Tool structs (anything else is rejected by the same boundary as the previous row). |
| test_optional_parameters | pass (partial) | Defaults: max_llm_calls 50, sub_lm nil. The `interpreter=` injection half is n/a (no pluggable interpreter object). |
| test_forward_validates_required_inputs | pass | Missing `query` → `{:error, {:missing_input_fields, [:query]}}` (single-missing case; the multi-missing report rides the same surface). |
| test_batched_query_errors_have_clear_markers | blocked | `_make_llm_tools` internal surface; Imp's llm_query error path is interpreter-level (own suite) with no [ERROR]-marker contract to assert. |
| test_tools_call_counter_is_thread_safe | n/a | Python threading/ThreadPoolExecutor; BEAM processes + budget ledger design. |
| test_strip_code_fences | n/a | Markdown-fence stripping is upstream's controller output format; Imp's controller contract is fence-less JSON reasoning/code. |
| test_strip_code_fences_rejects_non_python_lang | n/a | Same. |
| TestRLMFormatting::test_format_history | n/a | REPLHistory prompt-formatting internals; Imp has its own trace/compaction machinery. |
| TestRLMFormatting::test_format_history_empty | n/a | Same. |
| TestRLMFormatting::test_action_signature_has_iteration_field | n/a | Internal controller-signature layout is Imp's own design. |
| TestRLMFormatting::test_format_output | n/a | Formatting internals. |
| TestRLMFormatting::test_format_output_empty | n/a | Same. |
| TestRLMFormatting::test_format_output_passthrough | n/a | Same. |
| TestRLMFormatting::test_format_variable_info_string | n/a | REPLVariable preview internals (Imp: max_preview_chars machinery, own tests). |
| TestRLMFormatting::test_format_variable_info_dict | n/a | Same. |
| TestRLMFormatting::test_build_variables_multiple | n/a | Same. |
| TestREPLTypes (11 tests) | n/a | Python REPL type classes (REPLHistory/REPLEntry/REPLVariable) — upstream's own data structures, not an Imp surface. Rows collapsed; all 11 carry this one reason. |
| TestRLMCallMethod::test_call_is_alias_for_forward | n/a | `__call__`/forward alias; Imp has a single call surface. |
| test_max_iterations_triggers_extract | pass | Three non-submitting turns exhaust max_iterations 3; the extraction fallback answers "extracted_answer". |
| test_tool_exception_returns_error_in_output | pass | Raising registered tool → recorded error; controller recovers and submits "recovered". |
| test_runtime_error_history_uses_stripped_code | n/a | Fence-stripping bookkeeping (fence-less controller contract). |
| test_syntax_error_from_execute_is_recoverable | pass | Unparsable code is an iteration error; controller recovers and submits. |
| test_syntax_error_from_strip_code_fences_is_recoverable | n/a | Fence stripping. |
| TestRLMDynamicSignature::test_action_signature_structure | n/a | Internal controller-signature layout (Imp's instructions enumerate llm_query/submit in its own JSON contract). |
| TestRLMDynamicSignature::test_extract_signature_structure | n/a | Same. |
| TestPythonInterpreter (13 tests) | n/a | Deno/Pyodide interpreter integration (start/idempotence/injection/tools/state/errors). Imp's sandbox and interpreter have their own in-repo suites (rlm_interpreter_test.exs etc.). Rows collapsed; all 13 carry this one reason. |
| TestSandboxSecurity::test_no_network_access | n/a | Deno permission flags; Imp's interpreter executes an AST allowlist — there is no network capability to deny. |
| TestSandboxSecurity::test_imports_work | n/a | Python stdlib imports. |
| TestRLMAsyncMock (3 tests) | n/a | asyncio twins of ported behavior. |
| TestRLMTypeCoercionMock::test_type_coercion | pass (partial) | int/float/bool/array[integer] submissions come back as declared types. The `Literal['yes','no']` case rides the next row's enum port. |
| TestRLMTypeCoercionMock::test_type_error_retries | pass | Invalid enum submission rejected; controller retries and the valid value lands. |
| TestRLMTypeCoercion (deno) ::test_type_coercion | n/a | Deno variant of the ported mock coercion (the dict[str,str] case also lacks generics). |
| TestRLMTypeCoercion (deno) ::test_submit_extracts_typed_value | n/a | Deno variant. |
| test_multi_output_final_kwargs | pass | Imp submit/1 takes one map of all output fields; both outputs typed and present. |
| test_multi_output_final_positional | n/a | Python positional-args convention; collapses to the map form ported above. |
| test_multi_output_three_fields | n/a | Same kwargs convention; covered by the map-form port. |
| test_multi_output_final_missing_field_errors | pass | Submit missing `count` is an error; retry with both fields succeeds. |
| test_multi_output_submit_vars | n/a | Positional variable-passing convention; map form covers it. |
| test_multi_output_type_coercion | n/a | Kwargs convention; coercion itself ported in TestRLMTypeCoercionMock row. |
| test_simple_computation_e2e | pass | Controller computes and submits; typed int 5 returns. |
| test_multi_turn_computation_e2e | pass | Interpreter state (`x = 10`) persists to the next turn; answer 20. |
| test_with_input_variables_e2e | pass | Inputs are live interpreter variables; the sum is spelled `Enum.sum(numbers)` (gap #10 fixed by de-hzcv: sum/product allowlisted). |
| test_with_tool_e2e | pass | Registered host-side tool callable from generated code; "apple" → "red". |
| test_aforward_simple_computation_e2e | n/a | asyncio twin. |
| test_aforward_multi_turn_e2e | n/a | asyncio twin. |
| test_aforward_with_input_variables_e2e | n/a | asyncio twin. |
| TestRLMIntegration::test_simple_computation | n/a | Skipped upstream ("Requires actual LM and Deno"). |
| TestRLMIntegration::test_with_llm_query | n/a | Same. |

---

# Tranche 3 — teleprompt/, evaluate/, streaming/

The DSPy authors' `tests/teleprompt/` (14 files, 65 test functions),
`tests/evaluate/` (3 files, 21), and `tests/streaming/` (1 file, 37) suites
run against Imp. Every upstream test function is accounted for below. Ported
tests live in `test/upstream_exam/teleprompt_test.exs`,
`test/upstream_exam/evaluate_test.exs`, and
`test/upstream_exam/streaming_test.exs`. `mix test --only upstream_exam` runs
all three tranches.

This tranche examines the least-reviewed code in the repo (the optimizer
internals). Design substitutions that recur in the rows:

- **Report, not attributes**: DSPy attaches mutable attributes to the
  compiled program (`_compiled`, `total_calls`, `results_best`,
  `candidate_programs`, `flag_compilation_error_occurred`); Imp attaches an
  `Imp.Optimizer.Report` (fetched via `Report.fetch/1`) carrying the same
  facts as data.
- **Scores are fractions**: Imp.Evaluate scores are 0..1; DSPy's are 0..100.
- **Enumerable streaming**: DSPy streams via asyncio generators wrapped by
  `streamify`; Imp streams via Enumerables and
  `Imp.Streaming.Messages.StreamListener.attach/2`. Ports feed the listener
  the SAME provider chunk sequences upstream's mocked litellm streams yield.

## Totals (tranche 3)

| Metric | Count |
|---|---|
| Upstream test functions in scope | **123** (teleprompt 65, evaluate 21, streaming 37) |
| Ported | **69** (68 ExUnit tests; some ports cover two same-surface upstream fns, some upstream fns split across two ports) |
| — pass | **68** |
| — FAIL (real divergence found by upstream's own test) | **1** (chat stream listener trailing-whitespace trim; tagged `@tag :upstream_fail` + `:skip`, failing output preserved in the test comment) |
| Blocked (behavior should/could exist in Imp; not expressible yet) | **26** (11 flipped by the dee-r67q GEPA selector/proposer batch: 9 to pass, 2 to n/a) |
| Not applicable (Python/pydantic/litellm/asyncio specific, or a documented Imp design substitution) | **28** |

### The FAIL

**Chat stream listener does not trim trailing section whitespace when the end
marker arrives split across chunks** (streaming_test.exs, tagged). With
upstream's recorded gpt-4o-mini token split (`"!\n\n[[ ##"`, `" completed"`,
`" ##"`, `" ]]"`), DSPy's listener yields `"!"` as the final content chunk
(trailing `\n\n` trimmed, `is_last_chunk` on it). Imp's chat parser emits the
untrimmed `"!\n\n"` — the whitespace precedes a then-unconfirmed marker
prefix and is flushed as content — then marks doneness on a separate
nil-content terminal chunk. Concatenated listener output therefore differs
from upstream by the trailing whitespace. When the full end marker arrives in
ONE chunk, Imp does drop the preceding whitespace, so the divergence is
specific to split markers. JSON and XML extraction are content-exact
(JSON byte-exact including chunk boundaries and the done flag).

### Gaps and notable findings (fix-wave candidates)

1. **Chat listener trailing-whitespace FAIL** above — the one place
   upstream's own test catches Imp emitting different bytes.
2. **BetterTogether accepts a non-optimizer at construction**
   (test_bettertogether_initialization_invalid_optimizer): DSPy raises
   TypeError at `__init__`; Imp accepts `%{p: "not_a_teleprompter"}` silently
   and only surfaces `{:not_an_optimizer, _}` when the strategy step runs.
   The error is loud at compile, so no silent failure — but construction-time
   validation is absent (the ported test asserts Imp's boundary; seam in the
   row).
3. **Terminal chunk carries `chunk: nil`, not `""`** (streaming): upstream's
   "empty last chunk" is an empty string; Imp's is nil. Cosmetic but it
   forces `chunk || ""` on every consumer that joins chunks.
4. **No list-of-acceptable-answers exact-match helper**
   (test_answer_exact_match_list): upstream's `answer_exact_match` accepts
   `str | list`; `Imp.Metrics.exact_match/1` compares one value. The port
   spells the list semantics inline per Imp's metrics-are-functions doctrine;
   a built-in would close the gap.
5. **Bootstrap max_errors raises a budget error, not the underlying
   exception** (test_error_handling_during_bootstrap): DSPy re-raises
   "Simulated error"; Imp raises "bootstrap error budget exhausted: 1 errors
   (maximum 1)". Loud either way; the original error is in the message chain
   but not re-raised.
6. **No per-tool/module status-message provider** (5 streaming status tests):
   DSPy's `StatusMessageProvider` hooks lm/tool/module start+end and streams
   "Calling tool ..." messages; Imp's StatusMessage vocabulary covers
   listener lifecycle only (:started/:completed/:error/:cancelled).
7. **No GEPA component_selector / instruction_proposer surfaces** — LANDED
   (dee-r67q): `Imp.Optimizer.GEPA.new/2` now takes `:module_selector`
   (upstream `component_selector`: `:round_robin` default, `:all`, an
   arity-five custom function, or a ModuleSelector module/struct) and the
   already-public `:reflection_strategy` is the `instruction_proposer`
   equivalent (arity-three candidate/dataset/components function returning a
   proposal map; works with `reflection_lm: nil`). Custom selector returns
   are validated loudly (non-empty, known components, no duplicates).
   Multimodal (dspy.Image) reflection remains out of scope — no image
   example type in Imp.
8. **No public minibatch-eval / n-fewshot-candidates utility surface**
   (test_utils.py): `eval_candidate_program` and
   `create_n_fewshot_demo_sets` equivalents are internal
   (`Imp.Optimizer.DemoCandidates`, MIPROv2 internals). Upstream's
   metric_threshold regression (#9308) does not apply: DemoCandidates applies
   the threshold uniformly to every round, seed schedule included.

## tests/teleprompt/test_teleprompt.py (1)

| Upstream test | Status | Note |
|---|---|---|
| test_get_params | n/a | `Teleprompter.get_params` reads `self.__dict__`; Imp optimizers are structs whose params are plain visible fields — nothing to port. |

## tests/teleprompt/test_bootstrap.py (5)

| Upstream test | Status | Note |
|---|---|---|
| test_bootstrap_initialization | pass | metric + demo caps stored on the struct. |
| test_compile_with_predict_instances | pass (adapted) | Compiled program returned; `_compiled` flag substituted by the attached optimizer Report. |
| test_bootstrap_effectiveness | pass (adapted) | Exactly one bootstrapped demo with the trainset's input/output; the follow-examples half is scripted (the fn-LM echoes the demo found in its own prompt, so a missing demo fails loudly) since Imp has no DummyLM(follow_examples). |
| test_error_handling_during_bootstrap | pass (adapted) | Raising teacher + `max_errors: 1` → loud RuntimeError "bootstrap error budget exhausted" (DSPy re-raises the underlying error; seam noted, gap #5). |
| test_validation_set_usage | pass | `length(compiled.demos) >= 1`. |

## tests/teleprompt/test_random_search.py (1)

| Upstream test | Status | Note |
|---|---|---|
| test_basic_workflow | pass | RandomSearch compile over the 2-example trainset with a teacher completes and returns a program. |

## tests/teleprompt/test_copro_optimizer.py (5)

| Upstream test | Status | Note |
|---|---|---|
| test_signature_optimizer_initialization | pass | metric/breadth/depth/init_temperature stored. |
| test_signature_optimizer_optimization_process | pass | `optimized != student` after compile with a scripted proposer LM (Imp: `proposer_lm` option; DSPy: global settings LM). |
| test_signature_optimizer_statistics_tracking | pass (adapted) | `track_stats: true` → total_calls/results_best/results_latest on the Report (DSPy: attributes on the program). One port covers this and the row below. |
| test_optimization_and_output_verification | pass | Optimized student answers "Paris". |
| test_statistics_tracking_during_optimization | pass (adapted) | Same surface as statistics_tracking; `total_calls > 0`, results populated. |

## tests/teleprompt/test_ensemble.py (4)

| Upstream test | Status | Note |
|---|---|---|
| test_ensemble_without_reduction | pass | 5 programs → prediction with 5 outputs (Imp wraps the list in a Prediction; DSPy returns the bare list). |
| test_ensemble_with_reduction | pass | reduce_fn over the 5 predictions → mean 2.0. |
| test_ensemble_with_size_limitation | pass | size: 3 → 3 outputs. |
| test_ensemble_deterministic_behavior | n/a | Upstream asserts its own `NotImplemented`/TODO stub raises; Imp implements deterministic selection (`deterministic: true` + seed), so the stub-assertion has nothing to port. |

## tests/teleprompt/test_knn_fewshot.py (2)

| Upstream test | Status | Note |
|---|---|---|
| test_knn_few_shot_initialization | pass | `knn.k == 2`, 3 trainset examples (stub vectorizer; geometry not exercised here). |
| _test_knn_few_shot_compile | n/a | Disabled upstream ("Test not working yet" — leading underscore, pytest never runs it). Imp's per-call KNN compile semantics are covered in-repo (knn_few_shot_test.exs). |

## tests/teleprompt/test_utils.py (4)

| Upstream test | Status | Note |
|---|---|---|
| test_eval_candidate_program_full_trainset | blocked | No public `eval_candidate_program`; minibatch-vs-full evaluation lives inside MIPROv2/optimizer internals with no callback_metadata surface. |
| test_eval_candidate_program_minibatch | blocked | Same. |
| test_eval_candidate_program_failure | blocked | Same (the failure→score-0 contract is internal). |
| test_create_n_fewshot_demo_sets_passes_metric_threshold_for_unshuffled | n/a | Regression for upstream #9308 (threshold dropped on the seed=-1 arm). Imp's `Imp.Optimizer.DemoCandidates.build/4` applies `:metric_threshold` uniformly to every round by construction; the buggy code shape does not exist. |

## tests/teleprompt/test_bootstrap_finetune.py (3)

| Upstream test | Status | Note |
|---|---|---|
| test_bootstrap_finetune_initialization | pass | metric stored; `multitask` defaults true. |
| test_compile_with_predict_instances | blocked | Requires mocking `finetune_lms` and a `_compiled` flag; Imp's training boundary is a Trainer provider returning `Imp.Clients.TrainingJob` — no in-process mock seam equivalent to `patch.object(bootstrap, "finetune_lms")`. Provider-training semantics are covered in-repo (bootstrap_finetune_test.exs, provider_training_lifecycle_test.exs). |
| test_error_handling_missing_lm | pass (adapted) | Compile without a configured trainer/LM is a loud error, never a silent no-op (DSPy: ValueError "does not have an LM assigned"). |

## tests/teleprompt/test_bootstrap_trace.py (2)

| Upstream test | Status | Note |
|---|---|---|
| test_bootstrap_trace_data | blocked | `bootstrap_trace_data`'s row shape (`example/prediction/trace/example_ind/score` + FailedPrediction with format_reward) has no public Imp equivalent; trajectory capture is internal (`Imp.Optimizer.TrajectoryRunner`) with its own contract tests. If GRPO-style failed-parse rewards ever land, this is the contract to port. |
| test_bootstrap_trace_data_passes_callback_metadata | n/a | Monkeypatched Evaluate + callback_metadata plumbing; Imp has no BaseCallback system (telemetry is the substitution). |

## tests/teleprompt/test_grpo.py (3)

| Upstream test | Status | Note |
|---|---|---|
| test_grpo_dataset_shuffler | blocked | `select_training_sample_and_update_shuffled_trainset` is not a public Imp surface; GRPO's epoch shuffling is internal state. The uniform-coverage property (each example seen equally often across steps) is worth a property test on Imp's own boundary. |
| test_grpo_dataset_shuffler_with_num_ex_per_step_less_dataset | blocked | Same. |
| test_grpo_dataset_shuffler_with_num_ex_per_step_greater_dataset | blocked | Same. |

## tests/teleprompt/test_gepa.py (11)

| Upstream test | Status | Note |
|---|---|---|
| test_gepa_adapter_disables_logging_on_minibatch_eval | n/a | callback_metadata/logging plumbing on the DspyAdapter internals. |
| test_basic_workflow | pass (adapted) | Upstream replays byte-exact prompt fixtures (gepa_dummy_lm.json) through its reflection prompts; Imp's GEPA proposal contract differs (JSON instruction proposals), so the port asserts the boundary: compile completes against scripted task + reflection LMs and returns a program. The 2,000-char instruction-string equality is not reproducible by design. |
| test_workflow_with_custom_instruction_proposer_and_component_selector | pass (adapted) | Custom `:reflection_strategy` (instruction_proposer) + custom arity-5 `:module_selector` (component_selector) compile end to end; the proposer receives every selected component. Adapted: upstream replays dspy.Image fixtures and asserts the fixture instructions; Imp has no image example type, so the port asserts the boundary. |
| test_metric_requires_feedback_signature | n/a | TypeError from Python arity introspection of the metric; Imp metrics are arity-2/3 functions returning score/feedback data — the 5-arg feedback signature does not exist. |
| test_gepa_compile_with_track_usage_no_tuple_error | n/a | litellm track_usage regression ("'tuple' object has no attribute 'set_lm_usage'"); no usage-tracking tuples in Imp. |
| test_component_selector_functionality | pass | Custom arity-5 `:module_selector` function is invoked with the full candidate (both components) and may return single or multiple components. |
| test_component_selector_default_behavior | pass | No selector option → `:round_robin` default on the struct; compile completes. |
| test_component_selector_string_round_robin | pass | Upstream string "round_robin" is the `:round_robin` atom in Imp. |
| test_component_selector_string_all | pass (adapted) | `:all` updates every component in the first accepted candidate; `:round_robin` exactly one. Adapted: candidate parameters read from the Report's candidates (Imp's `detailed_results.candidates` equivalent), acceptance via `:equal_or_better` since the port's metric is constant. |
| test_component_selector_custom_random | pass | Random-half custom function selector compiles. |
| test_alternating_half_component_selector | pass | Upstream `state.i` is `state.iteration` on Imp's `Engine.State`; even iterations select the first half, odd the second, verified over multiple selections. |

## tests/teleprompt/test_gepa_instruction_proposer.py (4)

| Upstream test | Status | Note |
|---|---|---|
| test_reflection_lm_gets_structured_images | n/a | Tests DSPy's MultiModalInstructionProposer emitting structured image_url messages for dspy.Image inputs; Imp has no image example type, so there is no multimodal reflection path to assert. The pluggable proposer surface itself is covered by the ported rows below. |
| test_custom_proposer_without_reflection_lm | pass | `:reflection_strategy` (the instruction_proposer equivalent) manages its own external reflection source; GEPA compiles with `reflection_lm` unset and the external source is called. |
| test_image_serialization_into_strings | n/a | Asserts DSPy's CUSTOM-TYPE-START-IDENTIFIER text-serialization of dspy.Image objects — DSPy's own serialization format for a type Imp does not have. |
| test_default_proposer (parametrized reasoning=True/False) | pass (adapted) | Without a custom proposer the default reflection path calls the configured reflection LM and no reflection/proposal error is recorded (upstream: "Exception during reflection/proposal" absent from logs). Adapted: no dspy.Image inputs, and the reasoning parametrization is DummyLM-specific. |

## tests/teleprompt/test_bettertogether.py (20)

| Upstream test | Status | Note |
|---|---|---|
| test_bettertogether_import | n/a | Python import smoke test. |
| test_bettertogether_initialization_default | pass | Defaults: p → RandomSearch (BootstrapFewShotWithRandomSearch port), w → BootstrapFinetune. |
| test_bettertogether_initialization_custom | pass | Custom p/w kept. |
| test_bettertogether_initialization_invalid_optimizer | pass (adapted) | DSPy raises TypeError at `__init__`; Imp records loud `{:not_an_optimizer, _}` when the step runs (gap #2 — construction-time validation absent; rejection asserted at Imp's boundary). |
| test_strategy_validation | pass | Valid strategies validate; unknown key "x" is a recorded step error; empty strategy raises. |
| test_compile_basic | pass | Mock optimizer's compile is called; Report carries candidates + compilation_error_occurred (DSPy: attributes on the program). |
| test_trainset_validation | pass | Empty trainset raises "cannot be empty". |
| test_valset_ratio_validation | pass | Ratio 1.0 and -0.1 raise "[0, 1)". |
| test_optimizer_compile_args_validation | pass | Non-keyword args rejected. One port covers this and the row below. |
| test_student_in_optimizer_compile_args | pass | `student:` override rejected. |
| test_compile_args_passed_to_optimizer | pass | num_trials/max_bootstrapped_demos reach the step invocation. |
| test_compile_args_multi_optimizer_strategy | pass | p gets only p's args, w only w's. |
| test_compile_args_override_global_params | blocked | Imp compile args are invocation options; trainset/valset/teacher are positional compile parameters and cannot be overridden per step. |
| test_trainset_shuffling_between_steps | pass | Both steps receive the same example multiset (order may differ; Imp uses its deterministic seeded sampler, not Python's RNG). |
| test_strategy_execution_order | pass | "p -> w -> p" executes in order, each step receiving the prior step's output (path carried via program metadata; DSPy: ad-hoc attributes). |
| test_lm_lifecycle_management | n/a | `launch_lms`/`kill_lms` manage local litellm servers; Imp's training boundary is provider TrainingJobs — no local LM lifecycle to manage. |
| test_error_handling_returns_best_program | pass | Failing second step: best program still returned, error recorded, candidates present. |
| test_program_selection (valset / no-valset) | pass | Both parametrizations: with valset the best score wins; without (valset_ratio: 0) the latest successful step wins. |
| test_candidate_programs_structure | pass (adapted) | Report candidates: baseline + one per step, numeric scores, strategy labels; best_score selected. DSPy sorts candidates best-first; Imp keeps execution order with best_score/selection separate (seam). |
| test_empty_valset_handling | pass | `[]` and nil both select the latest program. |

## tests/evaluate/test_metrics.py (3)

Upstream's `answer_exact_match` helper is ported inline as a plain metric
function per Imp's metrics-are-functions doctrine (gap #4: no built-in
list-of-answers exact match).

| Upstream test | Status | Note |
|---|---|---|
| test_answer_exact_match_string | pass | |
| test_answer_exact_match_list | pass (adapted) | Any-member match; the list semantics live in the ported metric fn, not an Imp built-in. |
| test_answer_exact_match_no_match | pass | |

## tests/evaluate/test_evaluate.py (12)

| Upstream test | Status | Note |
|---|---|---|
| test_evaluate_initialization | pass | devset/metric stored (num_threads → max_concurrency default 1; display flags n/a — no progress UI). |
| test_evaluate_call | pass | Score 1.0 (Imp fraction; DSPy 100.0). |
| test_evaluate_single_thread_runs_in_main_thread | n/a | Python threading identity; BEAM tasks are the concurrency model. |
| test_construct_result_df | n/a | pandas DataFrame construction. |
| test_multithread_evaluate_call | pass | max_concurrency: 2 → 1.0. |
| test_multi_thread_evaluate_call_cancelled | n/a | SIGINT/KeyboardInterrupt process signaling. |
| test_evaluate_call_wrong_answer | pass | Score 0.0. |
| test_evaluate_display_table | n/a | IPython/pandas display plumbing. |
| test_evaluate_callback | n/a | BaseCallback on_evaluate_start/end; Imp's substitution is telemetry events (observability suite). |
| test_evaluation_result_repr | n/a | Python `__repr__` format. |
| test_evaluate_save_as_json_with_history | blocked | No `save_as_json`/`save_as_csv` options on Imp.Evaluate (and dspy.History-in-example serialization). Result rows are plain data callers can dump, but the built-in file surface is absent. |
| test_evaluate_save_as_csv_with_history | blocked | Same. |

## tests/evaluate/test_auto_evaluation.py (6)

SemanticF1/CompleteAndGrounded accept upstream's exact `(example, pred,
trace)` shape as a `%{example:, pred:, trace:}` map.

| Upstream test | Status | Note |
|---|---|---|
| test_semantic_f1_returns_prediction_without_trace | pass | Prediction with numeric score. |
| test_semantic_f1_returns_prediction_with_trace | pass | Boolean threshold truth with trace. |
| test_semantic_f1_score_value | pass | Harmonic mean 0.6857 from precision 0.8 / recall 0.6, byte-equal formula. |
| test_complete_and_grounded_returns_prediction_without_trace | pass | Two independent judgments combined. |
| test_complete_and_grounded_returns_prediction_with_trace | pass | Boolean threshold truth. |
| test_semantic_f1_prediction_can_be_compared | pass | result2.score > result1.score. |

## tests/streaming/test_streaming.py (37)

| Upstream test | Status | Note |
|---|---|---|
| test_streamify_yields_expected_response_chunks | pass (adapted) | litellm test-server deltas → `Imp.Streaming.stream/3` local chunking; chunks assemble the full answer. |
| test_streaming_response_yields_expected_response_chunks | n/a | `dspy.streaming.streaming_response` OpenAI-SSE re-encoding helper; no Imp counterpart by design (callers own their transport). |
| test_default_status_streaming | blocked | Tool/module status-message provider absent (gap #6); Imp statuses cover listener lifecycle only. |
| test_custom_status_streaming | blocked | Same (StatusMessageProvider subclass hooks). |
| test_concurrent_status_message_providers | blocked | Same. |
| test_stream_listener_chat_adapter | n/a | `@pytest.mark.llm_call` — requires a real LM. |
| test_default_status_streaming_in_async_program | n/a | asyncio twin. |
| test_stream_listener_json_adapter | n/a | llm_call. |
| test_streaming_handles_space_correctly | pass | Joined chunks == "How are you doing?" byte-exact. |
| test_sync_streaming | n/a | llm_call (and Imp streaming is already synchronous — the sync/async split collapses). |
| test_sync_status_streaming | blocked | Status provider absent (gap #6). |
| test_stream_listener_returns_correct_chunk_chat_adapter | **FAIL** | The one real divergence: split end marker → Imp emits untrimmed "!\n\n" and a separate nil terminal chunk; upstream trims to "!" with is_last_chunk. Tagged `@tag :upstream_fail` + `:skip`; observed output preserved in the test. |
| test_stream_listener_returns_correct_chunk_json_adapter | pass | Byte-exact including quotes in chunks, chunk boundaries, and done on the final content chunk; split-key ("jud"/"gement") half also ported. |
| test_stream_listener_returns_correct_chunk_chat_adapter_untokenized_stream | pass | Whole-section chunks; done marked on the terminal boundary chunk (nil-chunk seam, gap #3). |
| test_stream_listener_missing_completion_marker_chat_adapter | pass | All tokens flushed, terminal done, nothing lost. |
| test_stream_listener_returns_correct_chunk_json_adapter_untokenized_stream | pass (adapted) | Joined content byte-exact incl. quotes; upstream's single-chunk granularity is its buffering artifact (Imp may split at fed-chunk seams). |
| test_status_message_non_blocking | pass (adapted) | Listener status stream: exactly one :started and one :completed around the pulled events (Imp's status vocabulary; upstream's is tool-status + async timing). |
| test_status_message_non_blocking_async_program | n/a | asyncio twin. |
| test_stream_listener_allow_reuse | pass (adapted) | Same listener extracts its field from two consecutive streams; markers fed unsplit so the recorded FAIL does not mask the reuse behavior. |
| test_stream_listener_returns_correct_chunk_xml_adapter | pass | Joined content byte-exact for both fields; done on terminal boundary chunk (nil-chunk seam). |
| test_streaming_allows_custom_chunk_types | n/a | Arbitrary user dataclasses passing through streamify; Imp streams are ordinary Enumerables — any term already passes through (nothing to gate). |
| test_streaming_allows_custom_streamable_type | blocked | No custom Type.is_streamable/parse_stream_chunk protocol; typed partial-value streaming absent. |
| test_streaming_with_citations | blocked | Anthropic citations streaming (tranche-1 Citations type absent). |
| test_chat_adapter_simple_pydantic_streaming | blocked | Pydantic-typed field streaming (typed output models absent). |
| test_chat_adapter_with_generic_type_annotation | blocked | Same (list[str]-typed field streaming). |
| test_chat_adapter_nested_pydantic_streaming | blocked | Same. |
| test_chat_adapter_mixed_fields_streaming | blocked | Same. |
| test_json_adapter_simple_pydantic_streaming | blocked | Same. |
| test_json_adapter_bracket_balance_detection | blocked | Same (nested-object value streaming; Imp's JSON lexer streams string values). |
| test_json_adapter_multiple_fields_detection | blocked | Same. |
| test_stream_listener_could_form_end_identifier_chat_adapter | n/a | `_could_form_end_identifier` is upstream's private buffering predicate; Imp's equivalent retention logic is asserted behaviorally by the chunk tests above. |
| test_stream_listener_could_form_end_identifier_json_adapter | n/a | Same. |
| test_stream_listener_could_form_end_identifier_xml_adapter | n/a | Same. |
| test_streaming_reasoning_model | blocked | Native `reasoning_content` delta streaming (Reasoning type + provider reasoning deltas absent; tranche-1 seam). |
| test_stream_listener_empty_last_chunk_chat_adapter | pass | Both fields' final chunk is done (Imp: nil-content terminal chunk; upstream: empty string — gap #3). |
| test_stream_listener_empty_last_chunk_json_adapter | pass | Same for the JSON framing. |
| test_streaming_reasoning_fallback | blocked | Reasoning-field fallback streaming; same absent surface. |

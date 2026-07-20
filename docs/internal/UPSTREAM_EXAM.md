# Upstream Exam — Tranche 1: DSPy 3.2.1 adapters/ and signatures/ tests vs Imp

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
| Ported | **80** (81 ExUnit tests; one upstream test split in two) |
| — pass | **80** |
| — FAIL (real divergence found by upstream's own test) | **0** (14 found by the exam; all fixed) |
| — unclear | 0 |
| Blocked (behavior should/could exist in Imp; not expressible yet) | **78** |
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
`Imp.Adapters.Types.Citation` is a different, simpler `{text, source}` struct
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
| test_signature_field_with_constraints | blocked | DSPy renders ge/le/min_length as a human-readable `constraints` description string; Imp keeps machine constraints (validated by Imp.Schema) with no description rendering. |
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

Imp files (`Imp.Adapters.Types.File`) carry `path`/`url`/`data`/`mime_type`
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

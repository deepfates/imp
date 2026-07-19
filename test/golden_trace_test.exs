defmodule GoldenTraceTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  import ExUnit.CaptureIO

  @fixtures "test/fixtures/golden_trace/cases.json"
  @python "tmp/dspy-parity-venv/bin/python"

  test "golden trace task compares Imp and DSPy with provider-free fixtures" do
    unless File.exists?(@python) do
      flunk("missing #{@python}; run the documented DSPy parity environment setup")
    end

    out_dir = tmp_dir("golden-trace")

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Trace.run([
        "--fixtures",
        @fixtures,
        "--out",
        out_dir,
        "--python",
        @python
      ])
    end)

    [report_path] = Path.wildcard(Path.join(out_dir, "golden-trace-parity-*.json"))
    report = report_path |> File.read!() |> Jason.decode!()

    assert report["summary"]["all_cases_passing"]
    assert report["summary"]["prediction_parity"]
    assert report["summary"]["error_status_parity"]
    assert report["summary"]["tool_trace_parity"]
    assert report["summary"]["imp_semantic_checks"]["all_passing"]
    assert report["summary"]["passing"] == report["summary"]["total"]
    assert report["fixtures"]["cases"] == 33

    # Prompt fidelity (epic dee-8zev): the lane MEASURES whether Imp's rendered
    # prompt is byte-identical to DSPy's, per case. Every case is measured, and
    # the paths proven byte-identical to DSPy are LOCKED as regressions here.
    # Chat (predict/CoT/typed), JSON adapter (dee-ye3h), and the parse-failure
    # ChatAdapter->JSONAdapter fallback (dee-bd34) all hold. The only remaining
    # divergence is the ReAct trajectory (dee-kzop); full cross-adapter CI
    # enforcement lands in dee-3e4v.
    parity_by_case = report["summary"]["template_parity_by_case"]
    assert map_size(parity_by_case) == report["summary"]["total"]
    assert parity_by_case["predict_chat_basic"] == true
    assert parity_by_case["chain_of_thought_basic"] == true
    assert parity_by_case["typed_fields_chat"] == true
    assert parity_by_case["json_adapter_basic"] == true
    assert parity_by_case["missing_output_error"] == true

    # Non-scalar type rendering (dee-9ttv): enum->Literal, array->list, object->dict
    # render byte-identically to DSPy 3.2.1 across both adapters. Locked as
    # regressions so each composite type retires its defect class permanently.
    assert parity_by_case["enum_literal_chat"] == true
    assert parity_by_case["list_str_field_json"] == true
    assert parity_by_case["list_int_field_json"] == true
    assert parity_by_case["dict_field_json"] == true

    # Composite chat-adapter PARSE (dee-dgme): a `list[...]`/`dict` chat response
    # field arrives as JSON text (e.g. `[[ ## tags ## ]]\n["a","b"]`). Chat parse
    # now JSON-decodes non-scalar field values (mirroring DSPy `parse_value`'s
    # json-decode-then-validate) so the composite output round-trips. Both cases
    # reach template_parity (rendering, dee-9ttv) AND prediction_parity (this
    # parse path). Locked so the parse defect class retires permanently.
    assert parity_by_case["list_str_field_chat"] == true
    assert parity_by_case["dict_field_chat"] == true

    assert Enum.find(report["cases"], &(&1["id"] == "list_str_field_chat"))["prediction_parity"]
    assert Enum.find(report["cases"], &(&1["id"] == "dict_field_chat"))["prediction_parity"]

    # Few-shot demo rendering (dee-u4st chat, dee-0bwu json). Optimized DSPy
    # programs carry demos; Imp rendered them divergently on both adapters. Each
    # case's demo list exercises every confirmed axis at once: a COMPLETE demo
    # with `flag: true`, a COMPLETE demo with `flag: false` (a legitimate false
    # must render "False"/false, not be dropped for the missing sentinel), a
    # present-but-nil demo (kept as INCOMPLETE, values render "None"/null — not
    # dropped), and an absent-output demo (the missing-field message). The chat
    # side now always emits the trailing `[[ ## completed ## ]]` marker; the JSON
    # side emits a pretty JSON object for assistant turns instead of chat markers.
    # Byte-verified against real DSPy 3.2.1 and locked here.
    assert parity_by_case["demo_history_fidelity_chat"] == true
    assert parity_by_case["demo_history_fidelity_json"] == true

    assert Enum.find(report["cases"], &(&1["id"] == "demo_history_fidelity_chat"))[
             "prediction_parity"
           ]

    assert Enum.find(report["cases"], &(&1["id"] == "demo_history_fidelity_json"))[
             "prediction_parity"
           ]

    # ReAct :dspy_3_2_1 byte-faithfulness (dee-kzop): the reshaped `:dspy_3_2_1`
    # mode reproduces dspy.ReAct exactly. `react_dspy_tool_lookup` drives Imp's
    # faithful mode and real dspy.ReAct with the SAME text-trajectory responses,
    # so the reasoning-signature prompt (question + trajectory ->
    # next_thought/next_tool_name/next_tool_args), the interleaved trajectory
    # text, AND the separate ChainOfThought extraction call are all byte-
    # identical. Locked here so the ReAct trajectory divergence retires
    # permanently. The three provider-native `react_*` cases stay a documented
    # deviation (see below).
    assert parity_by_case["react_dspy_tool_lookup"] == true
    react_dspy = Enum.find(report["cases"], &(&1["id"] == "react_dspy_tool_lookup"))
    assert react_dspy["template_parity"]
    assert react_dspy["prediction_parity"]
    assert react_dspy["tool_trace_parity"]
    # 2 reasoning calls + 1 extraction call, all replayed provider-free.
    assert length(react_dspy["imp"]["history"]) == 3
    assert length(react_dspy["dspy"]["history"]) == 3

    # The three provider-native ReAct cases remain an intentional, documented
    # deviation: Imp's default mode uses provider function-tool calls, not the
    # DSPy text trajectory, so their prompts are NOT byte-identical.
    assert parity_by_case["react_tool_lookup"] == false
    assert parity_by_case["react_multi_tool_transform"] == false
    assert parity_by_case["react_tool_argument_error"] == false

    # Seven message-level edge divergences found by adversarial review (epic
    # dee-8zev), each now byte-identical to real DSPy 3.2.1 and LOCKED here so its
    # defect class retires permanently. Every case below reaches template_parity
    # (byte-identical rendered prompt); the JSON-adapter ones read envelope=false
    # like every JSON case (dee-ps19, asserted later).
    #
    # dee-tsce: a list value on a `str`-annotated INPUT field renders DSPy's
    # numbered guillemet blobs (`[1] «alpha»` / `«alpha»` / `N/A`), not inspect().
    assert parity_by_case["tsce_list_on_str_input_multi_chat"] == true
    assert parity_by_case["tsce_list_on_str_input_single_chat"] == true
    assert parity_by_case["tsce_list_on_str_input_empty_chat"] == true

    # dee-wrx5: empty-string instructions ("") are replaced with DSPy's
    # default-instructions sentence (whitespace-only is NOT — see the parser fix).
    assert parity_by_case["wrx5_empty_instructions_chat"] == true

    # dee-709o: the objective transform now reproduces inspect.cleandoc +
    # textwrap.dedent + str.splitlines (the full Unicode boundary set), on BOTH
    # adapters, so indented/multiline/tab/CRLF/exotic-separator instructions match.
    assert parity_by_case["o709_indented_multiline_instructions_chat"] == true
    assert parity_by_case["o709_indented_multiline_instructions_json"] == true
    assert parity_by_case["o709_crlf_instructions_chat"] == true
    assert parity_by_case["o709_tab_continuation_instructions_chat"] == true
    assert parity_by_case["o709_unicode_line_separator_instructions_chat"] == true

    # dee-68oy: nested array types render faithfully (list[list[int]] /
    # list[list[str]] with a doubly-nested schema), not silently flattened.
    assert parity_by_case["o68oy_nested_array_int_json"] == true
    assert parity_by_case["o68oy_nested_array_str_json"] == true

    # dee-p1d5: array[object] renders list[dict[str, Any]] with
    # additionalProperties:true, consistent with standalone object.
    assert parity_by_case["p1d5_array_object_json"] == true

    # dee-h7nw: bare scalar ReAct observations render Python-faithfully — float
    # fixed/exponent form (1000000.0, not 1.0e6), True/False, and None.
    assert parity_by_case["h7nw_react_float_observation"] == true
    assert parity_by_case["h7nw_react_bool_observation"] == true
    assert parity_by_case["h7nw_react_nil_observation"] == true

    # dee-cidk: ChainOfThought's ${reasoning} sentinel renders as an empty field
    # description under the JSON adapter (matching chat), not the literal token.
    assert parity_by_case["cidk_chain_of_thought_json"] == true

    # All seven fixes carry prediction_parity too (the render AND the round-trip).
    for id <- [
          "tsce_list_on_str_input_multi_chat",
          "o68oy_nested_array_int_json",
          "o68oy_nested_array_str_json",
          "p1d5_array_object_json",
          "cidk_chain_of_thought_json",
          "h7nw_react_float_observation",
          "h7nw_react_bool_observation",
          "h7nw_react_nil_observation"
        ] do
      assert Enum.find(report["cases"], &(&1["id"] == id))["prediction_parity"],
             "expected prediction_parity for #{id}"
    end

    # Request-envelope fidelity (dee-idig). The old instrument compared only
    # message role+content, so it reported false parity while Imp shipped
    # response_format:json_object on JSON cases and DSPy (capability-gated)
    # shipped nothing. envelope_parity is a NEW dimension: the PER-CALL request
    # options (LM opts on the Imp side, adapter kwargs on the DSPy side). These
    # values are LOCKED to their REAL measured truth — false where Imp and DSPy
    # actually diverge — and are NOT faked true. The underlying capability-
    # gating product fix (Imp sends response_format regardless of LM support) is
    # a SEPARATE ticket; this harness only refuses to hide the divergence.
    envelope_by_case = report["summary"]["envelope_parity_by_case"]
    assert map_size(envelope_by_case) == report["summary"]["total"]

    # Pure chat / faithful-ReAct cases send no extra request options on either
    # side -> the envelopes match, so these stay fully parity.
    assert envelope_by_case["predict_chat_basic"] == true
    assert envelope_by_case["chain_of_thought_basic"] == true
    assert envelope_by_case["typed_fields_chat"] == true
    assert envelope_by_case["enum_literal_chat"] == true
    assert envelope_by_case["list_str_field_chat"] == true
    assert envelope_by_case["dict_field_chat"] == true
    assert envelope_by_case["react_dspy_tool_lookup"] == true

    # The four JSON-adapter cases: Imp sends response_format:{type:json_object}
    # while DSPy's capability-gated JSONAdapter sends nothing for the fixture LM.
    # This request divergence was MASKED by the message-only instrument and is
    # now VISIBLE. message-parity stays true; the envelope honestly reads false.
    assert envelope_by_case["json_adapter_basic"] == false
    assert envelope_by_case["list_str_field_json"] == false
    assert envelope_by_case["list_int_field_json"] == false
    assert envelope_by_case["dict_field_json"] == false

    # The demo cases inherit their adapter's envelope behavior: the pure-chat
    # demo case sends no extra options (full parity); the JSON demo case sends
    # response_format:json_object like every other JSON case, so its envelope
    # honestly reads false (that divergence is dee-ps19, not this ticket). The
    # message templates match on BOTH (asserted above).
    assert envelope_by_case["demo_history_fidelity_chat"] == true
    assert envelope_by_case["demo_history_fidelity_json"] == false

    # The surfaced per-call envelopes make the JSON divergence legible in the
    # report itself (nothing silent), not just as a boolean.
    json_case = Enum.find(report["cases"], &(&1["id"] == "json_adapter_basic"))
    assert json_case["imp_call_envelopes"] == [%{"response_format" => %{"type" => "json_object"}}]
    assert json_case["dspy_call_envelopes"] == [%{}]

    # The ChatAdapter->JSONAdapter parse-failure fallback (missing_output_error)
    # retries the second call with response_format on the Imp side only, so its
    # envelope diverges on that call even though messages match per call.
    assert envelope_by_case["missing_output_error"] == false

    # The three provider-native ReAct cases already diverge on messages
    # (documented deviation); they also diverge on the envelope because Imp
    # sends tools/tool_choice where DSPy's text-trajectory ReAct sends nothing.
    assert envelope_by_case["react_tool_lookup"] == false
    assert envelope_by_case["react_multi_tool_transform"] == false
    assert envelope_by_case["react_tool_argument_error"] == false

    # The seven-edge fixtures inherit their adapter's envelope behavior: chat and
    # faithful-ReAct cases send no extra request options (full parity), while the
    # JSON-adapter cases send response_format:json_object like every JSON case, so
    # their envelope honestly reads false (dee-ps19, not these tickets). The
    # message templates match on all of them (asserted above).
    for id <- [
          "tsce_list_on_str_input_multi_chat",
          "tsce_list_on_str_input_single_chat",
          "tsce_list_on_str_input_empty_chat",
          "wrx5_empty_instructions_chat",
          "o709_indented_multiline_instructions_chat",
          "o709_crlf_instructions_chat",
          "o709_tab_continuation_instructions_chat",
          "o709_unicode_line_separator_instructions_chat",
          "h7nw_react_float_observation",
          "h7nw_react_bool_observation",
          "h7nw_react_nil_observation"
        ] do
      assert envelope_by_case[id] == true, "expected envelope parity for #{id}"
    end

    for id <- [
          "o709_indented_multiline_instructions_json",
          "o68oy_nested_array_int_json",
          "o68oy_nested_array_str_json",
          "p1d5_array_object_json",
          "cidk_chain_of_thought_json"
        ] do
      assert envelope_by_case[id] == false, "expected honest envelope divergence for #{id}"
    end

    # The honest faithful-port count: byte-identical messages AND identical
    # request envelope, per call. Nineteen of thirty-three cases fully match today
    # (the original eight full-parity cases plus eleven of the seven-edge
    # fixtures: three dee-tsce, one dee-wrx5, four dee-709o chat, three dee-h7nw
    # ReAct). The message-only matches (nine JSON incl. the five new JSON-adapter
    # edge fixtures + the JSON demo case + fallback, plus three native ReAct) are
    # not allowed to read as full parity.
    assert report["summary"]["envelope_parity_cases"] == 19
    assert report["summary"]["full_parity_cases"] == 19
    assert report["summary"]["message_envelope_parity"] == false

    full_by_case = report["summary"]["full_parity_by_case"]
    assert map_size(full_by_case) == report["summary"]["total"]
    assert full_by_case["json_adapter_basic"] == false
    assert full_by_case["predict_chat_basic"] == true

    assert report["imp"]["runner"] == "imp-golden-trace"
    assert report["dspy"]["runner"] == "python-dspy-golden-trace"

    assert report["cases"]
           |> Enum.reject(&(&1["expected_status"] == "error"))
           |> Enum.all?(& &1["prediction_parity"])

    assert Enum.find(report["cases"], &(&1["id"] == "missing_output_error"))["error_parity"]

    assert Enum.find(report["cases"], &(&1["id"] == "react_tool_lookup"))[
             "tool_trace_parity"
           ]

    assert Enum.find(report["cases"], &(&1["id"] == "react_multi_tool_transform"))[
             "tool_trace_parity"
           ]

    assert Enum.find(report["cases"], &(&1["id"] == "react_tool_argument_error"))[
             "error_parity"
           ]

    assert Enum.any?(report["cases"], &(&1["adapter"] == "json"))
    assert Enum.all?(report["cases"], &(&1["imp"]["history"] != []))
    assert Enum.all?(report["cases"], &(&1["dspy"]["history"] != []))

    assert Enum.map(report["imp_semantic_checks"], & &1["id"]) == [
             "streaming_incremental_fields",
             "save_load_redacts_req_llm_credentials",
             "req_llm_cache_hit_reuses_success",
             "provider_stream_chunk_replay"
           ]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

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
    assert report["fixtures"]["cases"] == 12

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

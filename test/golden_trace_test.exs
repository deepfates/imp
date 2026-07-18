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
    assert report["fixtures"]["cases"] == 8
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

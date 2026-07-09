defmodule DSEx.UpstreamFidelityTest do
  use ExUnit.Case, async: true

  test "upstream fidelity report maps every tracked upstream surface" do
    report = DSEx.UpstreamFidelity.report()

    assert report.summary.total > 50
    assert report.summary.unmapped == 0
    assert report.summary.passing

    names = MapSet.new(report.surfaces, & &1.name)

    for required <- [
          "RLM",
          "ReActV2",
          "InferRules",
          "Assertions",
          "ToolCalls",
          "History",
          "ColBERTv2",
          "optimize_anything",
          "Recursive Language Models paper"
        ] do
      assert MapSet.member?(names, required)
    end
  end

  test "upstream fidelity source anchors include papers and source indexes" do
    report = DSEx.UpstreamFidelity.report()

    assert report.source_anchors.dspy_docs == "https://dspy.ai/"
    assert report.source_anchors.deepwiki == "https://deepwiki.com/stanfordnlp/dspy"
    assert report.source_anchors.rlm_paper == "arXiv:2512.24601"
    assert report.source_anchors.optimize_anything_paper == "arXiv:2605.19633"
  end
end

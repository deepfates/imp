defmodule DSEx.UpstreamFidelityTest do
  use ExUnit.Case, async: true

  test "upstream fidelity report maps every tracked upstream surface" do
    report = DSEx.UpstreamFidelity.report()

    assert report.summary.total > 100
    assert report.summary.unmapped == 0
    assert report.summary.needs_work > 0
    assert report.summary.passing

    names = MapSet.new(report.surfaces, & &1.name)
    by_name = Map.new(report.surfaces, &{&1.name, &1})

    assert by_name["ReActV2"].status == :needs_work
    assert by_name["InferRules"].status == :needs_work
    assert by_name["ColBERTv2"].status == :intentional_omission

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

    for deepwiki_category <- [
          "History & Conversation Management",
          "Assertions & Output Validation",
          "Vector Databases & Retrieval",
          "Build System & CI/CD",
          "Package Metadata & Release Process"
        ] do
      assert MapSet.member?(names, deepwiki_category)
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

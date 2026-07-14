defmodule TutorialParityTest do
  use ExUnit.Case, async: true

  @parity_path "docs/TUTORIAL_EXAMPLE_PARITY.md"

  @families [
    "Email and entity extraction",
    "Classification",
    "RAG and multi-hop RAG",
    "Tools, ReAct, agents, and MCP",
    "Program of Thought and CodeAct",
    "Image and native document inputs",
    "Audio",
    "Streaming and async work",
    "Privacy-conscious delegation",
    "Financial analysis",
    "Games and code examples",
    "Deployment"
  ]

  test "every tutorial and real-world example family has one current DSEx disposition" do
    body = File.read!(@parity_path)

    assert body =~ "The executable learning path is the five Livebooks"

    for family <- @families do
      assert body =~ "| #{family} |", "missing parity mapping for #{family}"
    end

    assert body =~ "Intentional omission of a live-audio reasoning claim"
    assert body =~ "Benchmark-only research lane"
    assert body =~ "Canonical production path"
    refute body =~ "TODO"
    refute body =~ "placeholder"
  end

  test "parity references resolve to shipped tutorials, docs, and deployment example" do
    body = File.read!(@parity_path)

    for path <- [
          "livebooks/01_real_lm_front_door.livemd",
          "livebooks/02_programming_not_prompting.livemd",
          "livebooks/03_evaluate_and_optimize.livemd",
          "livebooks/04_tools_agents_mcp_rlm.livemd",
          "livebooks/05_operate_and_live_checks.livemd",
          "docs/API_GUIDE.md",
          "docs/MULTIMODAL_FIDELITY.md",
          "docs/BENCHMARK_CATALOG.md",
          "examples/deployment/README.md"
        ] do
      assert File.regular?(path), "missing parity target #{path}"
    end

    assert body =~ "OPENAI_API_KEY"
    assert body =~ "OPENAI_MODEL"
  end

  test "operating Livebook hands production work to the sole deployment reference" do
    livebook = File.read!("livebooks/05_operate_and_live_checks.livemd")
    deployment = File.read!("examples/deployment/README.md")

    assert livebook =~ "## Canonical Deployment Reference"
    assert livebook =~ "examples/deployment"
    assert livebook =~ "DSEX_MODEL"
    assert livebook =~ "DSEX_API_KEY"

    assert deployment =~ "## Prepare An Artifact"
    assert deployment =~ "DSEx.save!"
    assert deployment =~ "DSEX_ARTIFACT_PATH"
    assert deployment =~ "DSEX_STATIC_ANSWER=Paris"
  end
end

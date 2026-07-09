defmodule RagToolAgentArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "RAG tool agent task writes a passing production-semantics artifact" do
    out_dir = tmp_dir("rag-tool-agent")

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.rag_tool_agent")
      Mix.Tasks.Dsex.Benchmark.RagToolAgent.run(["--out", out_dir])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "rag-tool-agent-parity-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["full_rag_tool_agent_parity"]
    assert artifact["summary"]["direct_comparisons"] == 2

    rows = Map.new(artifact["rows"], &{&1["id"], &1})

    assert rows["rag_memory_retrieval"]["passing"]
    assert rows["rag_multi_hop_retrieval"]["passing"]
    assert get_in(rows, ["rag_multi_hop_retrieval", "dsex", "trace", "hops"]) |> length() == 2
    assert rows["react_lookup_tool"]["passing"]
    assert rows["code_act_tool_program"]["passing"]
    assert get_in(rows, ["code_act_tool_program", "dsex", "trace"]) |> length() == 2
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end

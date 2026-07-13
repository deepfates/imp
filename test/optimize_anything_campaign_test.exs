defmodule OptimizeAnythingCampaignTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.OptimizeAnything.{
    AgentConfig,
    Artifact,
    Campaign,
    CodeArtifact,
    SchedulingHeuristic
  }

  test "campaign runs every evaluator across seeds and records measured usage" do
    responses =
      [CodeArtifact, AgentConfig, SchedulingHeuristic]
      |> Enum.flat_map(fn evaluator -> List.duplicate(evaluator.comparator(), 3) end)

    {:ok, queue} = Agent.start_link(fn -> responses end)

    lm = fn _messages, _opts ->
      response = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)

      :telemetry.execute(
        [:req_llm, :token_usage],
        %{total_cost: 0.002, tokens: %{input_tokens: 120, output_tokens: 40}},
        %{}
      )

      {:ok, "```text\n#{response}\n```"}
    end

    out_dir = tmp_dir("optimize-anything-campaign")

    %{artifact: artifact, out_path: path} =
      Campaign.run(
        lm: lm,
        provider: "openai",
        model: "gpt-5.4-mini-2026-03-17",
        seeds: [17, 23, 31],
        max_proposals: 1,
        run_id: "oa-campaign-contract-test",
        out_dir: out_dir
      )

    assert Artifact.full_artifact?(artifact)
    assert File.regular?(path)
    assert Agent.get(queue, & &1) == []
    assert length(artifact["rows"]) == 3

    for row <- artifact["rows"] do
      assert row["optimized"]["score"] > row["baseline"]["score"]
      assert row["input_tokens"] == 360
      assert row["output_tokens"] == 120
      assert_in_delta row["cost_usd"], 0.006, 1.0e-12
      assert length(row["reproducibility"]["runs"]) == 3
      assert Enum.all?(row["reproducibility"]["runs"], &(&1["lift"] > 0))
      assert Enum.all?(row["reproducibility"]["runs"], &File.regular?(&1["checkpoint"]))
    end
  end

  test "campaign requires distinct reproducibility seeds" do
    assert_raise ArgumentError, ~r/at least three distinct integers/, fn ->
      Campaign.run(
        lm: fn _, _ -> {:ok, "unused"} end,
        provider: "test",
        model: "test",
        seeds: [1]
      )
    end
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

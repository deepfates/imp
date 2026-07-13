defmodule GepaMergeTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "merges exactly one full-scope row for every required family" do
    root = tmp_dir()
    out = Path.join(root, "out")

    paths =
      required_families()
      |> Enum.with_index()
      |> Enum.map(fn {family, index} -> write_chunk!(root, family, index) end)

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_merge")
      Mix.Tasks.Dsex.Benchmark.GepaMerge.run(paths ++ ["--out", out])
    end)

    [path] = Path.wildcard(Path.join(out, "dsex-gepa-merged-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["partial"] == false
    assert artifact["summary"]["families"] == required_families()
    assert Enum.map(artifact["rows"], & &1["family"]) == required_families()
    assert length(artifact["source_chunks"]) == 6
  end

  test "rejects duplicate and missing families" do
    root = tmp_dir()
    aime = write_chunk!(root, "AIMEBench", 0)
    duplicate = write_chunk!(root, "AIMEBench", 1)

    assert_raise Mix.Error, ~r/duplicate GEPA families: AIMEBench/, fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_merge")
      Mix.Tasks.Dsex.Benchmark.GepaMerge.run([aime, duplicate])
    end
  end

  test "rejects chunks with mismatched concurrency or execution identity" do
    root = tmp_dir()

    paths =
      required_families()
      |> Enum.with_index()
      |> Enum.map(fn {family, index} -> write_chunk!(root, family, index) end)

    [first | rest] = paths
    first_chunk = first |> File.read!() |> Jason.decode!()

    File.write!(
      first,
      first_chunk |> put_in(["summary", "max_concurrency"], 4) |> Jason.encode!()
    )

    assert_raise Mix.Error, ~r/canonical campaign contract|summary disagrees/, fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_merge")
      Mix.Tasks.Dsex.Benchmark.GepaMerge.run([first | rest])
    end

    File.write!(
      first,
      first_chunk
      |> put_in(["summary", "execution", "lm", "max_tokens"], 512)
      |> Jason.encode!()
    )

    assert_raise Mix.Error, ~r/canonical campaign contract|summary disagrees/, fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_merge")
      Mix.Tasks.Dsex.Benchmark.GepaMerge.run([first | rest])
    end
  end

  defp write_chunk!(root, family, index) do
    path = Path.join(root, "chunk-#{index}.json")

    execution = %{
      "lm" => %{"provider" => "req_llm", "temperature" => 0, "max_tokens" => 256},
      "retrieval" => %{"hover_upstream_bm25" => true}
    }

    source_commits = %{
      "dsex" => "dsex@abc",
      "dspy" => "dspy@abc",
      "gepa_artifact" => "gepa@abc"
    }

    contract = %{
      "schema_version" => 1,
      "campaign_id" => "campaign-full",
      "model" => "openai:gpt-4.1-mini-2025-04-14",
      "reflection_model" => "openai:gpt-4.1-mini-2025-04-14",
      "judge_model" => "openai:gpt-4.1-mini-2025-04-14",
      "seeds" => [0, 1],
      "generations" => 1,
      "max_concurrency" => 8,
      "pricing_source" => "provider telemetry",
      "token_cost_schedule_sha256" => "sha256:" <> String.duplicate("a", 64),
      "source_commits" => source_commits,
      "execution" => execution
    }

    chunk = %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-campaign",
      "generated_at" => "2026-07-13T00:00:00Z",
      "git_sha" => "abcdef1",
      "summary" => %{
        "campaign_id" => "campaign-full",
        "families" => [family],
        "generations" => 1,
        "model" => "openai:gpt-4.1-mini-2025-04-14",
        "max_concurrency" => 8,
        "execution" => execution,
        "partial" => true,
        "reflection_model" => "openai:gpt-4.1-mini-2025-04-14",
        "seeds" => [0, 1],
        "total" => 1,
        "campaign_contract" => contract
      },
      "rows" => [
        %{
          "family" => family,
          "campaign_id" => "campaign-full",
          "model" => "openai:gpt-4.1-mini-2025-04-14",
          "reflection_model" => "openai:gpt-4.1-mini-2025-04-14",
          "execution" => execution,
          "dataset" => %{
            "scope" => "full",
            "max_per_split" => nil,
            "split_counts" => %{"train" => 2, "dev" => 2, "test" => 2}
          },
          "seed_variance" => %{"seeds" => [0, 1]},
          "source_commits" => source_commits
        }
      ]
    }

    File.write!(path, Jason.encode!(chunk))
    path
  end

  defp required_families, do: DSEx.BenchmarkTruth.GepaReplicationContract.required_families()

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "dsex-gepa-merge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end

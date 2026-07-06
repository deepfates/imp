defmodule BenchmarkTruthTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.Fetcher

  @fixtures Path.expand("fixtures/benchmarks", __DIR__)

  test "fetcher normalizes HuggingFace rows and writes manifests" do
    out_dir = tmp_dir("fetch")

    body =
      Jason.encode!(%{
        "rows" => [
          %{
            "row" => %{
              "question" => "What is 2+2?",
              "answer" => "Compute 2+2. #### 4"
            }
          }
        ]
      })

    [result] =
      DSEx.BenchmarkTruth.fetch(["gsm8k"],
        out_dir: out_dir,
        length: 1,
        page_delay_ms: 0,
        transport: fn _url -> {:ok, body} end
      )

    assert File.exists?(result.data_path)
    assert File.exists?(result.manifest_path)

    assert %{"rows" => 1, "task" => "gsm8k", "sha256" => sha} =
             Jason.decode!(File.read!(result.manifest_path))

    assert byte_size(sha) == 64
    assert [%{"canonical_answer" => "4"}] = result.data_path |> File.read!() |> read_jsonl()
  end

  test "fetcher paginates full-size requests and records source pages" do
    out_dir = tmp_dir("fetch-pages")
    parent = self()

    [result] =
      DSEx.BenchmarkTruth.fetch(["gsm8k"],
        out_dir: out_dir,
        length: 101,
        page_delay_ms: 0,
        transport: fn url ->
          send(parent, {:fetched, URI.decode(url)})

          rows =
            if String.contains?(url, "offset=0") do
              Enum.map(1..100, &gsm8k_hf_row/1)
            else
              [gsm8k_hf_row(101)]
            end

          {:ok, Jason.encode!(%{"rows" => rows})}
        end
      )

    manifest = Jason.decode!(File.read!(result.manifest_path))
    rows = result.data_path |> File.read!() |> read_jsonl()

    assert manifest["requested_length"] == 101
    assert manifest["rows"] == 101
    assert length(manifest["source_urls"]) == 2
    assert length(rows) == 101
    assert_received {:fetched, url}
    assert url =~ "length=100"
    assert_received {:fetched, url}
    assert url =~ "offset=100"
  end

  test "HotPotQA normalization flattens title/sentence context" do
    row = %{
      "id" => "x",
      "question" => "q",
      "answer" => "a",
      "context" => %{"title" => ["One"], "sentences" => [["Alpha.", "Beta."]]},
      "supporting_facts" => %{}
    }

    assert %{"context" => "One: Alpha. Beta."} = Fetcher.normalize_hotpotqa(row)
  end

  test "fixture benchmark truth runner evaluates GSM8K and HotPotQA and writes report" do
    out_dir = tmp_dir("results")

    result =
      DSEx.BenchmarkTruth.run(
        tasks: [
          gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl"),
          hotpotqa: Path.join(@fixtures, "hotpotqa-small.jsonl")
        ],
        out_dir: out_dir,
        max_examples: 2
      )

    assert File.exists?(result.out_path)
    assert result.report["aggregate_score"] == 1.0
    assert Enum.map(result.report["tasks"], & &1["task"]) == ["gsm8k", "hotpotqa"]
    assert Enum.all?(result.report["tasks"], &(&1["score"] == 1.0))

    assert Enum.all?(result.report["tasks"], fn task ->
             task["optimizer_comparisons"]
             |> Enum.map(& &1["optimizer"])
             |> Enum.sort() ==
               ["BootstrapFewShot", "COPRO", "GEPA", "LabeledFewShot", "MIPROv2", "SIMBA"]
           end)

    assert %{"schema_version" => 1, "tasks" => [_ | _]} =
             Jason.decode!(File.read!(result.out_path))
  end

  test "benchmark truth runner supports offset chunks" do
    out_dir = tmp_dir("offset-results")

    result =
      DSEx.BenchmarkTruth.run(
        tasks: [gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl")],
        out_dir: out_dir,
        offset: 1,
        max_examples: 1
      )

    [task] = result.report["tasks"]
    [row] = task["rows"]

    assert task["offset"] == 1
    assert task["examples"] == 1
    assert row["prediction"][:answer] == "3"
  end

  defp read_jsonl(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-benchmark-truth-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp gsm8k_hf_row(index) do
    %{
      "row" => %{
        "question" => "What is #{index}+0?",
        "answer" => "Compute #{index}+0. #### #{index}"
      }
    }
  end
end

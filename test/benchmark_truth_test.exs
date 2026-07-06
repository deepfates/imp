defmodule BenchmarkTruthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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

  test "parity aggregate deduplicates overlapping chunks and reports coverage gaps" do
    out_dir = tmp_dir("parity-aggregate")
    write_parity_report(out_dir, "older.json", "2026-07-06T00:00:00Z", 0, [true, false])
    write_parity_report(out_dir, "newer.json", "2026-07-06T00:01:00Z", 1, [true, true])

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert campaign["model"] == "gpt-test"
    assert campaign["coverage"]["covered"] == 3
    refute campaign["coverage"]["full"]
    refute campaign["parity"]["full_parity"]
    assert gsm8k["coverage"]["covered"] == 3
    assert gsm8k["dsex_passes"] == 3
    assert gsm8k["dspy_passes"] == 3
    assert [%{"from" => 3, "to" => 1318} | _] = gsm8k["coverage"]["missing_ranges"]
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

  defp write_parity_report(out_dir, name, generated_at, offset, passes) do
    rows =
      passes
      |> Enum.with_index()
      |> Enum.map(fn {passed?, index} ->
        %{
          "index" => index,
          "absolute_index" => offset + index,
          "dsex_passed" => passed?,
          "dspy_passed" => passed?,
          "pass_agreement" => true,
          "answer_agreement" => true,
          "dsex_answer" => to_string(offset + index),
          "dspy_answer" => to_string(offset + index)
        }
      end)

    report = %{
      "schema_version" => 1,
      "generated_at" => generated_at,
      "dsex" => %{"model" => %{"model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "tasks" => [
        %{
          "task" => "gsm8k",
          "offset" => offset,
          "examples" => length(rows),
          "dsex_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "row_agreement" => rows
        }
      ],
      "evidence" => %{"examples" => length(rows)}
    }

    File.write!(Path.join(out_dir, name), Jason.encode!(report, pretty: true) <> "\n")
  end
end

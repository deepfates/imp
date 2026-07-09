defmodule GepaReplicationArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "GEPA replication task validates required paper-family fields and writes artifact" do
    out_dir = tmp_dir("gepa-replication")
    input_path = write_rows!("complete-gepa", full_rows())

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_replication")

      Mix.Tasks.Dsex.Benchmark.GepaReplication.run([
        "--input",
        input_path,
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["full_gepa_replication"]
    assert artifact["summary"]["missing_families"] == []
    assert artifact["summary"]["missing_fields"] == []

    assert Enum.map(artifact["rows"], & &1["family"]) == [
             "AIMEBench",
             "HotpotQABench",
             "hoverBench",
             "IFBench",
             "LiveBenchMathBench",
             "Papillon"
           ]

    assert Enum.all?(artifact["rows"], fn row ->
             is_map(row["results"]["baseline"]) and
               is_map(row["results"]["dspy_gepa"]) and
               is_map(row["results"]["dsex_gepa"]) and
               is_map(row["results"]["mipro_v2"]) and
               is_map(row["token_cost"]) and
               is_map(row["seed_variance"]) and
               is_map(row["train_dev_test_gap"]) and
               is_integer(row["metric_calls"]) and
               is_integer(row["wall_clock_ms"]) and
               is_map(row["dataset"]) and
               is_map(row["optimizer_budgets"]) and
               is_map(row["source_commits"])
           end)
  end

  test "GEPA replication task rejects forged full rows with placeholder comparator evidence" do
    out_dir = tmp_dir("gepa-replication-forged")
    [row | rest] = full_rows()

    forged =
      [
        put_in(row, ["results", "dspy_gepa", "source"], "placeholder DSPy GEPA row")
      ] ++ rest

    input_path = write_rows!("forged-gepa", forged)

    assert_raise Mix.Error, ~r/GEPA replication artifact is incomplete/, fn ->
      capture_io(fn ->
        Mix.Task.reenable("dsex.benchmark.gepa_replication")

        Mix.Tasks.Dsex.Benchmark.GepaReplication.run([
          "--input",
          input_path,
          "--out",
          out_dir
        ])
      end)
    end

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    refute artifact["summary"]["all_passing"]
    refute artifact["summary"]["full_gepa_replication"]

    assert %{"family" => "AIMEBench", "field" => "dspy_gepa"} in artifact["summary"][
             "missing_fields"
           ]
  end

  test "GEPA replication smoke runner exercises DSEx GEPA without authorizing research claims" do
    out_dir = tmp_dir("gepa-replication-smoke")

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_replication")

      Mix.Tasks.Dsex.Benchmark.GepaReplication.run([
        "--smoke",
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    refute artifact["summary"]["full_gepa_replication"]
    assert artifact["summary"]["evidence_level"] == "smoke"

    assert Enum.all?(
             artifact["rows"],
             &(get_in(&1, ["results", "dsex_gepa", "source"]) == "DSEx.Optimize.GEPA")
           )
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp write_rows!(name, rows) do
    path = Path.join(tmp_dir(name), "rows.json")
    File.write!(path, Jason.encode!(%{"rows" => rows}, pretty: true))
    path
  end

  defp full_rows do
    [
      {"AIMEBench", "CoT", 1839},
      {"HotpotQABench", "HotpotMultiHop", 6871},
      {"hoverBench", "HoverMultiHop", 7051},
      {"IFBench", "IFBenchCoT2StageProgram", 3593},
      {"LiveBenchMathBench", "CoT", 1839},
      {"Papillon", "PAPILLON", 2426}
    ]
    |> Enum.map(fn {family, program, budget} ->
      full_row(family, program, budget)
    end)
  end

  defp full_row(family, program, budget) do
    %{
      "family" => family,
      "program" => program,
      "campaign_id" => "gepa-replication-test-campaign",
      "model" => "openai/gpt-4.1-mini-2025-04-14",
      "reflection_model" => "openai/gpt-5-2026-01-01",
      "evidence_level" => "research_campaign",
      "metric_calls" => budget,
      "optimizer_budgets" => %{
        "baseline" => 1,
        "dspy_gepa" => budget,
        "dsex_gepa" => budget,
        "mipro_v2" => budget
      },
      "dataset" => %{
        "source" => "github.com/gepa-ai/gepa-artifact@abcdef1",
        "split" => "train_dev_test",
        "checksums" => %{
          "train" => "sha256:#{family}:train",
          "dev" => "sha256:#{family}:dev",
          "test" => "sha256:#{family}:test"
        }
      },
      "source_commits" => %{
        "dspy" => "stanfordnlp/dspy@abcdef1",
        "dsex" => "deepfates/dsex@abcdef2",
        "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
      },
      "token_cost" => %{
        "usd" => 1.25,
        "input_tokens" => 10_000,
        "output_tokens" => 2_000,
        "pricing_source" => "openai pricing table 2026-07-09"
      },
      "wall_clock_ms" => 12_345,
      "seed_variance" => %{"seeds" => [0, 1, 2], "stddev" => 0.01},
      "train_dev_test_gap" => %{
        "train" => 0.8,
        "dev" => 0.75,
        "test" => 0.73,
        "split_digests" => %{
          "train" => "sha256:#{family}:train",
          "dev" => "sha256:#{family}:dev",
          "test" => "sha256:#{family}:test"
        }
      },
      "results" => %{
        "baseline" => %{"score" => 0.5, "source" => "DSEx baseline runner artifact"},
        "dspy_gepa" => %{"score" => 0.6, "source" => "DSPy GEPA runner artifact"},
        "dsex_gepa" => %{"score" => 0.61, "source" => "DSEx GEPA runner artifact"},
        "mipro_v2" => %{"score" => 0.55, "source" => "DSPy MIPROv2 runner artifact"},
        "simba" => %{"score" => 0.56, "source" => "optional SIMBA comparator artifact"}
      }
    }
  end
end

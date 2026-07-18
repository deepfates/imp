defmodule HotpotRetrievalArtifactTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  import ExUnit.CaptureIO

  alias Mix.Tasks.Imp.Benchmark.HotpotRetrieval

  test "pinned subset is source-includable with explicit share-alike attribution" do
    manifest = Jason.decode!(File.read!("benchmarks/data/hotpotqa-validation-0-10.manifest.json"))

    assert manifest["license"] == "CC-BY-SA-4.0"
    assert manifest["license_notice"] == "benchmarks/data/HOTPOTQA_ATTRIBUTION.md"
    assert File.regular?(manifest["license_notice"])

    {_output, status} =
      System.cmd("git", ["check-ignore", "-q", manifest["data_path"]], stderr_to_stdout: true)

    assert status == 1
  end

  test "writes a matched, source-bound ten-row shared-corpus differential" do
    out = tmp_dir("hotpot-retrieval")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.hotpot_retrieval")
      HotpotRetrieval.run(["--no-require-clean", "--out", out])
    end)

    [path] = Path.wildcard(Path.join(out, "hotpot-retrieval-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["provider_free_differential_complete"]
    refute artifact["summary"]["full_hotpotqa_effectiveness"]
    assert artifact["summary"]["matched_rows"] == 10
    assert artifact["corpus"]["documents"] == 100
    assert length(artifact["rows"]) == 10
    assert Enum.all?(artifact["rows"], & &1["matched"])
    assert Enum.all?(artifact["rows"], &(length(&1["imp"]["retrieved_ids"]) == 5))
    assert Enum.all?(artifact["rows"], &(&1["imp"]["context_sha256"] =~ ~r/^sha256:/))

    assert HotpotRetrieval.validate_artifact!(artifact, require_clean: false) == artifact

    if get_in(artifact, ["run_context", "workspace", "state"]) == "dirty" do
      assert_raise ArgumentError, ~r/requires a clean source checkout/, fn ->
        HotpotRetrieval.validate_artifact!(artifact)
      end
    end

    tampered = put_in(artifact, ["rows", Access.at(0), "matched"], false)

    assert_raise ArgumentError, ~r/invalid or tampered benchmark run envelope/, fn ->
      HotpotRetrieval.validate_artifact!(tampered, require_clean: false)
    end
  end

  test "comparison rejects missing, duplicate, reordered, and wrong-source DSPy evidence" do
    out = tmp_dir("hotpot-retrieval-negative")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.hotpot_retrieval")
      HotpotRetrieval.run(["--no-require-clean", "--out", out])
    end)

    [path] = Path.wildcard(Path.join(out, "hotpot-retrieval-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()
    imp = report_side(artifact, "imp")
    dspy = report_side(artifact, "dspy")

    mutations = [
      Map.update!(dspy, "rows", &tl/1),
      Map.update!(dspy, "rows", fn [row | rows] -> [row, row | rows] end),
      Map.update!(dspy, "rows", &Enum.reverse/1)
    ]

    Enum.each(mutations, fn mutated ->
      assert_raise Mix.Error, ~r/exact pinned ten-row split in order/, fn ->
        HotpotRetrieval.compare_reports!(imp, mutated)
      end
    end)

    wrong_source = put_in(dspy, ["source", "commit"], String.duplicate("0", 40))

    assert_raise Mix.Error, ~r/stale or wrong source bindings/, fn ->
      HotpotRetrieval.compare_reports!(imp, wrong_source)
    end
  end

  defp report_side(artifact, side) do
    %{
      "runner" => artifact[side]["runner"],
      "protocol_id" => artifact["protocol_id"],
      "corpus" => artifact["corpus"],
      "summary" => artifact[side]["summary"],
      "source" => artifact[side]["source"],
      "dspy_version" => artifact[side]["dspy_version"],
      "rows" => Enum.map(artifact["rows"], & &1[side])
    }
  end

  defp tmp_dir(label) do
    path = Path.join(System.tmp_dir!(), "imp-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

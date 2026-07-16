defmodule BfclAdaptedArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Imp.Benchmark.BfclAdapted
  alias Imp.BenchmarkTruth.ReproductionArtifactValidator

  @fixture_path "test/fixtures/benchmarks/bfcl-adapted-v1.json"
  @score_keys ~w(valid_input tool_name_exact arguments_exact terminal_state_exact passing error_code)

  test "runs independent positive and preregistered mutation corpora" do
    artifact = run_artifact!()

    assert artifact["evidence_level"] == "C1_T1_fixture_scorer_agreement"
    assert artifact["summary"]["fixture_scorer_conformance_complete"]
    refute artifact["summary"]["official_bfcl_effectiveness"]
    refute artifact["summary"]["dspy_comparison"]
    refute artifact["summary"]["operational_evidence"]
    assert artifact["summary"]["matched_positive_rows"] == 12
    assert artifact["summary"]["matched_mutation_rows"] == 9
    assert artifact["summary"]["mutation_detection_accuracy"] == 1.0
    assert artifact["summary"]["tool_name_accuracy"] == 1.0
    assert artifact["summary"]["argument_accuracy"] == 1.0
    assert artifact["summary"]["terminal_state_accuracy"] == 1.0
    assert length(artifact["rows"]) == 12
    assert length(artifact["mutations"]) == 9
    assert Enum.all?(artifact["rows"] ++ artifact["mutations"], & &1["matched"])
    assert artifact["source_bindings"]["fixture_license"] == "CC0-1.0"
    assert artifact["source_bindings"]["upstream_usage"] == "protocol_provenance_only"
    assert artifact["reference"]["runtime"]["dependencies"] == "stdlib_only"

    assert BfclAdapted.validate_artifact!(artifact,
             require_clean: false,
             python: "/definitely/missing/python"
           ) == artifact

    if get_in(artifact, ["run_context", "workspace", "state"]) == "dirty" do
      assert_raise ArgumentError, ~r/requires a clean source checkout/, fn ->
        BfclAdapted.validate_artifact!(artifact)
      end
    end
  end

  test "explicit local replay is separate from pure canonical validation" do
    artifact = run_artifact!()

    assert BfclAdapted.validate_artifact!(artifact,
             require_clean: false,
             replay_reference: true
           ) == artifact
  end

  test "canonical dispatcher is pure and rejects injected claim promotion" do
    artifact = run_artifact!() |> mark_clean() |> reseal()

    assert :ok = ReproductionArtifactValidator.validate!("bfcl_shaped_scorer", artifact)

    promoted =
      artifact
      |> put_in(["summary", "official_bfcl_effectiveness"], true)
      |> reseal()

    assert_raise ArgumentError,
                 ~r/rows, summaries, sources, runtime, limitations, or claim flags are invalid/,
                 fn ->
                   ReproductionArtifactValidator.validate!("bfcl_shaped_scorer", promoted)
                 end
  end

  test "shared mutation corpus detects every preregistered failure independently" do
    fixture = read_json!(@fixture_path)

    for mutation <- fixture["mutations"] do
      score = BfclAdapted.score_case!(mutation)
      assert Map.take(score, @score_keys) == mutation["expected_score"], mutation["id"]
      refute score["passing"]
    end

    malformed = Enum.find(fixture["mutations"], &(&1["category"] == "malformed_json"))
    assert BfclAdapted.score_case!(malformed)["error_code"] == "malformed_argument_json"

    invalid_terminal =
      Enum.find(fixture["mutations"], &(&1["category"] == "invalid_terminal"))

    assert BfclAdapted.score_case!(invalid_terminal)["error_code"] == "invalid_trace"
  end

  test "comparison rejects missing, duplicate, reordered, and wrong-bound reports" do
    artifact = run_artifact!()
    imp = report_side(artifact, "imp")
    reference = report_side(artifact, "reference")

    for mutated <- [
          Map.update!(reference, "rows", &tl/1),
          Map.update!(reference, "rows", fn [row | rows] -> [row, row | rows] end),
          Map.update!(reference, "rows", &Enum.reverse/1)
        ] do
      assert_raise Mix.Error, ~r/exact pinned positive corpus in order/, fn ->
        BfclAdapted.compare_reports!(imp, mutated)
      end
    end

    for mutated <- [
          Map.update!(reference, "mutations", &tl/1),
          Map.update!(reference, "mutations", fn [row | rows] -> [row, row | rows] end),
          Map.update!(reference, "mutations", &Enum.reverse/1)
        ] do
      assert_raise Mix.Error, ~r/exact pinned mutation corpus in order/, fn ->
        BfclAdapted.compare_reports!(imp, mutated)
      end
    end

    wrong_source = put_in(reference, ["source", "upstream_commit"], String.duplicate("0", 40))

    assert_raise Mix.Error, ~r/stale or wrong source\/runtime bindings/, fn ->
      BfclAdapted.compare_reports!(imp, wrong_source)
    end

    wrong_runtime = put_in(reference, ["runtime", "dependencies"], "unbounded")

    assert_raise Mix.Error, ~r/stale or wrong source\/runtime bindings/, fn ->
      BfclAdapted.compare_reports!(imp, wrong_runtime)
    end
  end

  test "artifact validation recomputes rows, summaries, runtime, limitations, and claim flags" do
    artifact = run_artifact!()

    mutations = [
      put_in(artifact, ["rows", Access.at(0), "matched"], false),
      put_in(artifact, ["mutations", Access.at(0), "imp", "error_code"], "forged"),
      put_in(artifact, ["summary", "matched_positive_rows"], 11),
      put_in(artifact, ["reference", "runtime", "version"], "0.0.0"),
      put_in(artifact, ["source_bindings", "upstream_commit"], String.duplicate("0", 40)),
      put_in(artifact, ["limitations", Access.at(0)], "unlimited evidence"),
      put_in(artifact, ["summary", "official_bfcl_effectiveness"], true),
      put_in(artifact, ["summary", "dspy_comparison"], true),
      put_in(artifact, ["summary", "operational_evidence"], true),
      Map.put(artifact, "official_bfcl_accuracy", 1.0)
    ]

    for tampered <- mutations do
      resealed = reseal(tampered)

      assert_raise ArgumentError,
                   ~r/rows, summaries, sources, runtime, limitations, or claim flags are invalid/,
                   fn -> BfclAdapted.validate_artifact!(resealed, require_clean: false) end
    end

    envelope_tamper = put_in(artifact, ["rows", Access.at(0), "matched"], false)

    assert_raise ArgumentError, ~r/invalid or tampered benchmark run envelope/, fn ->
      BfclAdapted.validate_artifact!(envelope_tamper, require_clean: false)
    end
  end

  defp run_artifact! do
    out = tmp_dir("bfcl-shaped")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.bfcl_adapted")
      BfclAdapted.run(["--out", out])
    end)

    [path] = Path.wildcard(Path.join(out, "bfcl-shaped-conformance-*.json"))
    read_json!(path)
  end

  defp report_side(artifact, side) do
    base = %{
      "runner" => artifact[side]["runner"],
      "protocol_id" => artifact["protocol_id"],
      "summary" => artifact[side]["summary"],
      "rows" => Enum.map(artifact["rows"], & &1[side]),
      "mutations" => Enum.map(artifact["mutations"], & &1[side])
    }

    if side == "reference" do
      Map.merge(base, %{
        "runtime" => artifact[side]["runtime"],
        "source" => artifact[side]["source"]
      })
    else
      base
    end
  end

  defp reseal(artifact) do
    payload = Map.drop(artifact, ["generated_at", "git_sha", "run_context"])
    context = put_in(artifact["run_context"], ["payload_sha256"], digest(payload))
    context = Map.put(context, "envelope_sha256", digest(Map.delete(context, "envelope_sha256")))
    Map.put(artifact, "run_context", context)
  end

  defp mark_clean(artifact) do
    artifact
    |> put_in(["run_context", "workspace", "state"], "clean")
    |> put_in(["run_context", "workspace", "reproducible"], true)
  end

  defp digest(value) do
    "sha256:" <>
      (:crypto.hash(:sha256, canonical_json(value)) |> Base.encode16(case: :lower))
  end

  defp canonical_json(%{} = map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> canonical_json(value)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp tmp_dir(label) do
    path = Path.join(System.tmp_dir!(), "imp-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

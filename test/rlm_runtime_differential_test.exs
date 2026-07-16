defmodule Imp.BenchmarkTruth.RLMRuntimeDifferentialReadinessTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.RLMRuntimeDifferential

  test "readiness reports setup errors without importing Python" do
    assert {:error, message} =
             RLMRuntimeDifferential.readiness(
               manifest: "/tmp/imp-missing-rlm-manifest.json",
               upstream: "/tmp/imp-missing-rlm-checkout",
               python: "/tmp/imp-missing-rlm-python"
             )

    assert message =~ "manifest is missing"
  end
end

defmodule Imp.BenchmarkTruth.RLMRuntimeDifferentialTest do
  use ExUnit.Case, async: false

  @differential_enabled System.get_env("IMP_RLM_DIFFERENTIAL") == "1"
  @moduletag :rlm_differential

  unless @differential_enabled do
    @moduletag skip: "set IMP_RLM_DIFFERENTIAL=1 to run the provider-free differential gate"
  end

  alias Imp.BenchmarkTruth.RLMRuntimeDifferential

  @manifest "benchmarks/config/rlm-runtime-differential-v1.json"
  @python "tmp/rlm-upstream/.venv/bin/python"
  @upstream "tmp/rlm-upstream"

  setup_all do
    if @differential_enabled do
      {:ok, artifact: run_artifact!()}
    else
      {:ok, artifact: nil}
    end
  end

  test "manifest separates matched semantics, declared deviations, and paper claims" do
    manifest = @manifest |> File.read!() |> Jason.decode!()
    cases = manifest["cases"]

    assert manifest["protocol_id"] == "rlm_runtime_differential"
    assert length(cases) == 9
    assert Enum.count(cases, &(&1["comparison"] == "matched")) == 8
    assert Enum.count(cases, &(&1["comparison"] == "declared_deviation")) == 1
    assert Enum.all?(cases, &is_map(&1["boundary"]))
    assert length(manifest["authority"]["selected_tests"]) >= 10

    assert Enum.sort(Enum.uniq(Enum.map(cases, & &1["category"]))) ==
             Enum.sort(manifest["required_categories"])

    assert "paper-scale T3 reproduction" in manifest["claim_scope"]["excluded"]
  end

  test "pinned standalone runtime and Imp pass the complete C1/C2 differential", %{
    artifact: artifact
  } do
    assert artifact["summary"]["c1_behavioral_conformance"]
    assert artifact["summary"]["c2_provider_free_operation"]
    assert artifact["summary"]["differential_complete"]
    assert artifact["summary"]["highest_satisfied_rung"] == "C2"
    assert artifact["summary"]["upstream_authority_tests_passed"]
    refute artifact["summary"]["paper_protocol_complete"]
    refute artifact["summary"]["effectiveness_claimed"]

    assert Enum.all?(artifact["rows"], & &1["passing"])
    assert Enum.all?(artifact["rows"], & &1["official"]["real_boundary"])
    assert Enum.all?(artifact["rows"], & &1["imp"]["real_boundary"])
  end

  test "validator rejects boundary evidence without an observed public invocation", %{
    artifact: artifact
  } do
    rows =
      List.update_at(artifact["rows"], 4, fn row ->
        update_in(row, ["official", "details", "boundary_evidence"], fn evidence ->
          %{evidence | "observed_invocations" => 0, "call_shapes" => []}
        end)
      end)

    forged = put_in(artifact, ["rows"], rows)

    assert_raise ArgumentError, ~r/not derivable|invalid standalone RLM/, fn ->
      RLMRuntimeDifferential.validate_artifact!(forged, %{"manifest" => @manifest})
    end
  end

  test "validator rejects forged compaction observations", %{artifact: artifact} do
    rows =
      List.update_at(artifact["rows"], 3, fn row ->
        put_in(row, ["official", "canonical", "next_prompt_shorter"], false)
      end)

    forged = put_in(artifact, ["rows"], rows)

    assert_raise ArgumentError, ~r/not derivable|invalid standalone RLM/, fn ->
      RLMRuntimeDifferential.validate_artifact!(forged, %{"manifest" => @manifest})
    end
  end

  test "validator rejects forged upstream authority-test evidence", %{artifact: artifact} do
    forged = put_in(artifact, ["upstream_tests", "status"], "failed")

    assert_raise ArgumentError, ~r/identity mismatch|not derivable|invalid standalone RLM/, fn ->
      RLMRuntimeDifferential.validate_artifact!(forged, %{"manifest" => @manifest})
    end
  end

  test "validator recomputes the captured upstream pytest digest", %{artifact: artifact} do
    forged = put_in(artifact, ["upstream_tests", "stdout"], "forged pytest output\n")

    assert_raise ArgumentError, ~r/identity mismatch|invalid standalone RLM/, fn ->
      RLMRuntimeDifferential.validate_artifact!(forged, %{"manifest" => @manifest})
    end
  end

  test "validator rejects an arbitrary 64-character upstream pytest digest", %{artifact: artifact} do
    forged = put_in(artifact, ["upstream_tests", "output_sha256"], String.duplicate("0", 64))

    assert_raise ArgumentError, ~r/identity mismatch|invalid standalone RLM/, fn ->
      RLMRuntimeDifferential.validate_artifact!(forged, %{"manifest" => @manifest})
    end
  end

  defp run_artifact! do
    case RLMRuntimeDifferential.readiness(
           manifest: @manifest,
           python: @python,
           upstream: @upstream
         ) do
      {:ok, _ready} ->
        RLMRuntimeDifferential.run(
          manifest: @manifest,
          python: @python,
          upstream: @upstream
        )

      {:error, reason} ->
        flunk("RLM differential readiness gate failed: #{reason}")
    end
  end
end

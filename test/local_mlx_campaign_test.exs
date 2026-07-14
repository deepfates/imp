defmodule DSEx.BenchmarkTruth.LocalMLXCampaignTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.LocalMLXCampaign

  @artifact_path Path.expand(
                   "../benchmarks/results/local-mlx/local-mlx-ada199b-20260713.json",
                   __DIR__
                 )

  test "admits only complete matched improvement with fusion and save/load equivalence" do
    baseline = [row("one", "R17", "R42"), row("two", "R42", "R42")] |> expand_rows() |> result()
    trained = [row("one", "R17", "R17"), row("two", "R42", "R42")] |> expand_rows() |> result()

    assert %{
             "admissible" => true,
             "official_fusion_completed" => true,
             "save_load_equivalent" => true,
             "row_identity_preserved" => true
           } = LocalMLXCampaign.acceptance(baseline, trained, trained)

    malformed = put_in(trained, ["rows", Access.at(0), "status"], "error")
    refute LocalMLXCampaign.acceptance(baseline, malformed, trained)["admissible"]

    reordered = Map.update!(trained, "rows", &Enum.reverse/1)
    refute LocalMLXCampaign.acceptance(baseline, trained, reordered)["admissible"]
  end

  test "restores runtime credentials only when portable deployment configuration matches" do
    runtime_lm =
      DSEx.req_llm("openai:default_model",
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    loaded =
      DSEx.predict("question -> answer", lm: runtime_lm)
      |> DSEx.Saving.dump()
      |> DSEx.Saving.load()

    refute Keyword.has_key?(DSEx.ProgramAccess.lm(loaded).opts, :api_key)

    restored = LocalMLXCampaign.restore_runtime_credentials!(loaded, runtime_lm)
    assert DSEx.ProgramAccess.lm(restored) == runtime_lm

    mismatched =
      DSEx.req_llm("openai:other_model",
        api_key: "local",
        base_url: "http://127.0.0.1:18821/v1"
      )

    assert_raise RuntimeError, ~r/changed its credential-free deployment LM/, fn ->
      LocalMLXCampaign.restore_runtime_credentials!(loaded, mismatched)
    end
  end

  test "independently validates the committed canonical campaign artifact" do
    artifact = @artifact_path |> File.read!() |> Jason.decode!()
    assert {:ok, ^artifact} = LocalMLXCampaign.validate_artifact(artifact)

    tampered = put_in(artifact, ["fused", "accuracy"], 1.0)
    assert {:error, [:invalid_run_envelope]} = LocalMLXCampaign.validate_artifact(tampered)
  end

  test "rejects re-enveloped canonical, metric, fusion, and persistence forgeries" do
    artifact = @artifact_path |> File.read!() |> Jason.decode!()

    cases = [
      {[:canonical_dataset],
       &put_in(&1, ["dataset", "payload_sha256"], "sha256:" <> String.duplicate("0", 64))},
      {[:recomputed_acceptance, :recomputed_effect], &put_in(&1, ["fused", "accuracy"], 1.0)},
      {[:official_fusion, :recomputed_acceptance],
       &put_in(&1, ["fusion", "result", "exit_status"], 1)},
      {[:recomputed_acceptance],
       &put_in(&1, ["reloaded", "rows", Access.at(0), "actual"], "R42")},
      {[:recomputed_acceptance], &put_in(&1, ["acceptance", "admissible"], false)}
    ]

    for {expected_errors, mutate} <- cases do
      assert {:error, errors} =
               artifact |> reenvelope(mutate) |> LocalMLXCampaign.validate_artifact()

      assert Enum.all?(expected_errors, &(&1 in errors))
    end

    assert {:error, errors} =
             artifact
             |> reenvelope(& &1, "dirty")
             |> LocalMLXCampaign.validate_artifact()

    assert :clean_run in errors
  end

  defp row(id, expected, actual) do
    %{
      "id" => id,
      "expected" => expected,
      "actual" => actual,
      "status" => "ok",
      "correct" => expected == actual
    }
  end

  defp expand_rows(rows) do
    for repetition <- 0..19, row <- rows do
      Map.update!(row, "id", &"#{&1}-#{repetition}")
    end
  end

  defp result(rows) do
    correct = Enum.count(rows, & &1["correct"])

    %{
      "rows" => rows,
      "total" => length(rows),
      "correct" => correct,
      "failures" => 0,
      "accuracy" => correct / length(rows),
      "macro_f1" => macro_f1(rows)
    }
  end

  defp macro_f1(rows) do
    ["R17", "R42", "R68", "R93"]
    |> Enum.map(fn label ->
      tp = Enum.count(rows, &(&1["expected"] == label and &1["actual"] == label))
      fp = Enum.count(rows, &(&1["expected"] != label and &1["actual"] == label))
      fn_ = Enum.count(rows, &(&1["expected"] == label and &1["actual"] != label))
      if 2 * tp + fp + fn_ == 0, do: 0.0, else: 2 * tp / (2 * tp + fp + fn_)
    end)
    |> then(&(Enum.sum(&1) / 4))
  end

  defp reenvelope(artifact, mutate, workspace_state \\ "clean") do
    payload = artifact |> Map.drop(["generated_at", "git_sha", "run_context"]) |> mutate.()

    DSEx.BenchmarkTruth.RunContext.new!(
      source_commits: %{"dsex" => "deepfates/dsex@test-revision"},
      workspace_state: workspace_state
    )
    |> DSEx.BenchmarkTruth.RunContext.finish(payload)
  end
end

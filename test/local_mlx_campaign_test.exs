defmodule DSEx.BenchmarkTruth.LocalMLXCampaignTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.LocalMLXCampaign

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
end

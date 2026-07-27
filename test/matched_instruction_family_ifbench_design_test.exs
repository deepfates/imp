defmodule Imp.MatchedInstructionFamilyIFBenchDesignTest do
  use ExUnit.Case, async: true

  @root "examples/matched_instruction_family_ifbench"

  test "draft binds a bounded non-launchable cross-family condition" do
    contract = read_json!(@root <> "/contract-draft.json")

    assert contract["status"] == "draft_no_network_authority"

    assert contract["dataset"]["counts"] == %{
             "train" => 16,
             "selection" => 32,
             "held_out" => 64
           }

    assert contract["arms"] == [
             "baseline",
             "gepa",
             "mipro_v2",
             "simba",
             "copro",
             "infer_rules",
             "signature_optimizer_native"
           ]

    safety = contract["outer_safety"]

    assert_in_delta safety["new_spend_usd_max"],
                    safety["task_calls"] * safety["task_usd_per_reserved_call"] +
                      safety["optimizer_calls"] * safety["optimizer_usd_per_reserved_call"],
                    1.0e-9

    assert_in_delta safety["workshop_aggregate_after_usd_lte"],
                    safety["known_workshop_aggregate_before_usd_lte"] +
                      safety["new_spend_usd_max"],
                    1.0e-9

    assert safety["workshop_aggregate_after_usd_lte"] <
             safety["authorized_workshop_ceiling_usd"]

    assert "cross-runtime no-model message and information-flow differential" in contract[
             "launch_blockers"
           ]
  end

  test "frozen rows are disjoint, content-bound, and cover the independent constraint registry" do
    receipt = read_json!(@root <> "/data/receipt.json")
    assert receipt["selection"]["result_blind"]

    ids = receipt["split_ids"]
    all_ids = ids["train"] ++ ids["selection"] ++ ids["held_out"]
    assert length(all_ids) == 112
    assert length(Enum.uniq(all_ids)) == 112

    for split <- ~w(train selection held_out) do
      path = @root <> "/data/#{split}.jsonl"
      assert sha256(path) == receipt["split_sha256"][split]
      assert length(read_jsonl!(path)) == receipt["counts"][split]
    end

    held_out_ids =
      (@root <> "/data/held_out.jsonl")
      |> read_jsonl!()
      |> Enum.flat_map(& &1["instruction_id_list"])
      |> MapSet.new()

    # The independent IFBench test owner contains the extended constraint
    # registry; the bounded slice must retain broad coverage rather than an
    # ordered-prefix accident.
    assert MapSet.size(held_out_ids) >= 50
  end

  @tag :requires_dspy_capture
  test "pinned DSPy and Imp render byte-identical two-stage task messages" do
    python =
      System.get_env("IMP_DSPY_PYTHON") ||
        Path.expand("tmp/dspy-parity-venv/bin/python")

    assert File.regular?(python), "set IMP_DSPY_PYTHON to the pinned DSPy 3.2.1 interpreter"

    {output, 0} =
      System.cmd(python, [@root <> "/no_model_task_messages.py"], stderr_to_stdout: true)

    upstream = Jason.decode!(output)

    program =
      Imp.BenchmarkTruth.IFBenchTwoStage.new(
        Imp.LM.Static.new(handler: fn _messages, _opts -> %{} end)
      )

    imp = [
      Imp.Adapter.Chat.format(
        program.generate_response_module.predict.signature,
        %{query: "Write exactly BLUE."},
        []
      ),
      Imp.Adapter.Chat.format(
        program.ensure_correct_response_module.predict.signature,
        %{query: "Write exactly BLUE.", response: "BLUE"},
        []
      )
    ]

    assert imp |> Jason.encode!() |> Jason.decode!() == upstream
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp read_jsonl!(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

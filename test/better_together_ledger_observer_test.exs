defmodule Imp.TestSupport.BetterTogetherLedgerObserverTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.Report
  alias Imp.TestSupport.BetterTogetherLedgerObserver, as: Observer

  test "classifies mixed baseline, weight, and prompt phases by durable identities" do
    report =
      Report.new(%{
        optimizer: :better_together,
        best_score: 0.5,
        candidate_count: 3,
        candidates: [
          %{strategy: "", status: :ok, score: 0.125},
          %{strategy: "w", status: :ok, score: 0.5},
          %{strategy: "w -> p", status: :ok, score: 0.5}
        ],
        metadata: %{selected_strategy: "w"}
      })

    calls =
      [
        call("validation-1", "/base", "original", 1.0),
        call("validation-2", "/base", "original", 0.0),
        call("validation-1", "/fused", "original", 1.0),
        call("validation-2", "/fused", "original", 0.0),
        call("train-1", "/fused", "original", 1.0),
        call("train-2", "/fused", "original", 0.0),
        call("train-1", "/fused", "proposal", 0.0),
        call("train-2", "/fused", "proposal", 1.0),
        call("validation-1", "/fused", "original", 1.0),
        call("validation-2", "/fused", "original", 0.0)
      ]
      |> Enum.reverse()

    observed =
      Observer.classify!(calls, Report.dump(report),
        train_ids: ["train-1", "train-2"],
        validation_ids: ["validation-1", "validation-2"],
        base_model: "/base",
        weighted_model: "/fused"
      )

    assert observed.baseline.calls == 2
    assert observed.prefix_selection.calls == 4
    assert Enum.sort(Enum.map(observed.prompt_candidates, & &1.calls)) == [2, 2]
    assert observed.rendered_instruction_count == 2
    assert observed.program_identity_count == 3
    assert observed.candidate_scores == [{"", 0.125}, {"w", 0.5}, {"w -> p", 0.5}]
    assert observed.selected_strategy == "w"

    assert observed.entries
           |> Enum.filter(&(&1.phase == :prefix_selection))
           |> Enum.all?(&(&1.prefixes == ["w", "w -> p"]))
  end

  test "rejects unknown rows and model drift instead of assigning by chronology" do
    report =
      Report.new(%{
        candidates: [%{strategy: "", status: :ok, score: 0.0}],
        metadata: %{selected_strategy: ""}
      })

    assert_raise ArgumentError, ~r/unknown durable row identity/, fn ->
      Observer.classify!([call("other", "/base", "original", 0.0)], report,
        train_ids: ["train"],
        validation_ids: ["validation"],
        base_model: "/base",
        weighted_model: "/fused"
      )
    end

    assert_raise ArgumentError, ~r/does not belong to a BetterTogether phase/, fn ->
      Observer.classify!([call("validation", "/other", "original", 0.0)], report,
        train_ids: ["train"],
        validation_ids: ["validation"],
        base_model: "/base",
        weighted_model: "/fused"
      )
    end
  end

  defp call(id, model, instruction, score) do
    %{
      id: id,
      response_model: model,
      score: score,
      trace: %{messages: [%{role: :system, content: "rendered #{instruction}"}]}
    }
  end
end

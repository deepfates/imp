defmodule Imp.Confidence.CalibrationTest do
  use ExUnit.Case, async: true

  alias Imp.Confidence.Calibration

  test "reports exact Brier, ECE, reliability, abstention, and prompt drift" do
    records = [
      record("e1", 0.9, true, prompt: :a),
      record("e2", 0.8, false, prompt: :a),
      record("e3", 0.4, true, prompt: :b),
      record("e4", 0.1, false, prompt: :b)
    ]

    report = Calibration.report(records, bins: 2, abstention_thresholds: [0.0, 0.85])

    assert_in_delta report.brier_score, 0.255, 1.0e-12
    assert_in_delta report.ece, 0.3, 1.0e-12
    assert report.sample_count == 4
    assert report.class_balance == %{correct: 2, incorrect: 2}
    assert report.accuracy == 0.5
    assert Enum.map(report.reliability_buckets, & &1.count) == [2, 2]
    assert [%{coverage: 1.0}, %{accepted: 1, coverage: 0.25, accuracy: 1.0}] = report.abstention
    assert Map.keys(report.prompt_reports) |> Enum.sort() == [:a, :b]
    assert_in_delta report.prompt_drift.mean_confidence_delta, 0.6, 1.0e-12
  end

  test "valid mixed histogram exposes class balance, occupancy, and mapping" do
    calibration = mixed_calibration()
    fitted = Calibration.fit_histogram(calibration, bins: 2)
    summary = Calibration.histogram_summary(fitted)

    assert Calibration.authoritative?(fitted)
    assert summary.authoritative?
    assert summary.class_balance == %{correct: 2, incorrect: 2}
    assert summary.occupied_bin_count == 2
    assert summary.supported_bin_count == 2

    assert [low, high] = summary.mapping

    assert Map.take(low, [:index, :count, :correct, :incorrect]) ==
             %{index: 0, count: 2, correct: 0, incorrect: 2}

    assert Map.take(high, [:index, :count, :correct, :incorrect]) ==
             %{index: 1, count: 2, correct: 2, incorrect: 0}

    assert low.probability_correct == 0.0
    assert high.probability_correct == 1.0

    assert {:ok, low_value} = Calibration.calibrate(fitted, 0.4)
    assert {:ok, high_value} = Calibration.calibrate(fitted, 0.7)
    assert low_value == 0.0
    assert high_value == 1.0

    held_out = [record("h1", 0.1, false), record("h2", 0.7, true)]
    report = Calibration.evaluate_histogram(fitted, held_out, abstention_thresholds: [0.0])

    assert report.sample_count == 2
    assert report.brier_score == 0.0
  end

  test "all-correct, all-wrong, and single-bin fits are non-authoritative" do
    all_correct =
      Calibration.fit_histogram(
        [
          record("c1", 0.2, true),
          record("c2", 0.3, true),
          record("c3", 0.8, true),
          record("c4", 0.9, true)
        ],
        bins: 2
      )

    all_wrong =
      Calibration.fit_histogram(
        [
          record("w1", 0.2, false),
          record("w2", 0.3, false),
          record("w3", 0.8, false),
          record("w4", 0.9, false)
        ],
        bins: 2
      )

    single_bin = Calibration.fit_histogram(mixed_calibration(), bins: 1)

    refute Calibration.authoritative?(all_correct)
    refute Calibration.authoritative?(all_wrong)
    refute Calibration.authoritative?(single_bin)

    assert :all_correct in all_correct.fit.non_authoritative_reasons
    assert :all_wrong in all_wrong.fit.non_authoritative_reasons
    assert :single_bin_fit in single_bin.fit.non_authoritative_reasons
    assert :single_occupied_bin in single_bin.fit.non_authoritative_reasons

    assert {:error, {:non_authoritative_calibration, reasons}} =
             Calibration.calibrate(all_correct, 0.8)

    assert :all_correct in reasons

    assert_raise ArgumentError, ~r/calibration fit is non-authoritative/, fn ->
      Calibration.evaluate_histogram(all_correct, [record("held", 0.8, true)])
    end
  end

  test "unsupported held-out bins fail closed on an otherwise valid fit" do
    calibration = [
      record("c1", 0.1, false),
      record("c2", 0.2, false),
      record("c3", 0.8, true),
      record("c4", 0.9, true)
    ]

    fitted = Calibration.fit_histogram(calibration, bins: 3)
    assert Calibration.authoritative?(fitted)
    assert {:error, {:unsupported_calibration_bin, 1}} = Calibration.calibrate(fitted, 0.5)
  end

  test "source and group overlap cannot be hidden by caller-namespaced IDs" do
    fitted =
      mixed_calibration()
      |> List.update_at(0, &Map.merge(&1, %{id: "minimal:shared", source_id: "shared"}))
      |> List.update_at(1, &Map.put(&1, :group_id, "thread-shared"))
      |> Calibration.fit_histogram(bins: 2)

    source_overlap = [
      record("policy:shared", 0.7, true, source_id: "shared")
    ]

    assert_raise ArgumentError, ~r/source_ids/, fn ->
      Calibration.evaluate_histogram(fitted, source_overlap)
    end

    group_overlap = [
      record("held:other", 0.7, true,
        source_id: "held-source",
        group_id: "thread-shared"
      )
    ]

    assert_raise ArgumentError, ~r/group_ids/, fn ->
      Calibration.evaluate_histogram(fitted, group_overlap)
    end
  end

  test "duplicate held-out sources and evaluation IDs fail closed" do
    fitted = Calibration.fit_histogram(mixed_calibration(), bins: 2)

    duplicate_source = [
      record("minimal:h1", 0.2, false, source_id: "h1"),
      record("policy:h1", 0.8, true, source_id: "h1")
    ]

    assert_raise ArgumentError, ~r/held-out source IDs must be unique/, fn ->
      Calibration.evaluate_histogram(fitted, duplicate_source)
    end

    assert_raise ArgumentError, ~r/evaluation IDs must be unique/, fn ->
      Calibration.report([
        record("duplicate", 0.2, false, source_id: "s1"),
        record("duplicate", 0.8, true, source_id: "s2")
      ])
    end
  end

  test "histogram summaries serialize deterministically regardless of input order" do
    records = mixed_calibration()
    left = records |> Calibration.fit_histogram(bins: 2) |> Calibration.histogram_summary()

    right =
      records
      |> Enum.reverse()
      |> Calibration.fit_histogram(bins: 2)
      |> Calibration.histogram_summary()

    assert left == right
    assert Jason.encode!(left) == Jason.encode!(right)
  end

  test "Brier comparison reports improvement, regression, and rejects split mismatch" do
    raw = %{sample_count: 20, brier_score: 0.24}
    improved = Calibration.compare_brier(raw, %{sample_count: 20, brier_score: 0.18})
    regressed = Calibration.compare_brier(raw, %{sample_count: 20, brier_score: 0.31})

    assert improved.improved?
    assert improved.outcome == "improved"
    assert_in_delta improved.raw_minus_calibrated, 0.06, 1.0e-12
    refute regressed.improved?
    assert regressed.outcome == "regressed"
    assert_in_delta regressed.calibrated_minus_raw, 0.07, 1.0e-12

    assert_raise ArgumentError, ~r/same non-empty held-out sample/, fn ->
      Calibration.compare_brier(raw, %{sample_count: 19, brier_score: 0.18})
    end
  end

  test "invalid evidence fails closed" do
    assert_raise ArgumentError, ~r/must not be empty/, fn -> Calibration.report([]) end

    assert_raise ArgumentError, ~r/between 0 and 1/, fn ->
      Calibration.report([record("invalid", 1.1, true)])
    end

    assert_raise ArgumentError, ~r/invalid evaluation record/, fn ->
      Calibration.report([%{id: "missing-source", raw_confidence: 0.5, correct?: true}])
    end
  end

  defp mixed_calibration do
    [
      record("c1", 0.2, false),
      record("c2", 0.3, false),
      record("c3", 0.8, true),
      record("c4", 0.9, true)
    ]
  end

  defp record(id, raw_confidence, correct?, opts \\ []) do
    %{
      id: id,
      source_id: Keyword.get(opts, :source_id, "source-#{id}"),
      group_id: Keyword.get(opts, :group_id),
      raw_confidence: raw_confidence,
      correct?: correct?,
      prompt: Keyword.get(opts, :prompt)
    }
  end
end

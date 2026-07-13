defmodule DSEx.Confidence.CalibrationTest do
  use ExUnit.Case, async: true

  alias DSEx.Confidence.Calibration

  test "reports exact Brier, ECE, reliability, abstention, and prompt drift" do
    records = [
      %{id: 1, raw_confidence: 0.9, correct?: true, prompt: :a},
      %{id: 2, raw_confidence: 0.8, correct?: false, prompt: :a},
      %{id: 3, raw_confidence: 0.4, correct?: true, prompt: :b},
      %{id: 4, raw_confidence: 0.1, correct?: false, prompt: :b}
    ]

    report = Calibration.report(records, bins: 2, abstention_thresholds: [0.0, 0.85])

    assert_in_delta report.brier_score, 0.255, 1.0e-12
    assert_in_delta report.ece, 0.3, 1.0e-12
    assert report.sample_count == 4
    assert report.accuracy == 0.5
    assert Enum.map(report.reliability_buckets, & &1.count) == [2, 2]
    assert [%{coverage: 1.0}, %{accepted: 1, coverage: 0.25, accuracy: 1.0}] = report.abstention
    assert Map.keys(report.prompt_reports) |> Enum.sort() == [:a, :b]
    assert_in_delta report.prompt_drift.mean_confidence_delta, 0.6, 1.0e-12
  end

  test "histogram calibration requires disjoint held-out IDs and observed bins" do
    calibration = [
      %{id: :c1, raw_confidence: 0.2, correct?: false},
      %{id: :c2, raw_confidence: 0.3, correct?: true},
      %{id: :c3, raw_confidence: 0.8, correct?: true},
      %{id: :c4, raw_confidence: 0.9, correct?: true}
    ]

    fitted = Calibration.fit_histogram(calibration, bins: 2)
    assert {:ok, 0.5} = Calibration.calibrate(fitted, 0.4)
    assert {:ok, 1.0} = Calibration.calibrate(fitted, 0.7)

    held_out = [
      %{id: :h1, raw_confidence: 0.1, correct?: false},
      %{id: :h2, raw_confidence: 0.7, correct?: true}
    ]

    report = Calibration.evaluate_histogram(fitted, held_out, abstention_thresholds: [0.0])
    assert report.sample_count == 2
    assert report.brier_score == 0.125

    assert_raise ArgumentError, ~r/must be disjoint/, fn ->
      Calibration.evaluate_histogram(fitted, [hd(calibration)])
    end

    sparse = Calibration.fit_histogram([hd(calibration)], bins: 2)
    assert {:error, {:unsupported_calibration_bin, 1}} = Calibration.calibrate(sparse, 0.9)
  end

  test "invalid or duplicate evidence fails closed" do
    assert_raise ArgumentError, ~r/must not be empty/, fn -> Calibration.report([]) end

    assert_raise ArgumentError, ~r/between 0 and 1/, fn ->
      Calibration.report([%{id: 1, raw_confidence: 1.1, correct?: true}])
    end

    assert_raise ArgumentError, ~r/must be unique/, fn ->
      Calibration.fit_histogram([
        %{id: 1, raw_confidence: 0.2, correct?: false},
        %{id: 1, raw_confidence: 0.8, correct?: true}
      ])
    end
  end
end

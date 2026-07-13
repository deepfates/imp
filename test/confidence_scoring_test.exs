defmodule DSEx.Confidence.ScoringTest do
  use ExUnit.Case, async: true

  alias DSEx.Confidence.Scoring
  alias DSEx.Confidence.Scoring.{LinearBlend, Sigmoid, Threshold}

  test "linear blend matches the upstream interpolation formula" do
    strategy = LinearBlend.new(low_confidence_threshold: 0.5, min_score_on_correct: 0.3)

    assert Scoring.score(strategy, false, :math.log(0.99)) == 0.0
    assert Scoring.score(strategy, true, nil) == 1.0
    assert Scoring.score(strategy, true, :math.log(0.5)) == 1.0

    assert_in_delta Scoring.score(strategy, true, :math.log(0.25)),
                    0.3 + (1.0 - 0.3) * (0.25 / 0.5),
                    1.0e-12
  end

  test "threshold and sigmoid match the upstream formulas" do
    threshold = Threshold.new(threshold: 0.7)
    assert Scoring.score(threshold, true, :math.log(0.7)) == 1.0
    assert Scoring.score(threshold, true, :math.log(0.69)) == 0.0
    assert Scoring.score(threshold, false, :math.log(0.99)) == 0.0

    sigmoid = Sigmoid.new(midpoint: 0.6, steepness: 8.0)
    expected = 1.0 / (1.0 + :math.exp(-8.0 * (0.75 - 0.6)))
    assert_in_delta Scoring.score(sigmoid, true, :math.log(0.75)), expected, 1.0e-12
    assert Scoring.score(sigmoid, false, :math.log(0.75)) == 0.0
  end

  test "strategy parameters fail closed outside upstream ranges" do
    assert_raise ArgumentError, fn -> LinearBlend.new(low_confidence_threshold: 0.0) end
    assert_raise ArgumentError, fn -> LinearBlend.new(min_score_on_correct: 1.0) end
    assert_raise ArgumentError, fn -> Threshold.new(threshold: 1.1) end
    assert_raise ArgumentError, fn -> Sigmoid.new(midpoint: 1.0) end
    assert_raise ArgumentError, fn -> Sigmoid.new(steepness: 0) end
  end
end

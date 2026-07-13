defmodule DSEx.Confidence.Scoring do
  @moduledoc """
  Source-faithful scoring strategies for correctness and joint token logprob.

  These formulas follow GEPA commit `65df4325e3fb4781cf2ab17dd144d6ce2f7b98fe`.
  A joint logprob is converted to raw confidence with `exp(logprob)`; this value
  is a model score, not a calibrated probability.
  """

  @callback score(struct(), boolean(), number() | nil) :: float()
  @callback describe(struct()) :: String.t()

  @doc "Scores correctness with a configured strategy."
  def score(%module{} = strategy, correct?, joint_logprob)
      when is_boolean(correct?) and (is_number(joint_logprob) or is_nil(joint_logprob)) do
    module.score(strategy, correct?, joint_logprob)
  end

  defmodule LinearBlend do
    @moduledoc "Linear interpolation below a raw-confidence threshold."
    @behaviour DSEx.Confidence.Scoring

    defstruct low_confidence_threshold: 0.5, min_score_on_correct: 0.3

    def new(opts \\ []) do
      threshold = Keyword.get(opts, :low_confidence_threshold, 0.5)
      minimum = Keyword.get(opts, :min_score_on_correct, 0.3)

      unless is_number(threshold) and threshold > 0.0 and threshold <= 1.0,
        do: raise(ArgumentError, "low_confidence_threshold must be in (0, 1]")

      unless is_number(minimum) and minimum >= 0.0 and minimum < 1.0,
        do: raise(ArgumentError, "min_score_on_correct must be in [0, 1)")

      %__MODULE__{
        low_confidence_threshold: threshold * 1.0,
        min_score_on_correct: minimum * 1.0
      }
    end

    @impl true
    def score(_strategy, false, _joint_logprob), do: 0.0
    def score(_strategy, true, nil), do: 1.0

    def score(strategy, true, joint_logprob) do
      raw_confidence = :math.exp(joint_logprob)

      if raw_confidence >= strategy.low_confidence_threshold do
        1.0
      else
        t = raw_confidence / strategy.low_confidence_threshold
        strategy.min_score_on_correct + (1.0 - strategy.min_score_on_correct) * t
      end
    end

    @impl true
    def describe(strategy) do
      "LinearBlendScoring(threshold=#{strategy.low_confidence_threshold}, min_score=#{strategy.min_score_on_correct})"
    end
  end

  defmodule Threshold do
    @moduledoc "Binary correctness gated by a raw-confidence threshold."
    @behaviour DSEx.Confidence.Scoring

    defstruct threshold: 0.7

    def new(opts \\ []) do
      threshold = Keyword.get(opts, :threshold, 0.7)

      unless is_number(threshold) and threshold > 0.0 and threshold <= 1.0,
        do: raise(ArgumentError, "threshold must be in (0, 1]")

      %__MODULE__{threshold: threshold * 1.0}
    end

    @impl true
    def score(_strategy, false, _joint_logprob), do: 0.0
    def score(_strategy, true, nil), do: 1.0

    def score(strategy, true, joint_logprob),
      do: if(:math.exp(joint_logprob) >= strategy.threshold, do: 1.0, else: 0.0)

    @impl true
    def describe(strategy), do: "ThresholdScoring(threshold=#{strategy.threshold})"
  end

  defmodule Sigmoid do
    @moduledoc "Smooth sigmoid over raw confidence for correct answers."
    @behaviour DSEx.Confidence.Scoring

    defstruct midpoint: 0.5, steepness: 10.0

    def new(opts \\ []) do
      midpoint = Keyword.get(opts, :midpoint, 0.5)
      steepness = Keyword.get(opts, :steepness, 10.0)

      unless is_number(midpoint) and midpoint > 0.0 and midpoint < 1.0,
        do: raise(ArgumentError, "midpoint must be in (0, 1)")

      unless is_number(steepness) and steepness > 0.0,
        do: raise(ArgumentError, "steepness must be positive")

      %__MODULE__{midpoint: midpoint * 1.0, steepness: steepness * 1.0}
    end

    @impl true
    def score(_strategy, false, _joint_logprob), do: 0.0
    def score(_strategy, true, nil), do: 1.0

    def score(strategy, true, joint_logprob) do
      raw_confidence = :math.exp(joint_logprob)
      1.0 / (1.0 + :math.exp(-strategy.steepness * (raw_confidence - strategy.midpoint)))
    end

    @impl true
    def describe(strategy) do
      "SigmoidScoring(midpoint=#{strategy.midpoint}, steepness=#{strategy.steepness})"
    end
  end
end

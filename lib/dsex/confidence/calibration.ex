defmodule DSEx.Confidence.Calibration do
  @moduledoc """
  Held-out reliability analysis for raw constrained-label confidence.

  Raw token confidence is treated as an uncalibrated score. Histogram fitting
  estimates probability of correctness from a distinct calibration split;
  evaluation refuses overlapping example IDs and unsupported empty bins.
  """

  @default_thresholds [0.0, 0.5, 0.7, 0.8, 0.9, 0.95, 0.99]

  defmodule Histogram do
    @moduledoc false
    @enforce_keys [:bins, :estimates, :calibration_ids]
    defstruct [:bins, :estimates, :calibration_ids]
  end

  @type record :: %{
          required(:id) => term(),
          required(:raw_confidence) => number(),
          required(:correct?) => boolean(),
          optional(:prompt) => term()
        }

  @doc "Computes Brier score, ECE, reliability buckets, abstention, and prompt drift."
  def report(records, opts \\ []) when is_list(records) do
    bins = positive_integer!(Keyword.get(opts, :bins, 10), :bins)
    thresholds = Keyword.get(opts, :abstention_thresholds, @default_thresholds)
    records = validate_records!(records)
    validate_thresholds!(thresholds)

    buckets = reliability_buckets(records, bins)

    %{
      sample_count: length(records),
      brier_score: mean(records, &brier/1),
      ece: Enum.sum(Enum.map(buckets, &(&1.weight * &1.gap))),
      accuracy: mean(records, &indicator(&1.correct?)),
      mean_confidence: mean(records, & &1.raw_confidence),
      reliability_buckets: buckets,
      abstention: Enum.map(thresholds, &abstention(records, &1)),
      prompt_reports: prompt_reports(records, bins),
      prompt_drift: prompt_drift(records, bins)
    }
  end

  @doc "Fits fixed-width histogram calibration on uniquely identified examples."
  def fit_histogram(records, opts \\ []) when is_list(records) do
    bins = positive_integer!(Keyword.get(opts, :bins, 10), :bins)
    min_bin_size = positive_integer!(Keyword.get(opts, :min_bin_size, 1), :min_bin_size)
    records = validate_records!(records)
    ids = Enum.map(records, & &1.id)

    if length(ids) != MapSet.size(MapSet.new(ids)) do
      raise ArgumentError, "calibration example IDs must be unique"
    end

    estimates =
      records
      |> Enum.group_by(&bin_index(&1.raw_confidence, bins))
      |> Map.new(fn {index, grouped} ->
        estimate = if length(grouped) >= min_bin_size, do: mean(grouped, &indicator(&1.correct?))
        {index, %{count: length(grouped), probability_correct: estimate}}
      end)

    %Histogram{bins: bins, estimates: estimates, calibration_ids: MapSet.new(ids)}
  end

  @doc "Maps one raw score to held-out empirical probability of correctness."
  def calibrate(%Histogram{} = calibrator, raw_confidence) do
    validate_confidence!(raw_confidence)
    index = bin_index(raw_confidence, calibrator.bins)

    case calibrator.estimates[index] do
      %{probability_correct: value} when is_number(value) -> {:ok, value}
      _ -> {:error, {:unsupported_calibration_bin, index}}
    end
  end

  @doc "Evaluates a fitted histogram on a disjoint held-out split."
  def evaluate_histogram(%Histogram{} = calibrator, records, opts \\ []) do
    records = validate_records!(records)

    overlap =
      records
      |> Enum.map(& &1.id)
      |> MapSet.new()
      |> MapSet.intersection(calibrator.calibration_ids)

    if MapSet.size(overlap) > 0 do
      raise ArgumentError, "calibration and held-out example IDs must be disjoint"
    end

    calibrated =
      Enum.map(records, fn record ->
        case calibrate(calibrator, record.raw_confidence) do
          {:ok, value} ->
            %{record | raw_confidence: value}

          {:error, reason} ->
            raise ArgumentError, "held-out calibration unavailable: #{inspect(reason)}"
        end
      end)

    report(calibrated, Keyword.put_new(opts, :bins, calibrator.bins))
  end

  defp reliability_buckets(records, bins) do
    total = length(records)

    Enum.map(0..(bins - 1), fn index ->
      grouped = Enum.filter(records, &(bin_index(&1.raw_confidence, bins) == index))
      count = length(grouped)
      confidence = mean(grouped, & &1.raw_confidence)
      accuracy = mean(grouped, &indicator(&1.correct?))

      %{
        index: index,
        lower: index / bins,
        upper: (index + 1) / bins,
        count: count,
        weight: if(total == 0, do: 0.0, else: count / total),
        mean_confidence: confidence,
        accuracy: accuracy,
        gap: abs(confidence - accuracy)
      }
    end)
  end

  defp abstention(records, threshold) do
    accepted = Enum.filter(records, &(&1.raw_confidence >= threshold))

    %{
      threshold: threshold * 1.0,
      accepted: length(accepted),
      coverage: ratio(length(accepted), length(records)),
      accuracy: mean(accepted, &indicator(&1.correct?)),
      risk: 1.0 - mean(accepted, &indicator(&1.correct?))
    }
  end

  defp prompt_reports(records, bins) do
    records
    |> Enum.reject(&is_nil(Map.get(&1, :prompt)))
    |> Enum.group_by(& &1.prompt)
    |> Map.new(fn {prompt, grouped} ->
      buckets = reliability_buckets(grouped, bins)

      {prompt,
       %{
         sample_count: length(grouped),
         brier_score: mean(grouped, &brier/1),
         ece: Enum.sum(Enum.map(buckets, &(&1.weight * &1.gap))),
         accuracy: mean(grouped, &indicator(&1.correct?)),
         mean_confidence: mean(grouped, & &1.raw_confidence)
       }}
    end)
  end

  defp prompt_drift(records, bins) do
    reports = prompt_reports(records, bins) |> Map.values()

    for left <- reports, right <- reports, left != right, reduce: zero_drift() do
      acc ->
        %{
          brier_delta: max(acc.brier_delta, abs(left.brier_score - right.brier_score)),
          ece_delta: max(acc.ece_delta, abs(left.ece - right.ece)),
          accuracy_delta: max(acc.accuracy_delta, abs(left.accuracy - right.accuracy)),
          mean_confidence_delta:
            max(
              acc.mean_confidence_delta,
              abs(left.mean_confidence - right.mean_confidence)
            )
        }
    end
  end

  defp zero_drift,
    do: %{brier_delta: 0.0, ece_delta: 0.0, accuracy_delta: 0.0, mean_confidence_delta: 0.0}

  defp validate_records!([]), do: raise(ArgumentError, "calibration records must not be empty")

  defp validate_records!(records) do
    Enum.map(records, fn
      %{id: id, raw_confidence: confidence, correct?: correct?} = record
      when not is_nil(id) and is_boolean(correct?) ->
        validate_confidence!(confidence)
        %{record | raw_confidence: confidence * 1.0}

      other ->
        raise ArgumentError, "invalid calibration record: #{inspect(other)}"
    end)
  end

  defp validate_confidence!(value) when is_number(value) and value >= 0 and value <= 1, do: :ok

  defp validate_confidence!(value),
    do: raise(ArgumentError, "raw confidence must be between 0 and 1, got: #{inspect(value)}")

  defp validate_thresholds!(thresholds) when is_list(thresholds) and thresholds != [] do
    Enum.each(thresholds, &validate_confidence!/1)
  end

  defp validate_thresholds!(value),
    do:
      raise(
        ArgumentError,
        "abstention thresholds must be a non-empty list, got: #{inspect(value)}"
      )

  defp positive_integer!(value, _name) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, name),
    do: raise(ArgumentError, "#{name} must be positive, got: #{inspect(value)}")

  defp bin_index(confidence, bins), do: min(trunc(confidence * bins), bins - 1)
  defp brier(record), do: :math.pow(record.raw_confidence - indicator(record.correct?), 2)
  defp indicator(true), do: 1.0
  defp indicator(false), do: 0.0
  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
  defp mean([], _fun), do: 0.0
  defp mean(values, fun), do: Enum.sum(Enum.map(values, fun)) / length(values)
end

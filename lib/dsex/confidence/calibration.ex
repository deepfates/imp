defmodule DSEx.Confidence.Calibration do
  @moduledoc """
  Held-out reliability analysis for raw constrained-label confidence.

  Raw token confidence is treated as an uncalibrated score. Histogram fitting
  estimates probability of correctness from a distinct calibration split.
  Evaluation IDs and source IDs must be unique within each split; evaluation,
  source, and optional group identities must be disjoint across splits.

  A fitted histogram exposes class balance, bin occupancy, and its complete
  mapping. All-correct, all-wrong, and single-bin fits are retained for
  diagnostics but marked non-authoritative and cannot calibrate held-out data.
  """

  @default_thresholds [0.0, 0.5, 0.7, 0.8, 0.9, 0.95, 0.99]

  defmodule Histogram do
    @moduledoc false
    @enforce_keys [
      :bins,
      :min_bin_size,
      :estimates,
      :calibration_ids,
      :calibration_source_ids,
      :calibration_group_ids,
      :fit
    ]
    defstruct @enforce_keys
  end

  @type record :: %{
          required(:id) => term(),
          required(:source_id) => term(),
          required(:raw_confidence) => number(),
          required(:correct?) => boolean(),
          optional(:group_id) => term(),
          optional(:prompt) => term()
        }

  @doc "Computes Brier score, ECE, reliability buckets, abstention, and prompt drift."
  def report(records, opts \\ []) when is_list(records) do
    bins = positive_integer!(Keyword.get(opts, :bins, 10), :bins)
    thresholds = Keyword.get(opts, :abstention_thresholds, @default_thresholds)
    records = validate_records!(records, "evaluation")
    validate_thresholds!(thresholds)

    buckets = reliability_buckets(records, bins)

    %{
      sample_count: length(records),
      class_balance: class_balance(records),
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

  @doc "Fits fixed-width histogram calibration on uniquely identified sources."
  def fit_histogram(records, opts \\ []) when is_list(records) do
    bins = positive_integer!(Keyword.get(opts, :bins, 10), :bins)
    min_bin_size = positive_integer!(Keyword.get(opts, :min_bin_size, 2), :min_bin_size)
    records = validate_records!(records, "calibration")
    estimates = histogram_estimates(records, bins, min_bin_size)
    fit = fit_diagnostics(records, estimates, bins)

    %Histogram{
      bins: bins,
      min_bin_size: min_bin_size,
      estimates: Map.new(estimates, &{&1.index, Map.drop(&1, [:index, :lower, :upper])}),
      calibration_ids: identity_set(records, :id),
      calibration_source_ids: identity_set(records, :source_id),
      calibration_group_ids: group_ids(records),
      fit: fit
    }
  end

  @doc "Returns a deterministic, JSON-safe description of a fitted histogram."
  def histogram_summary(%Histogram{} = calibrator) do
    %{
      schema_version: 1,
      method: "fixed-width histogram empirical correctness",
      bins: calibrator.bins,
      min_bin_size: calibrator.min_bin_size,
      authoritative?: calibrator.fit.authoritative?,
      non_authoritative_reasons: calibrator.fit.non_authoritative_reasons,
      sample_count: calibrator.fit.sample_count,
      class_balance: calibrator.fit.class_balance,
      occupied_bin_count: calibrator.fit.occupied_bin_count,
      supported_bin_count: calibrator.fit.supported_bin_count,
      mapping: histogram_mapping(calibrator)
    }
  end

  @doc "Whether a fit has mixed outcomes and at least two supported bins."
  def authoritative?(%Histogram{fit: %{authoritative?: authoritative?}}), do: authoritative?

  @doc "Maps one raw score to held-out empirical probability of correctness."
  def calibrate(%Histogram{} = calibrator, raw_confidence) do
    validate_confidence!(raw_confidence)

    if authoritative?(calibrator) do
      index = bin_index(raw_confidence, calibrator.bins)

      case calibrator.estimates[index] do
        %{probability_correct: value} when is_number(value) -> {:ok, value}
        _ -> {:error, {:unsupported_calibration_bin, index}}
      end
    else
      {:error, {:non_authoritative_calibration, calibrator.fit.non_authoritative_reasons}}
    end
  end

  @doc "Evaluates an authoritative histogram on identity-disjoint held-out sources."
  def evaluate_histogram(%Histogram{} = calibrator, records, opts \\ []) do
    records = validate_records!(records, "held-out")
    validate_disjoint!(calibrator, records)

    unless authoritative?(calibrator) do
      raise ArgumentError,
            "calibration fit is non-authoritative: " <>
              inspect(calibrator.fit.non_authoritative_reasons)
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

  defp histogram_estimates(records, bins, min_bin_size) do
    grouped = Enum.group_by(records, &bin_index(&1.raw_confidence, bins))

    Enum.map(0..(bins - 1), fn index ->
      records_in_bin = Map.get(grouped, index, [])
      count = length(records_in_bin)
      correct = Enum.count(records_in_bin, & &1.correct?)

      %{
        index: index,
        lower: index / bins,
        upper: (index + 1) / bins,
        count: count,
        correct: correct,
        incorrect: count - correct,
        supported?: count >= min_bin_size,
        probability_correct: if(count >= min_bin_size, do: ratio(correct, count))
      }
    end)
  end

  defp fit_diagnostics(records, estimates, bins) do
    balance = class_balance(records)
    occupied = Enum.count(estimates, &(&1.count > 0))
    supported = Enum.count(estimates, & &1.supported?)

    reasons =
      []
      |> maybe_reason(balance.incorrect == 0, :all_correct)
      |> maybe_reason(balance.correct == 0, :all_wrong)
      |> maybe_reason(bins == 1, :single_bin_fit)
      |> maybe_reason(occupied < 2, :single_occupied_bin)
      |> maybe_reason(supported < 2, :fewer_than_two_supported_bins)

    %{
      authoritative?: reasons == [],
      non_authoritative_reasons: reasons,
      sample_count: length(records),
      class_balance: balance,
      occupied_bin_count: occupied,
      supported_bin_count: supported,
      bin_occupancy: estimates
    }
  end

  defp histogram_mapping(calibrator) do
    Enum.map(0..(calibrator.bins - 1), fn index ->
      estimate = Map.fetch!(calibrator.estimates, index)

      Map.merge(estimate, %{
        index: index,
        lower: index / calibrator.bins,
        upper: (index + 1) / calibrator.bins
      })
    end)
  end

  defp validate_disjoint!(calibrator, records) do
    overlaps = [
      evaluation_ids: intersection(calibrator.calibration_ids, identity_set(records, :id)),
      source_ids:
        intersection(calibrator.calibration_source_ids, identity_set(records, :source_id)),
      group_ids: intersection(calibrator.calibration_group_ids, group_ids(records))
    ]

    case Enum.reject(overlaps, fn {_kind, values} -> values == [] end) do
      [] ->
        :ok

      found ->
        raise ArgumentError,
              "calibration and held-out evaluation/source/group identities must be disjoint: " <>
                inspect(found)
    end
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
         class_balance: class_balance(grouped),
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

  defp validate_records!([], split),
    do: raise(ArgumentError, "#{split} records must not be empty")

  defp validate_records!(records, split) do
    validated =
      Enum.map(records, fn
        %{id: id, source_id: source_id, raw_confidence: confidence, correct?: correct?} = record
        when not is_nil(id) and not is_nil(source_id) and is_boolean(correct?) ->
          validate_confidence!(confidence)
          %{record | raw_confidence: confidence * 1.0}

        other ->
          raise ArgumentError, "invalid #{split} record: #{inspect(other)}"
      end)

    validate_unique!(validated, :id, "#{split} evaluation IDs")
    validate_unique!(validated, :source_id, "#{split} source IDs")
    validated
  end

  defp validate_unique!(records, key, label) do
    values = Enum.map(records, &Map.fetch!(&1, key))

    if length(values) != MapSet.size(MapSet.new(values)) do
      raise ArgumentError, "#{label} must be unique"
    end
  end

  defp class_balance(records) do
    correct = Enum.count(records, & &1.correct?)
    %{correct: correct, incorrect: length(records) - correct}
  end

  defp identity_set(records, key), do: MapSet.new(records, &Map.fetch!(&1, key))

  defp group_ids(records) do
    records
    |> Enum.map(&Map.get(&1, :group_id))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp intersection(left, right) do
    left
    |> MapSet.intersection(right)
    |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic]))
  end

  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons

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

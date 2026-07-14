defmodule Imp.Optimizer.GEPA.ComBee.BatchController do
  @moduledoc """
  Runtime trial profiling and offline measurement fitting for ComBee batches.

  Runtime mode records one synchronized GEPA iteration for each candidate batch
  size. Offline mode fits explicitly supplied measurements without performing
  optimizer work. Both modes use the paper's epoch-delay power law and plateau
  equation; the candidate schedule and safety cap are Imp runtime policies.
  """

  @default_max_batch_size 200
  @default_slope_threshold_ratio 0.016

  defmodule Options do
    @moduledoc "Options for runtime ComBee profiling or an offline delay fit."

    defstruct mode: :runtime,
              measurements: [],
              candidate_batch_sizes: nil,
              min_batch_size: 1,
              max_batch_size: 200,
              slope_threshold_ratio: 0.016,
              profiling_timeout: :infinity

    @type t :: %__MODULE__{
            mode: :runtime | :offline_measurements,
            measurements: [{pos_integer(), number()}],
            candidate_batch_sizes: [pos_integer()] | nil,
            min_batch_size: pos_integer(),
            max_batch_size: pos_integer(),
            slope_threshold_ratio: float(),
            profiling_timeout: timeout()
          }
  end

  defmodule Trial do
    @moduledoc "One completed synchronized runtime trial."
    defstruct [
      :status,
      :reason,
      :index,
      :iteration,
      :batch_size,
      :delay_ms,
      :metric_calls,
      :reflection_calls
    ]
  end

  defmodule Report do
    @moduledoc "Checkpoint-identifiable runtime profile or offline fit result."

    defstruct [
      :status,
      :reason,
      :mode,
      :measurement_source,
      :trainset_size,
      :candidate_batch_sizes,
      :measurements,
      :epoch_times,
      :trials,
      :current_trial,
      :elapsed_ms,
      :metric_calls,
      :reflection_calls,
      :a,
      :alpha,
      :peak_slope,
      :tau,
      :plateau_batch_size,
      :selected_batch_size,
      :safety_range,
      :slope_threshold_ratio,
      :profiling_timeout,
      :identity
    ]
  end

  @doc "Returns the Imp hard safety cap for controller-selected batches."
  def max_safe_batch_size, do: @default_max_batch_size

  @doc "Validates and normalizes controller options."
  def options!(%Options{} = options), do: validate_options!(options)

  def options!(options) when is_list(options) do
    allowed = [
      :mode,
      :measurements,
      :candidate_batch_sizes,
      :min_batch_size,
      :max_batch_size,
      :slope_threshold_ratio,
      :profiling_timeout
    ]

    case Keyword.keys(options) -- allowed do
      [] ->
        measurements = Keyword.get(options, :measurements, [])

        mode =
          Keyword.get(
            options,
            :mode,
            if(measurements == [], do: :runtime, else: :offline_measurements)
          )

        %Options{
          mode: mode,
          measurements: measurements,
          candidate_batch_sizes: Keyword.get(options, :candidate_batch_sizes),
          min_batch_size: Keyword.get(options, :min_batch_size, 1),
          max_batch_size: Keyword.get(options, :max_batch_size, @default_max_batch_size),
          slope_threshold_ratio:
            Keyword.get(options, :slope_threshold_ratio, @default_slope_threshold_ratio),
          profiling_timeout: Keyword.get(options, :profiling_timeout, :infinity)
        }
        |> validate_options!()

      unknown ->
        raise ArgumentError,
              "unknown ComBee batch controller options: #{inspect(Enum.sort(unknown))}"
    end
  end

  def options!(value) do
    raise ArgumentError,
          "ComBee batch controller options must be a keyword list, got: #{inspect(value)}"
  end

  @doc "Creates a pending runtime profile with a deterministic candidate schedule."
  def new_profile(options, trainset_size) when is_integer(trainset_size) and trainset_size > 0 do
    options = options!(options)

    unless options.mode == :runtime do
      raise ArgumentError, "ComBee new_profile/2 requires :runtime mode"
    end

    {safe_min, safe_max} = effective_safety_range(options, trainset_size)
    candidates = runtime_candidates(options, safe_min, safe_max)

    report = %Report{
      status: :pending,
      mode: :runtime,
      measurement_source: :runtime_trials,
      trainset_size: trainset_size,
      candidate_batch_sizes: candidates,
      measurements: [],
      epoch_times: [],
      trials: [],
      current_trial: nil,
      elapsed_ms: 0.0,
      metric_calls: 0,
      reflection_calls: 0,
      selected_batch_size: safe_min,
      safety_range: {safe_min, safe_max},
      slope_threshold_ratio: options.slope_threshold_ratio,
      profiling_timeout: options.profiling_timeout
    }

    put_identity(report)
  end

  @doc "Marks the next runtime trial started before provider work is dispatched."
  def start_trial(%Report{mode: :runtime, status: status} = report, iteration)
      when status in [:pending, :profiling] and is_integer(iteration) and iteration > 0 do
    index = length(report.trials)
    batch_size = Enum.fetch!(report.candidate_batch_sizes, index)

    report
    |> Map.merge(%{
      status: :started,
      current_trial: %{index: index, iteration: iteration, batch_size: batch_size}
    })
    |> put_identity()
  end

  @doc "Completes a started trial, preserving candidate order and fitting after the final trial."
  def complete_trial(
        %Report{mode: :runtime, status: :started, current_trial: current} = report,
        delay_ms,
        metric_calls,
        reflection_calls
      )
      when is_number(delay_ms) and delay_ms > 0 and is_integer(metric_calls) and
             metric_calls >= 0 and is_integer(reflection_calls) and reflection_calls >= 0 do
    unless current.index == length(report.trials) do
      raise ArgumentError, "ComBee runtime trial order mismatch"
    end

    trial = %Trial{
      status: :ok,
      index: current.index,
      iteration: current.iteration,
      batch_size: current.batch_size,
      delay_ms: delay_ms * 1.0,
      metric_calls: metric_calls,
      reflection_calls: reflection_calls
    }

    report = %{
      report
      | status: :profiling,
        current_trial: nil,
        trials: report.trials ++ [trial],
        measurements: report.measurements ++ [{trial.batch_size, trial.delay_ms}],
        elapsed_ms: report.elapsed_ms + trial.delay_ms,
        metric_calls: report.metric_calls + metric_calls,
        reflection_calls: report.reflection_calls + reflection_calls
    }

    if length(report.trials) == length(report.candidate_batch_sizes),
      do: fit(report),
      else: put_identity(report)
  end

  def complete_trial(%Report{}, _delay_ms, _metric_calls, _reflection_calls) do
    raise ArgumentError, "ComBee runtime trial is not started"
  end

  @doc "Records a cleanly observed failed trial without admitting it to the delay fit."
  def abort_trial(
        %Report{mode: :runtime, status: :started, current_trial: current} = report,
        delay_ms,
        metric_calls,
        reflection_calls,
        reason
      )
      when is_number(delay_ms) and delay_ms >= 0 and is_integer(metric_calls) and
             metric_calls >= 0 and is_integer(reflection_calls) and reflection_calls >= 0 do
    trial = %Trial{
      status: :error,
      reason: reason,
      index: current.index,
      iteration: current.iteration,
      batch_size: current.batch_size,
      delay_ms: delay_ms * 1.0,
      metric_calls: metric_calls,
      reflection_calls: reflection_calls
    }

    report
    |> Map.merge(%{
      status: :incomplete,
      reason: reason,
      current_trial: nil,
      trials: report.trials ++ [trial],
      elapsed_ms: report.elapsed_ms + trial.delay_ms,
      metric_calls: report.metric_calls + metric_calls,
      reflection_calls: report.reflection_calls + reflection_calls
    })
    |> put_identity()
  end

  @doc "Marks a non-ambiguous profiling stop without selecting an unmeasured batch."
  def stop(%Report{mode: :runtime} = report, reason) do
    report
    |> Map.merge(%{status: :incomplete, reason: reason, current_trial: nil})
    |> put_identity()
  end

  @doc "Returns the next candidate batch or nil after profiling finishes."
  def next_batch_size(%Report{mode: :runtime, status: status} = report)
      when status in [:pending, :profiling] do
    Enum.at(report.candidate_batch_sizes, length(report.trials))
  end

  def next_batch_size(%Report{}), do: nil

  @doc "Fits explicitly supplied measurements without running optimizer trials."
  def select(options, trainset_size) when is_integer(trainset_size) and trainset_size > 0 do
    options = options!(options)

    unless options.mode == :offline_measurements and options.measurements != [] do
      raise ArgumentError,
            "ComBee offline measurement fitting requires :mode => :offline_measurements " <>
              "and caller-supplied :measurements"
    end

    {safe_min, safe_max} = effective_safety_range(options, trainset_size)

    %Report{
      status: :pending,
      mode: :offline_measurements,
      measurement_source: :caller_supplied,
      trainset_size: trainset_size,
      candidate_batch_sizes: [],
      measurements: Enum.map(options.measurements, fn {size, delay} -> {size, delay * 1.0} end),
      epoch_times: [],
      trials: [],
      current_trial: nil,
      elapsed_ms: 0.0,
      metric_calls: 0,
      reflection_calls: 0,
      selected_batch_size: safe_min,
      safety_range: {safe_min, safe_max},
      slope_threshold_ratio: options.slope_threshold_ratio,
      profiling_timeout: :infinity
    }
    |> fit()
  end

  def select(_options, trainset_size) do
    raise ArgumentError,
          "ComBee trainset size must be a positive integer, got: #{inspect(trainset_size)}"
  end

  @doc false
  def validate_report!(%Report{} = report) do
    expected = identity_payload(report) |> identity()

    unless secure_equal?(report.identity, expected) do
      raise ArgumentError, "ComBee batch controller report identity mismatch"
    end

    report
  end

  @doc false
  def load_report!(%Report{identity: nil, measurement_source: :caller_supplied} = report) do
    report
    |> Map.merge(%{
      mode: :offline_measurements,
      candidate_batch_sizes: [],
      trials: [],
      current_trial: nil,
      elapsed_ms: 0.0,
      metric_calls: 0,
      reflection_calls: 0,
      profiling_timeout: :infinity
    })
    |> put_identity()
  end

  def load_report!(%Report{} = report), do: validate_report!(report)

  defp fit(report) do
    {safe_min, safe_max} = report.safety_range

    epoch_times =
      Enum.map(report.measurements, fn {size, delay} ->
        {size, delay * report.trainset_size / size}
      end)

    report = %{report | epoch_times: epoch_times}

    with :ok <- measurements_in_range(report.measurements, safe_min, safe_max),
         {:ok, a, alpha} <- fit_positive_power_law(epoch_times),
         {:ok, peak_slope, tau, plateau} <-
           plateau(a, alpha, safe_min, report.slope_threshold_ratio) do
      selected = plateau |> floor() |> clamp(safe_min, safe_max)

      report
      |> Map.merge(%{
        status: :ok,
        reason: nil,
        a: a,
        alpha: alpha,
        peak_slope: peak_slope,
        tau: tau,
        plateau_batch_size: plateau,
        selected_batch_size: selected
      })
      |> put_identity()
    else
      {:error, reason} ->
        report
        |> Map.merge(%{status: :degenerate, reason: reason, selected_batch_size: safe_min})
        |> put_identity()
    end
  rescue
    ArithmeticError ->
      report
      |> Map.merge(%{
        status: :degenerate,
        reason: :non_finite_fit,
        selected_batch_size: elem(report.safety_range, 0)
      })
      |> put_identity()
  end

  defp validate_options!(%Options{} = options) do
    unless options.mode in [:runtime, :offline_measurements] do
      raise ArgumentError,
            "ComBee batch controller :mode must be :runtime or :offline_measurements"
    end

    unless is_list(options.measurements) and
             Enum.all?(options.measurements, &valid_measurement?/1) do
      raise ArgumentError,
            "ComBee measurements must be {positive batch size, positive delay} tuples"
    end

    if options.mode == :runtime and options.measurements != [] do
      raise ArgumentError, "ComBee runtime profiling does not accept offline :measurements"
    end

    if options.mode == :offline_measurements and options.candidate_batch_sizes != nil do
      raise ArgumentError,
            "ComBee offline measurement mode does not accept :candidate_batch_sizes"
    end

    unless is_nil(options.candidate_batch_sizes) or
             (is_list(options.candidate_batch_sizes) and options.candidate_batch_sizes != [] and
                Enum.all?(options.candidate_batch_sizes, &(is_integer(&1) and &1 > 0)) and
                options.candidate_batch_sizes ==
                  Enum.sort(Enum.uniq(options.candidate_batch_sizes))) do
      raise ArgumentError,
            "ComBee :candidate_batch_sizes must be a non-empty strictly increasing integer list"
    end

    unless is_integer(options.min_batch_size) and options.min_batch_size > 0 do
      raise ArgumentError, "ComBee :min_batch_size must be a positive integer"
    end

    unless is_integer(options.max_batch_size) and
             options.max_batch_size >= options.min_batch_size and
             options.max_batch_size <= @default_max_batch_size do
      raise ArgumentError,
            "ComBee :max_batch_size must be between :min_batch_size and #{@default_max_batch_size}"
    end

    unless is_number(options.slope_threshold_ratio) and options.slope_threshold_ratio > 0 and
             options.slope_threshold_ratio < 1 do
      raise ArgumentError,
            "ComBee :slope_threshold_ratio must be greater than 0 and less than 1"
    end

    unless options.profiling_timeout == :infinity or
             (is_integer(options.profiling_timeout) and options.profiling_timeout > 0) do
      raise ArgumentError,
            "ComBee :profiling_timeout must be :infinity or a positive integer"
    end

    %{options | slope_threshold_ratio: options.slope_threshold_ratio * 1.0}
  end

  defp runtime_candidates(%Options{candidate_batch_sizes: nil}, safe_min, safe_max) do
    [safe_min, min(safe_min * 2, safe_max), min(safe_min * 4, safe_max)]
    |> Enum.uniq()
  end

  defp runtime_candidates(%Options{candidate_batch_sizes: candidates}, safe_min, safe_max) do
    if Enum.any?(candidates, &(&1 < safe_min or &1 > safe_max)) do
      raise ArgumentError, "ComBee runtime candidate batch is outside the safety range"
    end

    candidates
  end

  defp valid_measurement?({size, delay}),
    do: is_integer(size) and size > 0 and is_number(delay) and delay > 0

  defp valid_measurement?(_measurement), do: false

  defp effective_safety_range(options, trainset_size) do
    safe_max = min(options.max_batch_size, trainset_size)
    safe_min = min(options.min_batch_size, safe_max)
    {safe_min, safe_max}
  end

  defp measurements_in_range(measurements, safe_min, safe_max) do
    cond do
      length(measurements) < 2 ->
        {:error, :insufficient_measurements}

      Enum.any?(measurements, fn {size, _delay} -> size < safe_min or size > safe_max end) ->
        {:error, :measurement_outside_safety_range}

      true ->
        :ok
    end
  end

  defp fit_positive_power_law(epoch_times) do
    points = Enum.map(epoch_times, fn {size, time} -> {:math.log(size), :math.log(time)} end)
    count = length(points)
    x_mean = Enum.sum(Enum.map(points, &elem(&1, 0))) / count
    y_mean = Enum.sum(Enum.map(points, &elem(&1, 1))) / count

    {covariance, variance} =
      Enum.reduce(points, {0.0, 0.0}, fn {x, y}, {covariance, variance} ->
        dx = x - x_mean
        {covariance + dx * (y - y_mean), variance + dx * dx}
      end)

    if variance <= 0 do
      {:error, :duplicate_batch_sizes}
    else
      alpha = -(covariance / variance)
      a = :math.exp(y_mean + alpha * x_mean)

      if alpha > 0 and finite_positive?(a) and finite_positive?(alpha),
        do: {:ok, a, alpha},
        else: {:error, :non_decreasing_power_law}
    end
  end

  defp plateau(a, alpha, safe_min, ratio) do
    peak_slope = alpha * a * :math.pow(safe_min, -(alpha + 1.0))
    tau = ratio * peak_slope
    plateau = :math.pow(alpha * a / tau, 1.0 / (alpha + 1.0))

    if Enum.all?([peak_slope, tau, plateau], &finite_positive?/1),
      do: {:ok, peak_slope, tau, plateau},
      else: {:error, :non_finite_fit}
  end

  defp put_identity(report), do: %{report | identity: report |> identity_payload() |> identity()}
  defp identity_payload(report), do: report |> Map.from_struct() |> Map.delete(:identity)

  defp identity(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_, _), do: false
  defp finite_positive?(value), do: is_float(value) and value > 0
  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)
end

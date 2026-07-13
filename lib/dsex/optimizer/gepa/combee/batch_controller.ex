defmodule DSEx.Optimizer.GEPA.ComBee.BatchController do
  @moduledoc """
  Fits ComBee's positive power-law epoch-delay model from measured batches.

  Every measurement is `{batch_size, observed_delay}`. The controller converts
  delay to estimated epoch time with `delay * trainset_size / batch_size`, fits
  `T = A * batch_size^-alpha` in log space, and applies the paper's plateau
  formula. Invalid or non-decreasing fits fail closed to the smallest safe batch
  and return an explicit `:degenerate` report.
  """

  @default_max_batch_size 200
  @default_slope_threshold_ratio 0.016

  defmodule Options do
    @moduledoc "Options for measured ComBee batch-size selection."

    defstruct measurements: [],
              min_batch_size: 1,
              max_batch_size: 200,
              slope_threshold_ratio: 0.016

    @type measurement :: {pos_integer(), number()}
    @type t :: %__MODULE__{
            measurements: [measurement()],
            min_batch_size: pos_integer(),
            max_batch_size: pos_integer(),
            slope_threshold_ratio: float()
          }
  end

  defmodule Report do
    @moduledoc "Result of a measured ComBee batch-size fit."

    defstruct [
      :status,
      :reason,
      :trainset_size,
      :measurements,
      :epoch_times,
      :a,
      :alpha,
      :peak_slope,
      :tau,
      :plateau_batch_size,
      :selected_batch_size,
      :safety_range,
      :slope_threshold_ratio
    ]

    @type status :: :ok | :degenerate
    @type t :: %__MODULE__{
            status: status(),
            reason: atom() | nil,
            trainset_size: pos_integer(),
            measurements: [{pos_integer(), float()}],
            epoch_times: [{pos_integer(), float()}],
            a: float() | nil,
            alpha: float() | nil,
            peak_slope: float() | nil,
            tau: float() | nil,
            plateau_batch_size: float() | nil,
            selected_batch_size: pos_integer(),
            safety_range: {pos_integer(), pos_integer()},
            slope_threshold_ratio: float()
          }
  end

  @doc "Returns the DSEx hard safety cap for controller-selected batches."
  @spec max_safe_batch_size() :: pos_integer()
  def max_safe_batch_size, do: @default_max_batch_size

  @doc "Validates and normalizes controller options."
  @spec options!(keyword() | Options.t()) :: Options.t()
  def options!(%Options{} = options), do: validate_options!(options)

  def options!(options) when is_list(options) do
    allowed = [
      :measurements,
      :min_batch_size,
      :max_batch_size,
      :slope_threshold_ratio
    ]

    case Keyword.keys(options) -- allowed do
      [] ->
        %Options{
          measurements: Keyword.get(options, :measurements, []),
          min_batch_size: Keyword.get(options, :min_batch_size, 1),
          max_batch_size: Keyword.get(options, :max_batch_size, @default_max_batch_size),
          slope_threshold_ratio:
            Keyword.get(
              options,
              :slope_threshold_ratio,
              @default_slope_threshold_ratio
            )
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

  @doc "Fits measured delay and selects a batch inside the configured safety range."
  @spec select(Options.t() | keyword(), pos_integer()) :: Report.t()
  def select(options, trainset_size) when is_integer(trainset_size) and trainset_size > 0 do
    options = options!(options)
    {safe_min, safe_max} = effective_safety_range(options, trainset_size)
    measurements = Enum.map(options.measurements, fn {size, delay} -> {size, delay * 1.0} end)

    epoch_times =
      Enum.map(measurements, fn {size, delay} ->
        {size, delay * trainset_size / size}
      end)

    base = %Report{
      trainset_size: trainset_size,
      measurements: measurements,
      epoch_times: epoch_times,
      selected_batch_size: safe_min,
      safety_range: {safe_min, safe_max},
      slope_threshold_ratio: options.slope_threshold_ratio
    }

    with :ok <- measurements_in_range(measurements, safe_min, safe_max),
         {:ok, a, alpha} <- fit_positive_power_law(epoch_times),
         {:ok, peak_slope, tau, plateau} <-
           plateau(a, alpha, safe_min, options.slope_threshold_ratio) do
      selected = plateau |> floor() |> clamp(safe_min, safe_max)

      %Report{
        base
        | status: :ok,
          a: a,
          alpha: alpha,
          peak_slope: peak_slope,
          tau: tau,
          plateau_batch_size: plateau,
          selected_batch_size: selected
      }
    else
      {:error, reason} -> %Report{base | status: :degenerate, reason: reason}
    end
  rescue
    ArithmeticError ->
      degenerate_report(options, trainset_size, :non_finite_fit)
  end

  def select(_options, trainset_size) do
    raise ArgumentError,
          "ComBee trainset size must be a positive integer, got: #{inspect(trainset_size)}"
  end

  defp validate_options!(%Options{} = options) do
    unless is_list(options.measurements) and
             Enum.all?(options.measurements, &valid_measurement?/1) do
      raise ArgumentError,
            "ComBee measurements must be {positive batch size, positive delay} tuples"
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

    unless is_number(options.slope_threshold_ratio) and
             options.slope_threshold_ratio > 0 and options.slope_threshold_ratio < 1 do
      raise ArgumentError,
            "ComBee :slope_threshold_ratio must be greater than 0 and less than 1"
    end

    %{options | slope_threshold_ratio: options.slope_threshold_ratio * 1.0}
  end

  defp valid_measurement?({size, delay}) do
    is_integer(size) and size > 0 and is_number(delay) and delay > 0
  end

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

  defp finite_positive?(value), do: is_float(value) and value > 0

  defp degenerate_report(options, trainset_size, reason) do
    {safe_min, safe_max} = effective_safety_range(options, trainset_size)
    measurements = Enum.map(options.measurements, fn {size, delay} -> {size, delay * 1.0} end)

    %Report{
      status: :degenerate,
      reason: reason,
      trainset_size: trainset_size,
      measurements: measurements,
      epoch_times: [],
      selected_batch_size: safe_min,
      safety_range: {safe_min, safe_max},
      slope_threshold_ratio: options.slope_threshold_ratio
    }
  end

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)
end

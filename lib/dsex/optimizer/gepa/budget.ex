defmodule DSEx.Optimizer.GEPA.Budget do
  @moduledoc false

  @enforce_keys [:max_metric_calls, :max_full_evaluations, :max_reflection_calls]
  defstruct max_metric_calls: :infinity,
            max_full_evaluations: :infinity,
            max_reflection_calls: :infinity,
            metric_calls: 0,
            full_evaluations: 0,
            reflection_calls: 0

  @type limit :: non_neg_integer() | :infinity
  @type t :: %__MODULE__{
          max_metric_calls: limit(),
          max_full_evaluations: limit(),
          max_reflection_calls: limit(),
          metric_calls: non_neg_integer(),
          full_evaluations: non_neg_integer(),
          reflection_calls: non_neg_integer()
        }

  @type exhaustion ::
          {:budget_exhausted, :metric_calls | :full_evaluations | :reflection_calls,
           non_neg_integer(), limit()}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_metric_calls:
        limit!(Keyword.get(opts, :max_metric_calls, :infinity), :max_metric_calls),
      max_full_evaluations:
        limit!(Keyword.get(opts, :max_full_evaluations, :infinity), :max_full_evaluations),
      max_reflection_calls:
        limit!(Keyword.get(opts, :max_reflection_calls, :infinity), :max_reflection_calls)
    }
  end

  @doc "Checks capacity for an evaluation without claiming that calls have occurred."
  @spec authorize_evaluation(t(), non_neg_integer(), :full | :minibatch) ::
          :ok | {:error, exhaustion()}
  def authorize_evaluation(%__MODULE__{} = budget, maximum_calls, kind \\ :full)
      when is_integer(maximum_calls) and maximum_calls >= 0 and kind in [:full, :minibatch] do
    full_increment = if kind == :full, do: 1, else: 0

    with :ok <-
           available(budget.metric_calls, maximum_calls, budget.max_metric_calls, :metric_calls),
         :ok <-
           available(
             budget.full_evaluations,
             full_increment,
             budget.max_full_evaluations,
             :full_evaluations
           ),
         do: :ok
  end

  @doc "Commits adapter-reported metric calls after an authorized evaluation completes."
  @spec record_evaluation(t(), non_neg_integer(), :full | :minibatch) ::
          {:ok, t()} | {:error, exhaustion(), t()}
  def record_evaluation(%__MODULE__{} = budget, actual_calls, kind \\ :full)
      when is_integer(actual_calls) and actual_calls >= 0 and kind in [:full, :minibatch] do
    case authorize_evaluation(budget, actual_calls, kind) do
      :ok ->
        {:ok,
         %{
           budget
           | metric_calls: budget.metric_calls + actual_calls,
             full_evaluations: budget.full_evaluations + if(kind == :full, do: 1, else: 0)
         }}

      {:error, reason} ->
        {:error, reason, budget}
    end
  end

  @doc "Records an observed reflection-model invocation."
  @spec record_reflection(t()) :: t()
  def record_reflection(%__MODULE__{} = budget), do: record_reflections(budget, 1)

  @doc "Preauthorizes an exact number of reflection-model invocations."
  @spec authorize_reflections(t(), non_neg_integer()) :: :ok | {:error, exhaustion()}
  def authorize_reflections(%__MODULE__{} = budget, calls)
      when is_integer(calls) and calls >= 0 do
    available(budget.reflection_calls, calls, budget.max_reflection_calls, :reflection_calls)
  end

  @doc "Records an observed number of reflection-model invocations."
  @spec record_reflections(t(), non_neg_integer()) :: t()
  def record_reflections(%__MODULE__{} = budget, calls)
      when is_integer(calls) and calls >= 0 do
    %{budget | reflection_calls: budget.reflection_calls + calls}
  end

  @doc false
  def commit_reserved(%__MODULE__{} = budget, metric_calls, full_evaluations, reflection_calls)
      when is_integer(metric_calls) and metric_calls >= 0 and
             is_integer(full_evaluations) and full_evaluations >= 0 and
             is_integer(reflection_calls) and reflection_calls >= 0 do
    projected = %{
      budget
      | metric_calls: budget.metric_calls + metric_calls,
        full_evaluations: budget.full_evaluations + full_evaluations,
        reflection_calls: budget.reflection_calls + reflection_calls
    }

    ensure_within_limit!(projected.metric_calls, projected.max_metric_calls, :metric_calls)

    ensure_within_limit!(
      projected.full_evaluations,
      projected.max_full_evaluations,
      :full_evaluations
    )

    ensure_within_limit!(
      projected.reflection_calls,
      projected.max_reflection_calls,
      :reflection_calls
    )

    projected
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = budget) do
    %{
      "max_metric_calls" => dump_limit(budget.max_metric_calls),
      "max_full_evaluations" => dump_limit(budget.max_full_evaluations),
      "max_reflection_calls" => dump_limit(budget.max_reflection_calls),
      "metric_calls" => budget.metric_calls,
      "full_evaluations" => budget.full_evaluations,
      "reflection_calls" => budget.reflection_calls
    }
  end

  @spec load!(map()) :: t()
  def load!(state) when is_map(state) do
    budget = %__MODULE__{
      max_metric_calls: state |> fetch!("max_metric_calls") |> load_limit!(:max_metric_calls),
      max_full_evaluations:
        state |> fetch!("max_full_evaluations") |> load_limit!(:max_full_evaluations),
      max_reflection_calls:
        state
        |> Map.get("max_reflection_calls", "infinity")
        |> load_limit!(:max_reflection_calls),
      metric_calls: state |> fetch!("metric_calls") |> count!(:metric_calls),
      full_evaluations: state |> fetch!("full_evaluations") |> count!(:full_evaluations),
      reflection_calls: state |> fetch!("reflection_calls") |> count!(:reflection_calls)
    }

    ensure_within_limit!(budget.metric_calls, budget.max_metric_calls, :metric_calls)
    ensure_within_limit!(budget.full_evaluations, budget.max_full_evaluations, :full_evaluations)
    ensure_within_limit!(budget.reflection_calls, budget.max_reflection_calls, :reflection_calls)
    budget
  end

  def load!(state),
    do: raise(ArgumentError, "GEPA budget state must be a map, got: #{inspect(state)}")

  defp available(_used, _increment, :infinity, _name), do: :ok

  defp available(used, increment, limit, name) do
    if used + increment <= limit,
      do: :ok,
      else: {:error, {:budget_exhausted, name, used + increment, limit}}
  end

  defp limit!(:infinity, _name), do: :infinity
  defp limit!(value, _name) when is_integer(value) and value >= 0, do: value

  defp limit!(value, name) do
    raise ArgumentError,
          "#{name} must be a non-negative integer or :infinity, got: #{inspect(value)}"
  end

  defp load_limit!("infinity", _name), do: :infinity
  defp load_limit!(value, name), do: limit!(value, name)
  defp dump_limit(:infinity), do: "infinity"
  defp dump_limit(value), do: value

  defp count!(value, _name) when is_integer(value) and value >= 0, do: value

  defp count!(value, name) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp ensure_within_limit!(_count, :infinity, _name), do: :ok
  defp ensure_within_limit!(count, limit, _name) when count <= limit, do: :ok

  defp ensure_within_limit!(count, limit, name) do
    raise ArgumentError, "#{name} count #{count} exceeds configured limit #{limit}"
  end

  defp fetch!(state, key) do
    Map.fetch!(state, key)
  rescue
    KeyError ->
      reraise ArgumentError,
              [message: "GEPA budget state is missing #{inspect(key)}"],
              __STACKTRACE__
  end
end

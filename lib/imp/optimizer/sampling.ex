defmodule Imp.Optimizer.Sampling do
  @moduledoc """
  Deterministic sampling helpers for optimizers.

  Every sampling operation accepts and returns explicit `:rand` state so
  optimizer runs remain reproducible without process-global random state.
  """

  @type state :: :rand.state()

  @doc "Serializes an explicit optimizer RNG state into JSON-safe data."
  @spec dump(state()) :: map()
  def dump(state) do
    case :rand.export_seed_s(state) do
      {:exsss, [first | second]} -> %{"algorithm" => "exsss", "words" => [first, second]}
      _other -> raise ArgumentError, "invalid optimizer RNG state"
    end
  end

  @doc "Restores an optimizer RNG state serialized by `dump/1`."
  @spec load!(map()) :: state()
  def load!(%{"algorithm" => "exsss", "words" => [first, second]})
      when is_integer(first) and is_integer(second) and first >= 0 and second >= 0 do
    :rand.seed_s({:exsss, [first | second]})
  end

  def load!(value),
    do: raise(ArgumentError, "invalid optimizer RNG checkpoint: #{inspect(value)}")

  @spec new(integer()) :: state()
  def new(seed) when is_integer(seed) do
    seed = abs(seed) + 1
    :rand.seed_s(:exsss, {seed, seed * 2 + 1, seed * 3 + 2})
  end

  @spec uniform(state()) :: {float(), state()}
  def uniform(state), do: :rand.uniform_s(state)

  @spec integer(pos_integer(), state()) :: {non_neg_integer(), state()}
  def integer(count, state) when is_integer(count) and count > 0 do
    {value, state} = :rand.uniform_s(count, state)
    {value - 1, state}
  end

  @spec choose([value], state()) :: {value, state()} when value: var
  def choose([], _state), do: raise(ArgumentError, "cannot choose from an empty collection")

  def choose(values, state) when is_list(values) do
    {index, state} = integer(length(values), state)
    {Enum.at(values, index), state}
  end

  @spec shuffle([value], state()) :: {[value], state()} when value: var
  def shuffle(values, state) when is_list(values) do
    values
    |> Enum.reduce({[], state}, fn value, {tagged, state} ->
      {tag, state} = uniform(state)
      {[{tag, value} | tagged], state}
    end)
    |> then(fn {tagged, state} ->
      {tagged |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), state}
    end)
  end

  @spec softmax_choose([{value, number()}], number(), state()) :: {value, state()}
        when value: var
  def softmax_choose([], _temperature, _state),
    do: raise(ArgumentError, "cannot sample an empty scored collection")

  def softmax_choose(scored, temperature, state) when temperature > 0 do
    max_score = scored |> Enum.map(&elem(&1, 1)) |> Enum.max()

    weighted =
      Enum.map(scored, fn {value, score} ->
        {value, :math.exp((score - max_score) / temperature)}
      end)

    total = Enum.sum(Enum.map(weighted, &elem(&1, 1)))
    {draw, state} = uniform(state)
    {weighted_pick(weighted, draw * total), state}
  end

  @spec percentile([number()], number()) :: float()
  def percentile([], _percentile), do: 0.0

  def percentile(values, percentile) when percentile >= 0 and percentile <= 100 do
    sorted = Enum.sort(values)
    rank = percentile / 100 * (length(sorted) - 1)
    lower = floor(rank)
    upper = ceil(rank)
    lower_value = Enum.at(sorted, lower)
    upper_value = Enum.at(sorted, upper)
    lower_value + (upper_value - lower_value) * (rank - lower)
  end

  @spec poisson(number(), state()) :: {non_neg_integer(), state()}
  def poisson(lambda, state) when is_number(lambda) and lambda >= 0 do
    if lambda == 0 do
      {0, state}
    else
      poisson_loop(:math.exp(-lambda), 1.0, 0, state)
    end
  end

  defp weighted_pick([{value, _weight}], _draw), do: value

  defp weighted_pick([{value, weight} | rest], draw) do
    if draw <= weight, do: value, else: weighted_pick(rest, draw - weight)
  end

  defp poisson_loop(limit, product, count, state) do
    {draw, state} = uniform(state)
    product = product * draw

    if product <= limit,
      do: {count, state},
      else: poisson_loop(limit, product, count + 1, state)
  end
end

defmodule Imp.Optimizer.SearchPolicy.Sampling do
  @moduledoc false
  @behaviour Imp.Optimizer.SearchPolicy

  alias Imp.Optimizer.Sampling

  @impl true
  def id, do: "sampling"

  @impl true
  def new(opts) do
    case Keyword.get(opts, :rng) do
      nil -> Sampling.new(Keyword.get(opts, :seed, 0))
      rng -> rng
    end
  end

  @impl true
  def suggest(state, {:choose, values}), do: Sampling.choose(values, state)
  def suggest(state, {:integer, count}), do: Sampling.integer(count, state)
  def suggest(state, {:shuffle, values}), do: Sampling.shuffle(values, state)

  def suggest(state, {:softmax, scored, temperature}),
    do: Sampling.softmax_choose(scored, temperature, state)

  def suggest(_state, context),
    do: raise(ArgumentError, "invalid sampling policy context: #{inspect(context)}")

  @impl true
  def observe(state, :noop), do: state

  def observe(_state, observation),
    do:
      raise(ArgumentError, "sampling policy does not accept observation: #{inspect(observation)}")

  @impl true
  def dump(state), do: %{"rng" => Sampling.dump(state)}

  @impl true
  def load!(%{"rng" => rng}), do: Sampling.load!(rng)

  def load!(value),
    do: raise(ArgumentError, "invalid sampling policy checkpoint: #{inspect(value)}")
end

defmodule DSEx.Optimizer.SearchPolicy.CategoricalTPE do
  @moduledoc false
  @behaviour DSEx.Optimizer.SearchPolicy

  alias DSEx.Optimizer.{CategoricalTPE, Sampling}

  @impl true
  def id, do: "categorical_tpe"

  @impl true
  def new(opts) do
    space = Keyword.fetch!(opts, :space)
    validate_wire_space!(space)
    CategoricalTPE.new(space, Keyword.delete(opts, :space))
  end

  @impl true
  def suggest(%CategoricalTPE{} = state, _context), do: CategoricalTPE.suggest(state)

  @impl true
  def observe(%CategoricalTPE{} = state, %{params: params, score: score}),
    do: CategoricalTPE.observe(state, params, score)

  def observe(_state, observation),
    do: raise(ArgumentError, "invalid categorical TPE observation: #{inspect(observation)}")

  @impl true
  def dump(%CategoricalTPE{} = state) do
    validate_wire_space!(state.space)

    %{
      "space" => state.space,
      "rng" => Sampling.dump(state.rng),
      "observations" =>
        Enum.map(state.observations, &%{"params" => &1.params, "score" => &1.score}),
      "startup_trials" => state.startup_trials,
      "candidates" => state.candidates,
      "gamma" => state.gamma,
      "bandwidth" => state.bandwidth
    }
  end

  @impl true
  def load!(state) do
    space = fetch_map!(state, "space")
    validate_wire_space!(space)

    tpe = %CategoricalTPE{
      space: space,
      rng: state |> Map.fetch!("rng") |> Sampling.load!(),
      observations: [],
      startup_trials: fetch_non_negative_integer!(state, "startup_trials"),
      candidates: fetch_positive_integer!(state, "candidates"),
      gamma: fetch_probability!(state, "gamma"),
      bandwidth: fetch_probability!(state, "bandwidth")
    }

    observations = Map.fetch!(state, "observations")

    unless is_list(observations),
      do: raise(ArgumentError, "categorical TPE observations must be a list")

    Enum.reduce(Enum.reverse(observations), tpe, fn
      %{"params" => params, "score" => score}, tpe when is_map(params) and is_number(score) ->
        CategoricalTPE.observe(tpe, params, score)

      observation, _tpe ->
        raise ArgumentError, "invalid categorical TPE observation: #{inspect(observation)}"
    end)
  end

  defp validate_wire_space!(space) when is_map(space) do
    Enum.each(space, fn
      {name, [_ | _] = choices} when is_binary(name) ->
        unless Enum.all?(choices, &wire_scalar?/1) do
          raise ArgumentError, "categorical TPE checkpoint choices must be JSON scalars"
        end

      {name, choices} ->
        raise ArgumentError,
              "categorical TPE checkpoint requires non-empty string-keyed choices, got: #{inspect({name, choices})}"
    end)
  end

  defp validate_wire_space!(space),
    do: raise(ArgumentError, "categorical TPE space must be a map, got: #{inspect(space)}")

  defp wire_scalar?(value),
    do: is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value)

  defp fetch_map!(map, key) do
    case Map.fetch!(map, key) do
      value when is_map(value) -> value
      value -> raise ArgumentError, "#{key} must be a map, got: #{inspect(value)}"
    end
  end

  defp fetch_non_negative_integer!(map, key) do
    case Map.fetch!(map, key) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp fetch_positive_integer!(map, key) do
    case Map.fetch!(map, key) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp fetch_probability!(map, key) do
    case Map.fetch!(map, key) do
      value when is_number(value) and value > 0 and value <= 1 -> value
      value -> raise ArgumentError, "#{key} must be in (0, 1], got: #{inspect(value)}"
    end
  end
end

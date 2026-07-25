defmodule Imp.Optimizer.CategoricalTPE do
  @moduledoc false

  alias Imp.Optimizer.Sampling

  @enforce_keys [:space, :rng]
  defstruct [
    :space,
    :rng,
    observations: [],
    startup_trials: 10,
    candidates: 24,
    gamma: 0.25,
    bandwidth: 0.2
  ]

  @type parameter :: atom() | String.t()
  @type assignment :: %{required(parameter()) => term()}
  @type observation :: %{params: assignment(), score: number()}
  @type t :: %__MODULE__{
          space: %{required(parameter()) => [term()]},
          rng: Sampling.state(),
          observations: [observation()],
          startup_trials: non_neg_integer(),
          candidates: pos_integer(),
          gamma: float(),
          bandwidth: float()
        }

  @spec new(map(), keyword()) :: t()
  def new(space, opts \\ []) when is_map(space) do
    validate_space!(space)

    %__MODULE__{
      space: space,
      rng: Sampling.new(Keyword.get(opts, :seed, 0)),
      startup_trials: Keyword.get(opts, :startup_trials, 10),
      candidates: Keyword.get(opts, :candidates, 24),
      gamma: Keyword.get(opts, :gamma, 0.25),
      bandwidth: Keyword.get(opts, :bandwidth, 0.2)
    }
  end

  @spec suggest(t()) :: {assignment(), t()}
  def suggest(%__MODULE__{} = tpe) do
    if length(tpe.observations) < tpe.startup_trials or
         distinct_assignment_count(tpe.observations) < 2 do
      random_assignment(tpe)
    else
      model_assignment(tpe)
    end
  end

  @spec observe(t(), assignment(), number()) :: t()
  def observe(%__MODULE__{} = tpe, params, score) when is_map(params) and is_number(score) do
    validate_assignment!(tpe.space, params)
    %{tpe | observations: [%{params: params, score: score} | tpe.observations]}
  end

  defp model_assignment(tpe) do
    ranked = Enum.sort_by(tpe.observations, & &1.score, :desc)
    good_count = max(1, ceil(length(ranked) * tpe.gamma))
    {good, bad} = Enum.split(ranked, good_count)

    {proposals, rng} =
      Enum.map_reduce(1..tpe.candidates, tpe.rng, fn _, rng ->
        sample_from_model(tpe.space, good, tpe.bandwidth, rng)
      end)

    best =
      Enum.max_by(proposals, &density_ratio(&1, tpe.space, good, bad, tpe.bandwidth))

    {best, %{tpe | rng: rng}}
  end

  defp sample_from_model(space, observations, bandwidth, rng) do
    {base, rng} = Sampling.choose(observations, rng)

    space
    |> stable_space()
    |> Enum.map_reduce(rng, fn {name, choices}, rng ->
      center = Map.fetch!(base.params, name)

      weights =
        Enum.map(choices, fn choice ->
          {choice, :math.log(categorical_kernel(choice, center, length(choices), bandwidth))}
        end)

      {choice, rng} = Sampling.softmax_choose(weights, 1.0, rng)
      {{name, choice}, rng}
    end)
    |> then(fn {pairs, rng} -> {Map.new(pairs), rng} end)
  end

  defp density_ratio(params, space, good, bad, bandwidth) do
    good_density = joint_density(params, space, good, bandwidth)
    bad_density = joint_density(params, space, bad, bandwidth)
    :math.log(good_density / bad_density)
  end

  defp joint_density(_params, _space, [], _bandwidth), do: 1.0e-12

  defp joint_density(params, space, observations, bandwidth) do
    observations
    |> Enum.map(fn observation ->
      Enum.reduce(space, 1.0, fn {name, choices}, density ->
        value = Map.fetch!(params, name)
        center = Map.fetch!(observation.params, name)
        density * categorical_kernel(value, center, length(choices), bandwidth)
      end)
    end)
    |> average()
  end

  defp categorical_kernel(value, center, choice_count, bandwidth) do
    uniform = bandwidth / choice_count
    if value == center, do: 1.0 - bandwidth + uniform, else: uniform
  end

  defp average(values), do: Enum.sum(values) / length(values)

  defp random_assignment(tpe) do
    tpe.space
    |> stable_space()
    |> Enum.map_reduce(tpe.rng, fn {name, choices}, rng ->
      {choice, rng} = Sampling.choose(choices, rng)
      {{name, choice}, rng}
    end)
    |> then(fn {pairs, rng} -> {Map.new(pairs), %{tpe | rng: rng}} end)
  end

  defp stable_space(space), do: Enum.sort_by(space, fn {name, _} -> to_string(name) end)

  defp distinct_assignment_count(observations) do
    observations
    |> Enum.map(& &1.params)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp validate_space!(space) do
    Enum.each(space, fn
      {_name, [_ | _]} ->
        :ok

      {name, choices} ->
        raise ArgumentError,
              "categorical parameter #{inspect(name)} has no choices: #{inspect(choices)}"
    end)
  end

  defp validate_assignment!(space, params) do
    if Map.keys(space) |> MapSet.new() != Map.keys(params) |> MapSet.new() do
      raise ArgumentError, "categorical assignment keys do not match the search space"
    end

    Enum.each(space, fn {name, choices} ->
      unless Map.fetch!(params, name) in choices do
        raise ArgumentError,
              "invalid choice for #{inspect(name)}: #{inspect(Map.fetch!(params, name))}"
      end
    end)
  end
end

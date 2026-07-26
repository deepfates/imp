defmodule Imp.Optimizer.MIPROv2.OptunaStartupPolicy do
  @moduledoc false
  @behaviour Imp.Optimizer.SearchPolicy

  alias Imp.Optimizer.MIPROv2.NumpyRandomState

  @id "dspy_3_2_1_optuna_4_9_0_startup"

  defstruct [:parameters, :rng, :startup_trials, completed_trials: 0]

  @impl true
  def id, do: @id

  @impl true
  def new(opts) do
    space = Keyword.fetch!(opts, :space)
    order = Keyword.fetch!(opts, :parameter_order)
    startup_trials = Keyword.fetch!(opts, :startup_trials)
    seed = Keyword.fetch!(opts, :seed)
    parameters = ordered_parameters!(space, order)

    unless is_integer(startup_trials) and startup_trials > 0 do
      raise ArgumentError, "Optuna startup_trials must be a positive integer"
    end

    %__MODULE__{
      parameters: parameters,
      rng: NumpyRandomState.new(seed),
      startup_trials: startup_trials
    }
  end

  @impl true
  def suggest(%__MODULE__{} = state, _context) do
    if state.completed_trials >= state.startup_trials do
      raise ArgumentError,
            "pinned Optuna startup search cannot enter modeled TPE after " <>
              "#{state.startup_trials} completed trials"
    end

    {pairs, rng} =
      Enum.map_reduce(state.parameters, state.rng, fn {name, choices}, rng ->
        {choice, rng} = NumpyRandomState.categorical(rng, choices)
        {{name, choice}, rng}
      end)

    {Map.new(pairs), %{state | rng: rng}}
  end

  @impl true
  def observe(%__MODULE__{} = state, %{params: params, score: score})
      when is_map(params) and is_number(score) do
    validate_assignment!(state.parameters, params)
    %{state | completed_trials: state.completed_trials + 1}
  end

  def observe(_state, observation),
    do: raise(ArgumentError, "invalid Optuna startup observation: #{inspect(observation)}")

  @impl true
  def dump(%__MODULE__{} = state) do
    %{
      "parameters" =>
        Enum.map(state.parameters, fn {name, choices} ->
          %{"name" => name, "choices" => choices}
        end),
      "rng" => NumpyRandomState.dump(state.rng),
      "startup_trials" => state.startup_trials,
      "completed_trials" => state.completed_trials
    }
  end

  @impl true
  def load!(
        %{
          "parameters" => parameters,
          "rng" => rng,
          "startup_trials" => startup_trials,
          "completed_trials" => completed_trials
        } = checkpoint
      )
      when is_list(parameters) and is_integer(startup_trials) and startup_trials > 0 and
             is_integer(completed_trials) and completed_trials >= 0 and
             completed_trials <= startup_trials and map_size(checkpoint) == 4 do
    parameters = Enum.map(parameters, &load_parameter!/1)

    unless parameters |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(parameters) do
      raise ArgumentError, "Optuna startup policy checkpoint contains duplicate parameters"
    end

    %__MODULE__{
      parameters: parameters,
      rng: NumpyRandomState.load!(rng),
      startup_trials: startup_trials,
      completed_trials: completed_trials
    }
  end

  def load!(value),
    do: raise(ArgumentError, "invalid Optuna startup policy checkpoint: #{inspect(value)}")

  defp ordered_parameters!(space, order) when is_map(space) and is_list(order) do
    unless MapSet.new(Map.keys(space)) == MapSet.new(order) and length(order) == map_size(space) do
      raise ArgumentError, "Optuna startup parameter order does not match the search space"
    end

    Enum.map(order, fn name ->
      case Map.fetch!(space, name) do
        [_ | _] = choices ->
          {name, choices}

        choices ->
          raise ArgumentError,
                "Optuna categorical parameter #{inspect(name)} has no choices: #{inspect(choices)}"
      end
    end)
  end

  defp ordered_parameters!(space, order) do
    raise ArgumentError,
          "Optuna startup policy requires a map space and ordered parameter names, got: " <>
            inspect({space, order})
  end

  defp validate_assignment!(parameters, params) do
    expected = parameters |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    unless expected == Map.keys(params) |> MapSet.new() do
      raise ArgumentError, "Optuna startup assignment keys do not match the search space"
    end

    Enum.each(parameters, fn {name, choices} ->
      unless Map.fetch!(params, name) in choices do
        raise ArgumentError, "invalid Optuna categorical choice for #{inspect(name)}"
      end
    end)
  end

  defp load_parameter!(%{"name" => name, "choices" => [_ | _] = choices}) when is_binary(name),
    do: {name, choices}

  defp load_parameter!(value),
    do: raise(ArgumentError, "invalid Optuna startup parameter checkpoint: #{inspect(value)}")
end

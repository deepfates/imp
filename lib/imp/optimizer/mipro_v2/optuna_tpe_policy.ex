defmodule Imp.Optimizer.MIPROv2.OptunaTPEPolicy do
  @moduledoc false
  @behaviour Imp.Optimizer.SearchPolicy

  alias Imp.Optimizer.MIPROv2.NumpyRandomState

  @id "dspy_3_2_1_optuna_4_9_0"
  @candidate_count 24
  @prior_weight 1.0

  defstruct [
    :parameters,
    :startup_rng,
    :model_rng,
    :startup_trials,
    observations: []
  ]

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
      startup_rng: NumpyRandomState.new(seed),
      model_rng: NumpyRandomState.new(seed),
      startup_trials: startup_trials
    }
  end

  @impl true
  def suggest(%__MODULE__{} = state, _context) do
    if length(state.observations) < state.startup_trials do
      startup_suggestion(state)
    else
      modeled_suggestion(state)
    end
  end

  @impl true
  def observe(%__MODULE__{} = state, %{params: params, score: score})
      when is_map(params) and is_number(score) do
    validate_assignment!(state.parameters, params)
    %{state | observations: state.observations ++ [%{params: params, score: score * 1.0}]}
  end

  def observe(_state, observation),
    do: raise(ArgumentError, "invalid Optuna TPE observation: #{inspect(observation)}")

  @impl true
  def dump(%__MODULE__{} = state) do
    %{
      "parameters" =>
        Enum.map(state.parameters, fn {name, choices} ->
          %{"name" => name, "choices" => choices}
        end),
      "startup_rng" => NumpyRandomState.dump(state.startup_rng),
      "model_rng" => NumpyRandomState.dump(state.model_rng),
      "startup_trials" => state.startup_trials,
      "observations" =>
        Enum.map(state.observations, fn observation ->
          %{"params" => observation.params, "score" => observation.score}
        end)
    }
  end

  @impl true
  def load!(
        %{
          "parameters" => parameters,
          "startup_rng" => startup_rng,
          "model_rng" => model_rng,
          "startup_trials" => startup_trials,
          "observations" => observations
        } = checkpoint
      )
      when is_list(parameters) and is_integer(startup_trials) and startup_trials > 0 and
             is_list(observations) and map_size(checkpoint) == 5 do
    parameters = Enum.map(parameters, &load_parameter!/1)

    unless parameters |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(parameters) do
      raise ArgumentError, "Optuna TPE policy checkpoint contains duplicate parameters"
    end

    state = %__MODULE__{
      parameters: parameters,
      startup_rng: NumpyRandomState.load!(startup_rng),
      model_rng: NumpyRandomState.load!(model_rng),
      startup_trials: startup_trials
    }

    Enum.reduce(observations, state, fn
      %{"params" => params, "score" => score}, state when is_map(params) and is_number(score) ->
        observe(state, %{params: params, score: score})

      observation, _state ->
        raise ArgumentError, "invalid Optuna TPE observation: #{inspect(observation)}"
    end)
  end

  def load!(value),
    do: raise(ArgumentError, "invalid Optuna TPE policy checkpoint: #{inspect(value)}")

  defp startup_suggestion(state) do
    {pairs, rng} =
      Enum.map_reduce(state.parameters, state.startup_rng, fn {name, choices}, rng ->
        {choice, rng} = NumpyRandomState.categorical(rng, choices)
        {{name, choice}, rng}
      end)

    {Map.new(pairs), %{state | startup_rng: rng}}
  end

  defp modeled_suggestion(state) do
    count = length(state.observations)
    below_count = min(ceil(0.1 * count), 25)

    # Optuna's single-objective split sorts descending by value while Python's
    # stable sort retains the original trial number for ties.
    ranked =
      state.observations
      |> Enum.with_index()
      |> Enum.sort_by(fn {observation, trial_number} -> {-observation.score, trial_number} end)

    {below, above} = Enum.split(ranked, below_count)

    # `_split_trials/4` ranks to choose the partition, then restores trial
    # number order before constructing each Parzen estimator. Kernel order is
    # observable because the seeded mixture first samples a kernel index.
    chronological = fn indexed ->
      indexed |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
    end

    below = chronological.(below)
    above = chronological.(above)
    below_model = model(state.parameters, below)
    above_model = model(state.parameters, above)

    {active_indices, rng} =
      NumpyRandomState.weighted_indices(
        state.model_rng,
        below_model.mixture_weights,
        @candidate_count
      )

    {columns, rng} =
      Enum.map_reduce(state.parameters, rng, fn {name, choices}, rng ->
        rows = Map.fetch!(below_model.parameter_weights, name)
        {quantiles, rng} = NumpyRandomState.uniforms(rng, @candidate_count)

        values =
          Enum.zip(active_indices, quantiles)
          |> Enum.map(fn {active, quantile} ->
            row = Enum.at(rows, active)
            index = row |> Enum.scan(&+/2) |> Enum.count(&(&1 < quantile))
            Enum.at(choices, min(index, length(choices) - 1))
          end)

        {{name, values}, rng}
      end)

    candidates =
      0..(@candidate_count - 1)
      |> Enum.map(fn index ->
        Map.new(columns, fn {name, values} -> {name, Enum.at(values, index)} end)
      end)

    scored =
      candidates
      |> Enum.map(fn candidate ->
        score =
          log_pdf(below_model, state.parameters, candidate) -
            log_pdf(above_model, state.parameters, candidate)

        {score, candidate}
      end)

    maximum = scored |> Enum.map(&elem(&1, 0)) |> Enum.max()

    # NumPy's argmax keeps the first candidate. Algebraically identical
    # categorical likelihoods can differ at the final ULP when Erlang and
    # NumPy sum the kernels in a different machine order, so collapse only
    # machine-epsilon-scale ties before applying that same rule.
    {_score, best} = Enum.find(scored, fn {score, _candidate} -> maximum - score <= 1.0e-14 end)

    {best, %{state | model_rng: rng}}
  end

  defp model(parameters, observations) do
    observation_weights = default_weights(length(observations))
    mixture_weights = normalize(observation_weights ++ [@prior_weight])
    kernel_count = length(observations) + 1

    parameter_weights =
      Map.new(parameters, fn {name, choices} ->
        base = @prior_weight / kernel_count

        rows =
          Enum.map(observations, fn observation ->
            observed = Map.fetch!(observation.params, name)

            Enum.map(choices, fn choice ->
              base + if(choice == observed, do: 1.0, else: 0.0)
            end)
            |> normalize()
          end) ++ [List.duplicate(1.0 / length(choices), length(choices))]

        {name, rows}
      end)

    %{mixture_weights: mixture_weights, parameter_weights: parameter_weights}
  end

  defp log_pdf(model, parameters, candidate) do
    model.mixture_weights
    |> Enum.with_index()
    |> Enum.map(fn {mixture_weight, kernel_index} ->
      Enum.reduce(parameters, :math.log(mixture_weight), fn {name, choices}, total ->
        choice_index = Enum.find_index(choices, &(&1 == Map.fetch!(candidate, name)))

        probability =
          model.parameter_weights
          |> Map.fetch!(name)
          |> Enum.at(kernel_index)
          |> Enum.at(choice_index)

        total + :math.log(probability)
      end)
    end)
    |> logsumexp()
  end

  defp logsumexp(values) do
    maximum = Enum.max(values)
    maximum + :math.log(Enum.sum(Enum.map(values, &:math.exp(&1 - maximum))))
  end

  defp default_weights(0), do: []
  defp default_weights(count) when count < 25, do: List.duplicate(1.0, count)

  defp default_weights(count) do
    ramp_count = count - 25

    ramp =
      if ramp_count == 1 do
        [1.0 / count]
      else
        for index <- 0..(ramp_count - 1),
            do: 1.0 / count + index * (1.0 - 1.0 / count) / (ramp_count - 1)
      end

    ramp ++ List.duplicate(1.0, 25)
  end

  defp normalize(weights) do
    total = Enum.sum(weights)
    Enum.map(weights, &(&1 / total))
  end

  defp ordered_parameters!(space, order) when is_map(space) and is_list(order) do
    unless MapSet.new(Map.keys(space)) == MapSet.new(order) and length(order) == map_size(space) do
      raise ArgumentError, "Optuna TPE parameter order does not match the search space"
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

  defp ordered_parameters!(space, order),
    do:
      raise(
        ArgumentError,
        "Optuna TPE requires a map space and ordered names, got: #{inspect({space, order})}"
      )

  defp validate_assignment!(parameters, params) do
    expected = parameters |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    unless expected == Map.keys(params) |> MapSet.new(),
      do: raise(ArgumentError, "Optuna TPE assignment keys do not match the search space")

    Enum.each(parameters, fn {name, choices} ->
      unless Map.fetch!(params, name) in choices,
        do: raise(ArgumentError, "invalid Optuna categorical choice for #{inspect(name)}")
    end)
  end

  defp load_parameter!(%{"name" => name, "choices" => [_ | _] = choices}) when is_binary(name),
    do: {name, choices}

  defp load_parameter!(value),
    do: raise(ArgumentError, "invalid Optuna TPE parameter checkpoint: #{inspect(value)}")
end

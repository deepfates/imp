defmodule Imp.Optimizer.GEPA.CandidateSelector do
  @moduledoc """
  Candidate-selection contract for the GEPA engine.

  A custom selector may be a module implementing `select_candidate/2` or a
  struct whose module implements `select_candidate/3`. Both callbacks receive
  the persisted engine RNG and must return `{candidate_id, rng_state}`.
  """

  alias Imp.Optimizer.GEPA.{Engine, Random}
  alias __MODULE__.{CurrentBest, EpsilonGreedy, Pareto, TopKPareto}

  @type candidate_id :: non_neg_integer()
  @type rng_state :: Random.state()
  @type selection :: {candidate_id(), rng_state()}

  @callback select_candidate(Engine.State.t(), rng_state()) :: selection()
  @callback select_candidate(struct(), Engine.State.t(), rng_state()) :: selection()
  @callback identity() :: term()
  @callback identity(struct()) :: term()
  @optional_callbacks select_candidate: 2, select_candidate: 3, identity: 0, identity: 1

  @built_ins [:pareto, :current_best, :epsilon_greedy, :top_k_pareto]

  @doc false
  @spec validate!(term()) :: :ok
  def validate!(strategy) when strategy in @built_ins, do: :ok

  def validate!(%module{} = strategy) do
    ensure_callback!(module, :select_candidate, 3, strategy)
  end

  def validate!(module) when is_atom(module) do
    ensure_callback!(module, :select_candidate, 2, module)
  end

  def validate!(strategy) do
    raise ArgumentError,
          ":candidate_selection_strategy must be a released strategy, selector module, or selector struct, got: " <>
            inspect(strategy)
  end

  @doc false
  def checkpoint_identity!(strategy) when strategy in @built_ins,
    do: %{kind: :built_in, name: strategy}

  def checkpoint_identity!(%module{} = strategy) do
    unless function_exported?(module, :identity, 1) do
      raise ArgumentError,
            "durable custom candidate selector #{inspect(module)} must implement identity/1"
    end

    %{kind: :struct, module: Atom.to_string(module), identity: module.identity(strategy)}
  end

  def checkpoint_identity!(module) when is_atom(module) do
    identity =
      if function_exported?(module, :identity, 0),
        do: module.identity(),
        else: :stateless

    %{kind: :module, module: Atom.to_string(module), identity: identity}
  end

  @doc false
  @spec select(term(), Engine.State.t()) :: {Engine.Entry.t(), rng_state()}
  def select(strategy, %Engine.State{} = state) do
    result = invoke(strategy, state)

    case result do
      {candidate_id, rng_state} ->
        candidate = Enum.find(state.candidates, &(&1.id == candidate_id))

        if is_nil(candidate) do
          raise ArgumentError,
                "GEPA candidate selector returned unknown candidate ID: #{inspect(candidate_id)}"
        end

        validate_rng!(rng_state)
        {candidate, rng_state}

      other ->
        raise ArgumentError,
              "GEPA candidate selector must return {candidate_id, rng_state}, got: #{inspect(other)}"
    end
  end

  defp invoke(:pareto, state), do: Pareto.select_candidate(state, state.rng_state)
  defp invoke(:current_best, state), do: CurrentBest.select_candidate(state, state.rng_state)

  defp invoke(:epsilon_greedy, state),
    do: EpsilonGreedy.select_candidate(struct(EpsilonGreedy), state, state.rng_state)

  defp invoke(:top_k_pareto, state),
    do: TopKPareto.select_candidate(struct(TopKPareto), state, state.rng_state)

  defp invoke(%module{} = strategy, state),
    do: module.select_candidate(strategy, state, state.rng_state)

  defp invoke(module, state), do: module.select_candidate(state, state.rng_state)

  defp ensure_callback!(module, function, arity, strategy) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      :ok
    else
      raise ArgumentError,
            "GEPA candidate selector #{inspect(strategy)} must implement #{function}/#{arity}"
    end
  end

  defp validate_rng!(rng_state) do
    if valid_rng?(rng_state) do
      :ok
    else
      raise ArgumentError,
            "GEPA candidate selector returned an invalid RNG state: #{inspect(rng_state)}"
    end
  end

  defp valid_rng?(rng_state) do
    Random.valid?(rng_state)
  end

  defmodule Pareto do
    @moduledoc false
    @behaviour Imp.Optimizer.GEPA.CandidateSelector

    alias Imp.Optimizer.GEPA.{Engine, Frontier}

    @impl true
    def select_candidate(%Engine.State{} = state, rng_state) do
      state.candidates
      |> candidates_with_results()
      |> Frontier.sample(state.frontier_type, rng_state)
    end

    defp candidates_with_results(candidates),
      do: Enum.map(candidates, &{&1.id, &1.validation})
  end

  defmodule CurrentBest do
    @moduledoc false
    @behaviour Imp.Optimizer.GEPA.CandidateSelector

    alias Imp.Optimizer.GEPA.Engine

    @impl true
    def select_candidate(%Engine.State{candidates: [first | rest]}, rng_state) do
      best =
        Enum.reduce(rest, first, fn candidate, best ->
          if candidate.validation.aggregate_score > best.validation.aggregate_score,
            do: candidate,
            else: best
        end)

      {best.id, rng_state}
    end
  end

  defmodule EpsilonGreedy do
    @moduledoc false
    @behaviour Imp.Optimizer.GEPA.CandidateSelector

    alias Imp.Optimizer.GEPA.Engine

    @enforce_keys []
    defstruct epsilon: 0.1

    @impl true
    def select_candidate(%__MODULE__{epsilon: epsilon}, %Engine.State{} = state, rng_state)
        when is_number(epsilon) and epsilon >= 0.0 and epsilon <= 1.0 do
      {draw, rng_state} = :rand.uniform_s(rng_state)

      if draw < epsilon do
        {position, rng_state} = :rand.uniform_s(length(state.candidates), rng_state)
        {Enum.at(state.candidates, position - 1).id, rng_state}
      else
        CurrentBest.select_candidate(state, rng_state)
      end
    end
  end

  defmodule TopKPareto do
    @moduledoc false
    @behaviour Imp.Optimizer.GEPA.CandidateSelector

    alias Imp.Optimizer.GEPA.{Engine, Frontier, Pareto}

    @enforce_keys []
    defstruct k: 5

    @impl true
    def select_candidate(%__MODULE__{k: k}, %Engine.State{} = state, rng_state)
        when is_integer(k) and k > 0 do
      top_ids =
        state.candidates
        |> Enum.with_index()
        |> Enum.sort_by(fn {candidate, index} ->
          {-candidate.validation.aggregate_score, index}
        end)
        |> Enum.take(k)
        |> Enum.map(fn {candidate, _index} -> candidate.id end)
        |> MapSet.new()

      mapping =
        state.candidates
        |> Enum.map(&{&1.id, &1.validation})
        |> Frontier.mapping(state.frontier_type)
        |> Enum.reduce(%{}, fn {key, ids}, filtered ->
          ids = MapSet.intersection(ids, top_ids)
          if MapSet.size(ids) == 0, do: filtered, else: Map.put(filtered, key, ids)
        end)

      if map_size(mapping) == 0 do
        CurrentBest.select_candidate(state, rng_state)
      else
        scores = Map.new(state.candidates, &{&1.id, &1.validation.aggregate_score})
        Pareto.sample(mapping, scores, rng_state)
      end
    end
  end
end

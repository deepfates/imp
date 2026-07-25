defmodule Imp.Training.FastSlow.Theta do
  @moduledoc "Immutable policy parameter identity and lineage node."

  alias Imp.Training.FastSlow.Config

  @enforce_keys [:id, :digest, :cycle, :payload]
  defstruct @enforce_keys ++ [parent_id: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          digest: String.t(),
          cycle: non_neg_integer(),
          parent_id: String.t() | nil,
          payload: Config.json_value()
        }

  @spec new!(non_neg_integer(), term(), String.t() | nil) :: t()
  def new!(cycle, payload, parent_id \\ nil)

  def new!(cycle, payload, parent_id)
      when is_integer(cycle) and cycle >= 0 and (is_nil(parent_id) or is_binary(parent_id)) do
    payload = Config.json_safe!(payload, [:theta, :payload])
    digest = Config.digest(payload)
    id = Config.digest(%{"cycle" => cycle, "digest" => digest, "parent_id" => parent_id})
    %__MODULE__{id: id, digest: digest, cycle: cycle, parent_id: parent_id, payload: payload}
  end

  def new!(_cycle, _payload, _parent_id),
    do: raise(ArgumentError, "theta cycle or parent is invalid")

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = theta) do
    expected = new!(theta.cycle, theta.payload, theta.parent_id)

    unless theta.id == expected.id and theta.digest == expected.digest,
      do: raise(ArgumentError, "theta identity or digest is invalid")

    theta
  end
end

defmodule Imp.Training.FastSlow.PromptPopulation do
  @moduledoc "Bounded prompt population used by the fast adaptation phase."

  alias Imp.Training.FastSlow.Config

  @enforce_keys [
    :revision,
    :digest,
    :candidates,
    :candidate_ids,
    :instance_scores,
    :instance_frontier,
    :parent_digest,
    :anchor_digest,
    :lookahead_digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          digest: String.t(),
          candidates: [Config.json_value()],
          candidate_ids: [String.t()],
          instance_scores: %{String.t() => %{String.t() => number()}},
          instance_frontier: %{String.t() => [String.t()]},
          parent_digest: String.t() | nil,
          anchor_digest: String.t() | nil,
          lookahead_digest: String.t() | nil
        }

  @metadata_keys [
    :candidate_ids,
    :instance_scores,
    :instance_frontier,
    :parent_digest,
    :anchor_digest,
    :lookahead_digest
  ]

  @spec new!(non_neg_integer(), [term()], keyword() | map()) :: t()
  def new!(revision, candidates, metadata \\ %{})

  def new!(revision, candidates, metadata)
      when is_integer(revision) and revision >= 0 and is_list(candidates) and candidates != [] and
             (is_list(metadata) or is_map(metadata)) do
    candidates = Config.json_safe!(candidates, [:prompt_population, :candidates])
    metadata = normalize_metadata!(metadata)

    candidate_ids =
      metadata
      |> Map.get(:candidate_ids, Enum.map(candidates, &Config.digest/1))
      |> candidate_ids!(length(candidates))

    instance_scores = scores!(Map.get(metadata, :instance_scores, %{}), candidate_ids)
    instance_frontier = frontier!(Map.get(metadata, :instance_frontier, %{}), candidate_ids)
    parent_digest = optional_digest!(Map.get(metadata, :parent_digest), :parent_digest)
    anchor_digest = optional_digest!(Map.get(metadata, :anchor_digest), :anchor_digest)
    lookahead_digest = optional_digest!(Map.get(metadata, :lookahead_digest), :lookahead_digest)

    if revision == 0 do
      unless map_size(instance_scores) == 0 and map_size(instance_frontier) == 0 and
               is_nil(parent_digest) and is_nil(anchor_digest) and is_nil(lookahead_digest) do
        raise ArgumentError, "Phi0 may not claim GEPA frontier provenance"
      end
    else
      validate_revision_provenance!(
        candidate_ids,
        instance_scores,
        instance_frontier,
        parent_digest,
        anchor_digest,
        lookahead_digest
      )
    end

    identity = %{
      "revision" => revision,
      "candidates" => candidates,
      "candidate_ids" => candidate_ids,
      "instance_scores" => instance_scores,
      "instance_frontier" => instance_frontier,
      "parent_digest" => parent_digest,
      "anchor_digest" => anchor_digest,
      "lookahead_digest" => lookahead_digest
    }

    %__MODULE__{
      revision: revision,
      digest: Config.digest(identity),
      candidates: candidates,
      candidate_ids: candidate_ids,
      instance_scores: instance_scores,
      instance_frontier: instance_frontier,
      parent_digest: parent_digest,
      anchor_digest: anchor_digest,
      lookahead_digest: lookahead_digest
    }
  end

  def new!(_revision, _candidates, _metadata),
    do: raise(ArgumentError, "prompt population requires a revision and non-empty candidates")

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = population) do
    expected =
      new!(population.revision, population.candidates,
        candidate_ids: population.candidate_ids,
        instance_scores: population.instance_scores,
        instance_frontier: population.instance_frontier,
        parent_digest: population.parent_digest,
        anchor_digest: population.anchor_digest,
        lookahead_digest: population.lookahead_digest
      )

    unless expected == population,
      do: raise(ArgumentError, "prompt population digest is invalid")

    population
  end

  defp normalize_metadata!(metadata) do
    metadata = if is_list(metadata), do: Map.new(metadata), else: metadata

    metadata =
      Map.new(metadata, fn
        {key, value} when is_atom(key) ->
          {key, value}

        {key, value} when is_binary(key) ->
          {String.to_existing_atom(key), value}

        {key, _value} ->
          raise ArgumentError, "invalid prompt population metadata key: #{inspect(key)}"
      end)

    unknown = Map.keys(metadata) -- @metadata_keys

    unless unknown == [],
      do: raise(ArgumentError, "unknown prompt population metadata: #{inspect(unknown)}")

    metadata
  rescue
    error in [ArgumentError] ->
      reraise ArgumentError,
              [message: "prompt population metadata is invalid: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp candidate_ids!(ids, count) when is_list(ids) do
    ids = Config.json_safe!(ids, [:prompt_population, :candidate_ids])

    unless length(ids) == count and Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
             MapSet.size(MapSet.new(ids)) == count do
      raise ArgumentError, "candidate IDs must be exact, unique, and aligned with candidates"
    end

    ids
  end

  defp candidate_ids!(_ids, _count),
    do: raise(ArgumentError, "candidate IDs must be exact, unique, and aligned with candidates")

  defp scores!(scores, candidate_ids) when is_map(scores) and not is_struct(scores) do
    scores = Config.json_safe!(scores, [:prompt_population, :instance_scores])

    Enum.each(scores, fn {instance_id, by_candidate} ->
      unless instance_id != "" and is_map(by_candidate) and
               Enum.sort(Map.keys(by_candidate)) == Enum.sort(candidate_ids) and
               Enum.all?(by_candidate, fn {_id, score} -> is_number(score) end) do
        raise ArgumentError,
              "per-instance scores must contain every candidate ID with numeric fitness"
      end
    end)

    scores
  end

  defp scores!(_scores, _candidate_ids),
    do: raise(ArgumentError, "per-instance scores must be a data-only map")

  defp frontier!(frontier, candidate_ids) when is_map(frontier) and not is_struct(frontier) do
    frontier = Config.json_safe!(frontier, [:prompt_population, :instance_frontier])
    allowed = MapSet.new(candidate_ids)

    Enum.each(frontier, fn {instance_id, winners} ->
      unless instance_id != "" and is_list(winners) and winners != [] and
               Enum.all?(winners, &(is_binary(&1) and MapSet.member?(allowed, &1))) and
               MapSet.size(MapSet.new(winners)) == length(winners) do
        raise ArgumentError, "per-instance frontier contains invalid candidate identities"
      end
    end)

    frontier
  end

  defp frontier!(_frontier, _candidate_ids),
    do: raise(ArgumentError, "per-instance frontier must be a data-only map")

  defp validate_revision_provenance!(
         candidate_ids,
         scores,
         frontier,
         parent_digest,
         anchor_digest,
         lookahead_digest
       ) do
    selected = frontier |> Map.values() |> List.flatten() |> MapSet.new()

    unless map_size(scores) > 0 and
             Enum.sort(Map.keys(scores)) == Enum.sort(Map.keys(frontier)) and
             selected == MapSet.new(candidate_ids) and is_binary(parent_digest) and
             is_binary(anchor_digest) and is_binary(lookahead_digest) do
      raise ArgumentError,
            "revised population requires per-instance scores and exactly frontier-selected candidates"
    end
  end

  defp optional_digest!(nil, _name), do: nil

  defp optional_digest!(digest, _name) when is_binary(digest) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: digest,
      else: raise(ArgumentError, "prompt population provenance digest is invalid")
  end

  defp optional_digest!(_digest, name),
    do: raise(ArgumentError, "#{name} must be a SHA-256 digest or nil")
end

defmodule Imp.Training.FastSlow.Lookahead do
  @moduledoc "Prefetched minibatch window and deterministic dataset progress."

  alias Imp.Training.FastSlow.Config

  @enforce_keys [:cycle, :dataset_cursor, :digest, :checksum, :minibatches, :consumed_steps]
  defstruct @enforce_keys

  @type minibatch :: map()
  @type t :: %__MODULE__{
          cycle: non_neg_integer(),
          dataset_cursor: non_neg_integer(),
          digest: String.t(),
          checksum: String.t(),
          minibatches: [minibatch()],
          consumed_steps: non_neg_integer()
        }

  @spec new!(non_neg_integer(), non_neg_integer(), [map()]) :: t()
  def new!(cycle, dataset_cursor, minibatches)
      when is_integer(cycle) and cycle >= 0 and is_integer(dataset_cursor) and dataset_cursor >= 0 and
             is_list(minibatches) and minibatches != [] do
    minibatches = Enum.map(minibatches, &minibatch!/1)

    unless minibatches |> Enum.map(& &1["id"]) |> MapSet.new() |> MapSet.size() ==
             length(minibatches),
           do: raise(ArgumentError, "lookahead minibatch identities must be unique")

    digest = identity_digest(cycle, dataset_cursor, minibatches)

    %__MODULE__{
      cycle: cycle,
      dataset_cursor: dataset_cursor,
      digest: digest,
      checksum: progress_checksum(digest, 0),
      minibatches: minibatches,
      consumed_steps: 0
    }
  end

  def new!(_cycle, _dataset_cursor, _minibatches),
    do: raise(ArgumentError, "lookahead cycle, dataset cursor, or minibatches are invalid")

  @spec consume!(t()) :: t()
  def consume!(%__MODULE__{} = lookahead) do
    if lookahead.consumed_steps < length(lookahead.minibatches) do
      consumed_steps = lookahead.consumed_steps + 1

      %{
        lookahead
        | consumed_steps: consumed_steps,
          checksum: progress_checksum(lookahead.digest, consumed_steps)
      }
    else
      raise ArgumentError, "lookahead minibatches are already fully consumed"
    end
  end

  @spec validate!(t(), pos_integer() | nil) :: t()
  def validate!(%__MODULE__{} = lookahead, expected_t \\ nil) do
    expected = new!(lookahead.cycle, lookahead.dataset_cursor, lookahead.minibatches)

    unless expected.digest == lookahead.digest and is_integer(lookahead.consumed_steps) and
             lookahead.consumed_steps in 0..length(lookahead.minibatches) and
             lookahead.checksum == progress_checksum(lookahead.digest, lookahead.consumed_steps) and
             (is_nil(expected_t) or length(lookahead.minibatches) == expected_t) do
      raise ArgumentError, "lookahead identity, checksum, length, or consumption is invalid"
    end

    lookahead
  end

  defp minibatch!(minibatch) when is_map(minibatch) and not is_struct(minibatch) do
    minibatch = Config.json_safe!(minibatch, [:lookahead, :minibatches])

    case minibatch do
      %{"id" => id, "digest" => digest} when map_size(minibatch) == 2 ->
        unless is_binary(id) and id != "" and is_binary(digest) and
                 Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
          raise ArgumentError, "lookahead minibatch identity or digest is invalid"
        end

        minibatch

      _other ->
        raise ArgumentError, "lookahead minibatches require exactly id and digest"
    end
  end

  defp minibatch!(_minibatch),
    do: raise(ArgumentError, "lookahead minibatches require exactly id and digest")

  defp identity_digest(cycle, dataset_cursor, minibatches) do
    Config.digest(%{
      "cycle" => cycle,
      "dataset_cursor" => dataset_cursor,
      "minibatches" => minibatches
    })
  end

  defp progress_checksum(digest, consumed_steps),
    do: Config.digest(%{"digest" => digest, "consumed_steps" => consumed_steps})
end

defmodule Imp.Training.FastSlow.DatasetState do
  @moduledoc "Deterministic dataset cursor, epoch, and random-state snapshot."

  alias Imp.Training.FastSlow.Config

  @enforce_keys [:cursor, :epoch, :rng]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          cursor: non_neg_integer(),
          epoch: non_neg_integer(),
          rng: Config.json_value()
        }

  @spec new!(non_neg_integer(), non_neg_integer(), term()) :: t()
  def new!(cursor, epoch, rng)
      when is_integer(cursor) and cursor >= 0 and is_integer(epoch) and epoch >= 0 do
    %__MODULE__{cursor: cursor, epoch: epoch, rng: Config.json_safe!(rng, [:dataset, :rng])}
  end

  def new!(_cursor, _epoch, _rng), do: raise(ArgumentError, "dataset cursor or epoch is invalid")
end

defmodule Imp.Training.FastSlow.Budget do
  @moduledoc "Named immutable limits and accumulated usage for a training run."

  @enforce_keys [:limits, :used]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          limits: %{String.t() => non_neg_integer()},
          used: %{String.t() => non_neg_integer()}
        }

  @spec new!(map()) :: t()
  def new!(limits) when is_map(limits) and map_size(limits) > 0 do
    limits = normalize_counts!(limits, "budget limits")
    %__MODULE__{limits: limits, used: Map.new(limits, fn {key, _limit} -> {key, 0} end)}
  end

  def new!(_limits), do: raise(ArgumentError, "budget limits must be a non-empty map")

  @spec charge(t(), String.t() | atom(), non_neg_integer()) :: {:ok, t()} | {:error, :exhausted}
  def charge(%__MODULE__{} = budget, key, amount)
      when (is_binary(key) or is_atom(key)) and is_integer(amount) and amount >= 0 do
    key = to_string(key)
    limit = Map.fetch!(budget.limits, key)
    next = Map.fetch!(budget.used, key) + amount

    if next <= limit,
      do: {:ok, %{budget | used: Map.put(budget.used, key, next)}},
      else: {:error, :exhausted}
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = budget) do
    limits = normalize_counts!(budget.limits, "budget limits")
    used = normalize_counts!(budget.used, "budget usage")

    unless Map.keys(limits) |> Enum.sort() == Map.keys(used) |> Enum.sort() and
             Enum.all?(used, fn {key, value} -> value <= Map.fetch!(limits, key) end) do
      raise ArgumentError, "budget usage does not match its limits"
    end

    budget
  end

  defp normalize_counts!(counts, label) when is_map(counts) do
    Map.new(counts, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      unless is_binary(key) and key != "" and is_integer(value) and value >= 0,
        do: raise(ArgumentError, "#{label} must contain non-negative integer values")

      {key, value}
    end)
  end
end

defmodule Imp.Training.FastSlow.Terminal do
  @moduledoc "Terminal reason and details for a completed or stopped run."

  alias Imp.Training.FastSlow.Config

  @reasons [:completed, :budget_exhausted, :failed, :cancelled]
  @enforce_keys [:reason, :cycle]
  defstruct @enforce_keys ++ [details: %{}]

  @type t :: %__MODULE__{reason: atom(), cycle: non_neg_integer(), details: Config.json_value()}

  @spec new!(atom(), non_neg_integer(), term()) :: t()
  def new!(reason, cycle, details \\ %{})

  def new!(reason, cycle, details)
      when reason in @reasons and is_integer(cycle) and cycle >= 0 do
    %__MODULE__{
      reason: reason,
      cycle: cycle,
      details: Config.json_safe!(details, [:terminal, :details])
    }
  end

  def new!(_reason, _cycle, _details), do: raise(ArgumentError, "terminal state is invalid")
end

defmodule Imp.Training.FastSlow.State do
  @moduledoc "Validated durable state for the Fast-Slow training state machine."

  alias Imp.Training.FastSlow.{
    Budget,
    Config,
    DatasetState,
    Event,
    Lookahead,
    OperationIntent,
    PromptPopulation,
    ReuseCache,
    Rollout,
    Terminal,
    Theta
  }

  @stages [:initialized, :fast, :slow, :terminal]
  @enforce_keys [
    :config_fingerprint,
    :sampling_config_digest,
    :t,
    :k,
    :g,
    :max_cycles,
    :reuse_rollouts,
    :stage,
    :cycle,
    :slow_step,
    :theta_lineage,
    :current_theta_id,
    :prompt_population,
    :dataset,
    :budgets,
    :reuse_cache
  ]
  defstruct @enforce_keys ++
              [
                lookahead: nil,
                pending_operations: %{},
                rollout_ledger: %{},
                events: [],
                terminal: nil
              ]

  @type t :: %__MODULE__{
          config_fingerprint: String.t(),
          sampling_config_digest: String.t(),
          t: pos_integer(),
          k: pos_integer(),
          g: pos_integer(),
          max_cycles: pos_integer(),
          reuse_rollouts: boolean(),
          stage: :initialized | :fast | :slow | :terminal,
          cycle: non_neg_integer(),
          slow_step: non_neg_integer(),
          theta_lineage: [Theta.t()],
          current_theta_id: String.t(),
          prompt_population: PromptPopulation.t(),
          dataset: DatasetState.t(),
          lookahead: Lookahead.t() | nil,
          pending_operations: %{String.t() => OperationIntent.t()},
          budgets: Budget.t(),
          reuse_cache: ReuseCache.t(),
          rollout_ledger: %{String.t() => Rollout.t()},
          events: [Event.t()],
          terminal: Terminal.t() | nil
        }

  @spec new!(Config.t(), term(), [term()], keyword()) :: t()
  def new!(%Config{} = config, theta_payload, prompt_candidates, options \\ []) do
    unless length(prompt_candidates) == 1,
      do: raise(ArgumentError, "Phi0 must contain exactly one seed candidate")

    theta = Theta.new!(0, theta_payload)
    dataset = DatasetState.new!(0, 0, Keyword.get(options, :rng, %{"seed" => 0}))
    budgets = Budget.new!(Keyword.get(options, :budgets, %{"operations" => 1_000_000}))

    unless Map.has_key?(budgets.limits, "operations") do
      raise ArgumentError, "Fast-Slow state budgets must include an operations limit"
    end

    %__MODULE__{
      config_fingerprint: Config.fingerprint(config),
      sampling_config_digest: Config.digest(config.sampling_config),
      t: config.t,
      k: config.k,
      g: config.g,
      max_cycles: config.max_cycles,
      reuse_rollouts: config.reuse_rollouts,
      stage: :initialized,
      cycle: 0,
      slow_step: 0,
      theta_lineage: [theta],
      current_theta_id: theta.id,
      prompt_population: PromptPopulation.new!(0, prompt_candidates),
      dataset: dataset,
      budgets: budgets,
      reuse_cache: ReuseCache.new!(0, theta.id)
    }
  end

  @spec set_stage(t(), :fast | :slow) :: t()
  def set_stage(%__MODULE__{stage: stage} = state, next) when next in [:fast, :slow] do
    allowed = {stage, next} in [{:initialized, :fast}, {:fast, :slow}]

    unless allowed,
      do: raise(ArgumentError, "invalid Fast-Slow stage transition #{stage} -> #{next}")

    if next == :slow and
         (length(state.prompt_population.candidates) != state.k or
            state.prompt_population.revision != state.cycle + 1 or
            not current_lookahead?(state) or
            state.prompt_population.lookahead_digest != state.lookahead.digest) do
      raise ArgumentError,
            "slow stage requires a current-cycle GEPA population of exactly k candidates"
    end

    if next == :slow do
      Lookahead.validate!(state.lookahead, state.t)
      PromptPopulation.validate!(state.prompt_population)
    end

    %{state | stage: next}
  end

  @spec put_lookahead(t(), Lookahead.t()) :: t()
  def put_lookahead(%__MODULE__{stage: stage, terminal: nil} = state, %Lookahead{} = lookahead)
      when stage in [:initialized, :fast] do
    Lookahead.validate!(lookahead, state.t)

    unless state.prompt_population.revision == state.cycle and lookahead.cycle == state.cycle and
             lookahead.dataset_cursor == state.dataset.cursor and lookahead.consumed_steps == 0 do
      raise ArgumentError, "lookahead is not bound to the current cycle and dataset cursor"
    end

    %{state | lookahead: lookahead}
  end

  def put_lookahead(%__MODULE__{}, %Lookahead{}),
    do: raise(ArgumentError, "lookahead may only be installed before the current fast update")

  @spec next_cycle(t(), DatasetState.t()) :: t()
  def next_cycle(%__MODULE__{stage: :slow, terminal: nil} = state, %DatasetState{} = dataset) do
    unless state.slow_step == state.t,
      do: raise(ArgumentError, "configured Fast-Slow cycle has incomplete slow updates")

    unless state.cycle + 1 < state.max_cycles,
      do: raise(ArgumentError, "configured Fast-Slow cycle horizon is exhausted")

    %{
      state
      | stage: :fast,
        cycle: state.cycle + 1,
        slow_step: 0,
        dataset: dataset,
        lookahead: nil,
        reuse_cache:
          ReuseCache.next_cycle(state.reuse_cache, state.cycle + 1, state.current_theta_id)
    }
  end

  def next_cycle(%__MODULE__{}, %DatasetState{}),
    do: raise(ArgumentError, "a new cycle may only follow the slow stage")

  @spec complete(t(), DatasetState.t(), term()) :: t()
  def complete(state, dataset, details \\ %{})

  def complete(
        %__MODULE__{
          stage: :slow,
          terminal: nil,
          slow_step: t,
          t: t,
          cycle: cycle,
          max_cycles: max_cycles
        } = state,
        %DatasetState{} = dataset,
        details
      )
      when cycle + 1 == max_cycles do
    state
    |> Map.put(:dataset, dataset)
    |> terminate(:completed, details)
  end

  def complete(%__MODULE__{}, %DatasetState{}, _details),
    do: raise(ArgumentError, "completion requires t slow updates in the final cycle")

  @spec complete_slow_step(t(), term()) :: t()
  def complete_slow_step(%__MODULE__{stage: :slow, terminal: nil} = state, payload) do
    unless state.slow_step < state.t,
      do: raise(ArgumentError, "configured Fast-Slow cycle already has t slow updates")

    unless current_lookahead?(state) and state.lookahead.consumed_steps == state.slow_step,
      do: raise(ArgumentError, "slow update is not aligned with the current lookahead")

    Lookahead.validate!(state.lookahead, state.t)

    theta = Theta.new!(state.cycle, payload, state.current_theta_id)

    %{
      state
      | theta_lineage: state.theta_lineage ++ [theta],
        current_theta_id: theta.id,
        slow_step: state.slow_step + 1,
        lookahead: Lookahead.consume!(state.lookahead)
    }
  end

  def complete_slow_step(%__MODULE__{}, _payload),
    do: raise(ArgumentError, "a slow update may only complete during the slow stage")

  @spec revise_prompts(t(), [term()], keyword() | map()) :: t()
  def revise_prompts(state, candidates, metadata \\ %{})

  def revise_prompts(%__MODULE__{stage: :fast, terminal: nil} = state, candidates, metadata) do
    unless length(candidates) == state.k,
      do: raise(ArgumentError, "active prompt population must contain exactly k candidates")

    unless state.prompt_population.revision == state.cycle,
      do: raise(ArgumentError, "GEPA prompt population was already revised for this cycle")

    unless current_lookahead?(state),
      do: raise(ArgumentError, "GEPA prompt revision requires the current cycle lookahead")

    Lookahead.validate!(state.lookahead, state.t)

    revision = state.prompt_population.revision + 1
    metadata = if is_list(metadata), do: Map.new(metadata), else: metadata

    metadata =
      metadata
      |> Map.put(:parent_digest, state.prompt_population.digest)
      |> Map.put(:lookahead_digest, state.lookahead.digest)
      |> Map.put_new(:anchor_digest, state.lookahead.digest)

    %{state | prompt_population: PromptPopulation.new!(revision, candidates, metadata)}
  end

  def revise_prompts(%__MODULE__{}, _candidates, _metadata),
    do: raise(ArgumentError, "prompts may only be revised during the fast stage")

  @spec put_reuse_cache(t(), ReuseCache.t()) :: t()
  def put_reuse_cache(%__MODULE__{stage: :fast, terminal: nil} = state, %ReuseCache{} = cache) do
    ReuseCache.validate!(cache)

    unless current_lookahead?(state) and cache.cycle == state.cycle and
             cache.theta_id == state.current_theta_id and
             state.prompt_population.revision == state.cycle do
      raise ArgumentError, "GEPA reuse cache is not bound to the current fast update"
    end

    %{state | reuse_cache: cache}
  end

  @spec claim_cached(t(), String.t(), String.t(), String.t()) ::
          {:ok, Imp.Training.FastSlow.CachedTrajectory.t(), t()} | :miss
  def claim_cached(%__MODULE__{stage: :slow} = state, problem_id, input_digest, prompt_digest) do
    case ReuseCache.claim(state.reuse_cache, problem_id, input_digest, prompt_digest) do
      {:ok, trajectory, cache} -> {:ok, trajectory, %{state | reuse_cache: cache}}
      :miss -> :miss
    end
  end

  @spec put_dataset(t(), DatasetState.t()) :: t()
  def put_dataset(%__MODULE__{terminal: nil, lookahead: nil} = state, %DatasetState{} = dataset),
    do: %{state | dataset: dataset}

  def put_dataset(%__MODULE__{terminal: nil}, %DatasetState{}),
    do: raise(ArgumentError, "dataset cursor may not move while a lookahead is active")

  @spec put_intent(t(), OperationIntent.t()) :: t()
  def put_intent(%__MODULE__{terminal: nil} = state, %OperationIntent{cycle: cycle} = intent)
      when cycle == state.cycle do
    OperationIntent.validate!(intent)

    case Map.fetch(state.pending_operations, intent.id) do
      :error ->
        %{state | pending_operations: Map.put(state.pending_operations, intent.id, intent)}

      {:ok, ^intent} ->
        state

      {:ok, _other} ->
        raise ArgumentError, "operation intent ID collision"
    end
  end

  def put_intent(%__MODULE__{}, %OperationIntent{}),
    do: raise(ArgumentError, "operation intent does not belong to the current cycle")

  @spec reconcile_intent(t(), String.t(), OperationIntent.reconciliation(), term()) :: t()
  def reconcile_intent(%__MODULE__{} = state, id, reconciliation, result \\ nil) do
    intent =
      state.pending_operations
      |> Map.fetch!(id)
      |> OperationIntent.reconcile(reconciliation, result)

    pending =
      if reconciliation in [:confirmed, :failed],
        do: Map.delete(state.pending_operations, id),
        else: Map.put(state.pending_operations, id, intent)

    %{state | pending_operations: pending}
  end

  @spec put_rollout(t(), Rollout.t()) :: t()
  def put_rollout(%__MODULE__{stage: :slow, terminal: nil} = state, %Rollout{} = rollout) do
    Rollout.validate!(rollout)

    unless rollout.cycle == state.cycle and behavior_policy_in_lineage?(state, rollout.theta_id) and
             rollout.prompt_revision == state.prompt_population.revision and
             rollout.sampling_config_digest == state.sampling_config_digest and
             rollout.prompt_index < state.k and rollout.generated_at_step <= state.slow_step do
      raise ArgumentError, "rollout does not match the current cycle identity"
    end

    case Map.fetch(state.rollout_ledger, rollout.id) do
      :error -> %{state | rollout_ledger: Map.put(state.rollout_ledger, rollout.id, rollout)}
      {:ok, ^rollout} -> state
      {:ok, _other} -> raise ArgumentError, "rollout ID collision"
    end
  end

  @spec claim_rollout(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def claim_rollout(%__MODULE__{stage: :slow, terminal: nil} = state, rollout_id, claim_id) do
    with %Rollout{cycle: cycle} = rollout when cycle == state.cycle <-
           Map.get(state.rollout_ledger, rollout_id),
         {:ok, claimed} <- Rollout.claim(rollout, claim_id) do
      {:ok, %{state | rollout_ledger: Map.put(state.rollout_ledger, rollout_id, claimed)}}
    else
      nil -> {:error, :unknown_rollout}
      %Rollout{} -> {:error, :stale_cycle}
      {:error, reason} -> {:error, reason}
    end
  end

  def claim_rollout(%__MODULE__{}, _rollout_id, _claim_id), do: {:error, :invalid_stage}

  @spec complete_rollout(t(), String.t(), String.t(), term(), number(), term()) :: t()
  def complete_rollout(state, rollout_id, claim_id, output, score, metrics) do
    rollout =
      state.rollout_ledger
      |> Map.fetch!(rollout_id)
      |> Rollout.complete!(claim_id, output, score, metrics)

    %{state | rollout_ledger: Map.put(state.rollout_ledger, rollout_id, rollout)}
  end

  @spec validate_complete_group!(t(), String.t()) :: [Rollout.t()]
  def validate_complete_group!(%__MODULE__{} = state, group_id) do
    state.rollout_ledger
    |> Map.values()
    |> Rollout.validate_complete_group!(group_id, state.cycle, state.g, state.k)
  end

  @spec charge_budget(t(), String.t() | atom(), non_neg_integer()) ::
          {:ok, t()} | {:error, :exhausted}
  def charge_budget(%__MODULE__{} = state, key, amount) do
    case Budget.charge(state.budgets, key, amount) do
      {:ok, budgets} -> {:ok, %{state | budgets: budgets}}
      error -> error
    end
  end

  @spec record_event(t(), Event.t()) :: t()
  def record_event(%__MODULE__{} = state, %Event{sequence: sequence, cycle: cycle} = event) do
    unless sequence == length(state.events) and cycle == state.cycle,
      do: raise(ArgumentError, "event sequence or cycle is not current")

    %{state | events: state.events ++ [event]}
  end

  @spec terminate(t(), atom(), term()) :: t()
  def terminate(state, reason, details \\ %{})

  def terminate(
        %__MODULE__{
          stage: :slow,
          terminal: nil,
          slow_step: t,
          t: t,
          cycle: cycle,
          max_cycles: max_cycles
        } = state,
        :completed,
        details
      )
      when cycle + 1 == max_cycles do
    terminal = Terminal.new!(:completed, state.cycle, details)
    %{state | stage: :terminal, terminal: terminal}
  end

  def terminate(%__MODULE__{}, :completed, _details) do
    raise ArgumentError,
          "Fast-Slow training may complete only after t slow updates in the final cycle"
  end

  def terminate(%__MODULE__{terminal: nil} = state, reason, details) do
    terminal = Terminal.new!(reason, state.cycle, details)
    %{state | stage: :terminal, terminal: terminal}
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = state) do
    Enum.each(state.theta_lineage, &Theta.validate!/1)
    PromptPopulation.validate!(state.prompt_population)
    if state.lookahead, do: Lookahead.validate!(state.lookahead, state.t)
    ReuseCache.validate!(state.reuse_cache)
    Budget.validate!(state.budgets)

    Enum.each(state.pending_operations, fn {id, intent} ->
      id == intent.id || invalid!("intent key mismatch")
      OperationIntent.validate!(intent)
    end)

    Enum.each(state.rollout_ledger, fn {id, rollout} ->
      id == rollout.id || invalid!("rollout key mismatch")
      Rollout.validate!(rollout)
    end)

    valid =
      state.stage in @stages and is_integer(state.cycle) and state.cycle >= 0 and
        is_integer(state.t) and state.t > 0 and is_integer(state.max_cycles) and
        state.max_cycles > 0 and state.cycle < state.max_cycles and
        is_boolean(state.reuse_rollouts) and
        is_integer(state.slow_step) and state.slow_step in 0..state.t and
        is_integer(state.k) and state.k > 0 and is_integer(state.g) and state.g > 0 and
        rem(state.g, state.k) == 0 and valid_population?(state) and
        valid_lookahead?(state) and
        valid_reuse_cache?(state) and
        digest?(state.sampling_config_digest) and
        valid_lineage?(state.theta_lineage, state.current_theta_id, state.cycle) and
        length(state.theta_lineage) == state.cycle * state.t + state.slow_step + 1 and
        valid_dataset?(state.dataset) and valid_events?(state.events, state.cycle) and
        valid_terminal?(state.stage, state.terminal, state.cycle) and
        Enum.all?(state.pending_operations, fn {_id, intent} -> intent.cycle == state.cycle end)

    unless valid, do: invalid!("aggregate invariants failed")
    state
  end

  defp valid_lineage?([root | rest], current_id, cycle) do
    root.parent_id == nil and root.cycle == 0 and List.last([root | rest]).id == current_id and
      Enum.reduce_while(rest, root, fn theta, parent ->
        if theta.parent_id == parent.id and theta.cycle >= parent.cycle and theta.cycle <= cycle,
          do: {:cont, theta},
          else: {:halt, false}
      end) != false
  end

  defp valid_lineage?(_, _current_id, _cycle), do: false

  defp valid_population?(%__MODULE__{stage: stage} = state)
       when stage in [:initialized, :fast] do
    old_population =
      state.prompt_population.revision == state.cycle and
        ((state.cycle == 0 and length(state.prompt_population.candidates) == 1) or
           (state.cycle > 0 and length(state.prompt_population.candidates) == state.k))

    revised_population =
      state.stage == :fast and state.prompt_population.revision == state.cycle + 1 and
        length(state.prompt_population.candidates) == state.k and
        current_population_binding?(state)

    old_population or revised_population
  end

  defp valid_population?(%__MODULE__{stage: :terminal} = state) do
    (state.cycle == 0 and length(state.prompt_population.candidates) == 1 and
       state.prompt_population.revision == 0) or
      (state.cycle > 0 and length(state.prompt_population.candidates) == state.k and
         state.prompt_population.revision == state.cycle) or
      (length(state.prompt_population.candidates) == state.k and
         state.prompt_population.revision == state.cycle + 1 and
         terminal_population_binding?(state))
  end

  defp valid_population?(%__MODULE__{} = state) do
    length(state.prompt_population.candidates) == state.k and
      state.prompt_population.revision == state.cycle + 1 and current_population_binding?(state)
  end

  defp valid_lookahead?(%__MODULE__{lookahead: nil} = state) do
    state.stage in [:initialized, :fast, :terminal] and state.slow_step == 0 and
      state.prompt_population.revision == state.cycle
  end

  defp valid_lookahead?(
         %__MODULE__{
           stage: :terminal,
           terminal: %Terminal{reason: :completed},
           lookahead: %Lookahead{} = lookahead
         } = state
       ) do
    lookahead.cycle == state.cycle and lookahead.consumed_steps == state.t and
      length(lookahead.minibatches) == state.t
  end

  defp valid_lookahead?(
         %__MODULE__{stage: :terminal, lookahead: %Lookahead{} = lookahead} = state
       ) do
    current_lookahead?(state) and lookahead.consumed_steps == state.slow_step
  end

  defp valid_lookahead?(%__MODULE__{} = state) do
    current_lookahead?(state) and state.lookahead.consumed_steps == state.slow_step
  end

  defp current_lookahead?(%__MODULE__{lookahead: %Lookahead{} = lookahead} = state) do
    lookahead.cycle == state.cycle and lookahead.dataset_cursor == state.dataset.cursor and
      length(lookahead.minibatches) == state.t
  end

  defp current_lookahead?(%__MODULE__{}), do: false

  defp current_population_binding?(%__MODULE__{} = state) do
    current_lookahead?(state) and
      state.prompt_population.lookahead_digest == state.lookahead.digest and
      is_binary(state.prompt_population.parent_digest) and
      is_binary(state.prompt_population.anchor_digest)
  end

  defp terminal_population_binding?(%__MODULE__{lookahead: %Lookahead{} = lookahead} = state) do
    lookahead.cycle == state.cycle and
      state.prompt_population.lookahead_digest == lookahead.digest and
      is_binary(state.prompt_population.parent_digest) and
      is_binary(state.prompt_population.anchor_digest)
  end

  defp terminal_population_binding?(%__MODULE__{}), do: false

  defp valid_reuse_cache?(state) do
    state.reuse_cache.cycle == state.cycle and
      behavior_policy_in_lineage?(state, state.reuse_cache.theta_id)
  end

  defp behavior_policy_in_lineage?(state, theta_id),
    do: Enum.any?(state.theta_lineage, &(&1.id == theta_id))

  defp valid_dataset?(%DatasetState{cursor: cursor, epoch: epoch})
       when cursor >= 0 and epoch >= 0,
       do: true

  defp valid_dataset?(_dataset), do: false

  defp valid_events?(events, cycle) do
    Enum.with_index(events)
    |> Enum.all?(fn {%Event{sequence: sequence, cycle: event_cycle}, index} ->
      sequence == index and event_cycle <= cycle
    end)
  end

  defp valid_terminal?(:terminal, %Terminal{cycle: cycle}, cycle), do: true
  defp valid_terminal?(stage, nil, _cycle), do: stage != :terminal
  defp valid_terminal?(_stage, _terminal, _cycle), do: false

  defp invalid!(message), do: raise(ArgumentError, "invalid Fast-Slow state: #{message}")

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end

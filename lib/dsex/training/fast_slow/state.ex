defmodule DSEx.Training.FastSlow.Theta do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

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

defmodule DSEx.Training.FastSlow.PromptPopulation do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

  @enforce_keys [:revision, :digest, :candidates]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          digest: String.t(),
          candidates: [Config.json_value()]
        }

  @spec new!(non_neg_integer(), [term()]) :: t()
  def new!(revision, candidates)
      when is_integer(revision) and revision >= 0 and is_list(candidates) and candidates != [] do
    candidates = Config.json_safe!(candidates, [:prompt_population, :candidates])
    %__MODULE__{revision: revision, digest: Config.digest(candidates), candidates: candidates}
  end

  def new!(_revision, _candidates),
    do: raise(ArgumentError, "prompt population requires a revision and non-empty candidates")

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = population) do
    expected = new!(population.revision, population.candidates)

    unless expected.digest == population.digest,
      do: raise(ArgumentError, "prompt population digest is invalid")

    population
  end
end

defmodule DSEx.Training.FastSlow.DatasetState do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

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

defmodule DSEx.Training.FastSlow.Budget do
  @moduledoc false

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

defmodule DSEx.Training.FastSlow.Terminal do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

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

defmodule DSEx.Training.FastSlow.State do
  @moduledoc false

  alias DSEx.Training.FastSlow.{
    Budget,
    Config,
    DatasetState,
    Event,
    OperationIntent,
    PromptPopulation,
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
    :stage,
    :cycle,
    :slow_step,
    :theta_lineage,
    :current_theta_id,
    :prompt_population,
    :dataset,
    :budgets
  ]
  defstruct @enforce_keys ++
              [pending_operations: %{}, rollout_ledger: %{}, events: [], terminal: nil]

  @type t :: %__MODULE__{
          config_fingerprint: String.t(),
          sampling_config_digest: String.t(),
          t: pos_integer(),
          k: pos_integer(),
          g: pos_integer(),
          max_cycles: pos_integer(),
          stage: :initialized | :fast | :slow | :terminal,
          cycle: non_neg_integer(),
          slow_step: non_neg_integer(),
          theta_lineage: [Theta.t()],
          current_theta_id: String.t(),
          prompt_population: PromptPopulation.t(),
          dataset: DatasetState.t(),
          pending_operations: %{String.t() => OperationIntent.t()},
          budgets: Budget.t(),
          rollout_ledger: %{String.t() => Rollout.t()},
          events: [Event.t()],
          terminal: Terminal.t() | nil
        }

  @spec new!(Config.t(), term(), [term()], keyword()) :: t()
  def new!(%Config{} = config, theta_payload, prompt_candidates, options \\ []) do
    unless length(prompt_candidates) in 1..config.k,
      do: raise(ArgumentError, "seed prompt population must contain between one and k candidates")

    theta = Theta.new!(0, theta_payload)
    dataset = DatasetState.new!(0, 0, Keyword.get(options, :rng, %{"seed" => 0}))
    budgets = Budget.new!(Keyword.get(options, :budgets, %{"operations" => 1_000_000}))

    %__MODULE__{
      config_fingerprint: Config.fingerprint(config),
      sampling_config_digest: Config.digest(config.sampling_config),
      t: config.t,
      k: config.k,
      g: config.g,
      max_cycles: config.max_cycles,
      stage: :initialized,
      cycle: 0,
      slow_step: 0,
      theta_lineage: [theta],
      current_theta_id: theta.id,
      prompt_population: PromptPopulation.new!(0, prompt_candidates),
      dataset: dataset,
      budgets: budgets
    }
  end

  @spec set_stage(t(), :fast | :slow) :: t()
  def set_stage(%__MODULE__{stage: stage} = state, next) when next in [:fast, :slow] do
    allowed = {stage, next} in [{:initialized, :fast}, {:fast, :slow}]

    unless allowed,
      do: raise(ArgumentError, "invalid Fast-Slow stage transition #{stage} -> #{next}")

    if next == :slow and
         (length(state.prompt_population.candidates) != state.k or
            state.prompt_population.revision != state.cycle + 1) do
      raise ArgumentError,
            "slow stage requires a current-cycle GEPA population of exactly k candidates"
    end

    %{state | stage: next}
  end

  @spec next_cycle(t(), DatasetState.t()) :: t()
  def next_cycle(%__MODULE__{stage: :slow, terminal: nil} = state, %DatasetState{} = dataset) do
    unless state.slow_step == state.t,
      do: raise(ArgumentError, "configured Fast-Slow cycle has incomplete slow updates")

    unless state.cycle + 1 < state.max_cycles,
      do: raise(ArgumentError, "configured Fast-Slow cycle horizon is exhausted")

    %{state | stage: :fast, cycle: state.cycle + 1, slow_step: 0, dataset: dataset}
  end

  def next_cycle(%__MODULE__{}, %DatasetState{}),
    do: raise(ArgumentError, "a new cycle may only follow the slow stage")

  @spec complete_slow_step(t(), term()) :: t()
  def complete_slow_step(%__MODULE__{stage: :slow, terminal: nil} = state, payload) do
    unless state.slow_step < state.t,
      do: raise(ArgumentError, "configured Fast-Slow cycle already has t slow updates")

    theta = Theta.new!(state.cycle, payload, state.current_theta_id)

    %{
      state
      | theta_lineage: state.theta_lineage ++ [theta],
        current_theta_id: theta.id,
        slow_step: state.slow_step + 1
    }
  end

  def complete_slow_step(%__MODULE__{}, _payload),
    do: raise(ArgumentError, "a slow update may only complete during the slow stage")

  @spec revise_prompts(t(), [term()]) :: t()
  def revise_prompts(%__MODULE__{stage: :fast, terminal: nil} = state, candidates) do
    unless length(candidates) == state.k,
      do: raise(ArgumentError, "active prompt population must contain exactly k candidates")

    unless state.prompt_population.revision == state.cycle,
      do: raise(ArgumentError, "GEPA prompt population was already revised for this cycle")

    revision = state.prompt_population.revision + 1
    %{state | prompt_population: PromptPopulation.new!(revision, candidates)}
  end

  def revise_prompts(%__MODULE__{}, _candidates),
    do: raise(ArgumentError, "prompts may only be revised during the fast stage")

  @spec put_dataset(t(), DatasetState.t()) :: t()
  def put_dataset(%__MODULE__{terminal: nil} = state, %DatasetState{} = dataset),
    do: %{state | dataset: dataset}

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

    unless rollout.cycle == state.cycle and rollout.theta_id == state.current_theta_id and
             rollout.prompt_revision == state.prompt_population.revision and
             rollout.sampling_config_digest == state.sampling_config_digest and
             rollout.prompt_index < state.k do
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
        is_integer(state.slow_step) and state.slow_step in 0..state.t and
        is_integer(state.k) and state.k > 0 and is_integer(state.g) and state.g > 0 and
        rem(state.g, state.k) == 0 and valid_population?(state) and
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
    length(state.prompt_population.candidates) in 1..state.k and
      state.prompt_population.revision == state.cycle
  end

  defp valid_population?(%__MODULE__{stage: :terminal} = state) do
    (length(state.prompt_population.candidates) in 1..state.k and
       state.prompt_population.revision == state.cycle) or
      (length(state.prompt_population.candidates) == state.k and
         state.prompt_population.revision == state.cycle + 1)
  end

  defp valid_population?(%__MODULE__{} = state) do
    length(state.prompt_population.candidates) == state.k and
      state.prompt_population.revision == state.cycle + 1
  end

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

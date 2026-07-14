defmodule DSEx.Training.FastSlow.Checkpoint do
  @moduledoc "Versioned, checksummed persistence for Fast-Slow training state."

  alias DSEx.Training.FastSlow.{
    Budget,
    Config,
    DatasetState,
    Event,
    Lookahead,
    OperationIntent,
    PromptPopulation,
    ReuseCache,
    Rollout,
    State,
    Terminal,
    Theta
  }

  @type_name "dsex_fast_slow_training"
  @schema_version 4

  @spec dump(Config.t(), State.t()) :: map()
  def dump(%Config{} = config, %State{} = state) do
    State.validate!(state)

    unless state.config_fingerprint == Config.fingerprint(config) and state.t == config.t and
             state.k == config.k and state.g == config.g and
             state.max_cycles == config.max_cycles and
             state.sampling_config_digest == Config.digest(config.sampling_config),
           do: raise(ArgumentError, "Fast-Slow state does not match the supplied configuration")

    payload =
      Config.persisted_safe!(%{
        "compatibility" => Config.compatibility(config),
        "state" => dump_state(state)
      })

    checkpoint = %{
      "type" => @type_name,
      "schema_version" => @schema_version,
      "payload_sha256" => checksum(payload),
      "payload" => payload
    }

    Jason.encode!(checkpoint)
    checkpoint
  end

  @spec load!(map(), Config.t()) :: State.t()
  def load!(%{"type" => @type_name, "schema_version" => 1}, %Config{}) do
    raise ArgumentError,
          "Fast-Slow checkpoint schema 1 encoded t as a cycle horizon and cannot be resumed faithfully"
  end

  def load!(%{"type" => @type_name, "schema_version" => 2}, %Config{}) do
    raise ArgumentError,
          "Fast-Slow checkpoint schema 2 omitted durable rollout reuse and token provenance"
  end

  def load!(%{"type" => @type_name, "schema_version" => 3}, %Config{}) do
    raise ArgumentError,
          "Fast-Slow checkpoint schema 3 did not persist the rollout reuse policy"
  end

  def load!(checkpoint, %Config{} = config) when is_map(checkpoint) do
    with %{
           "type" => @type_name,
           "schema_version" => @schema_version,
           "payload_sha256" => digest,
           "payload" => %{"compatibility" => compatibility, "state" => state_data} = payload
         }
         when is_binary(digest) and is_map(compatibility) and is_map(state_data) <- checkpoint do
      unless secure_equal?(checksum(payload), digest),
        do: raise(ArgumentError, "Fast-Slow checkpoint checksum does not match its payload")

      unless compatibility == Config.compatibility(config),
        do: raise(ArgumentError, "Fast-Slow checkpoint compatibility does not match this run")

      state = load_state!(state_data)

      unless state.config_fingerprint == Config.fingerprint(config) and state.t == config.t and
               state.k == config.k and state.g == config.g and
               state.max_cycles == config.max_cycles and
               state.sampling_config_digest == Config.digest(config.sampling_config),
             do: raise(ArgumentError, "Fast-Slow checkpoint state fingerprint is inconsistent")

      State.validate!(state)
    else
      _value -> raise ArgumentError, "invalid Fast-Slow checkpoint envelope or schema version"
    end
  rescue
    error in [KeyError, ArgumentError, FunctionClauseError] ->
      reraise ArgumentError,
              [message: "invalid Fast-Slow checkpoint: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(_checkpoint, %Config{}),
    do: raise(ArgumentError, "invalid Fast-Slow checkpoint envelope")

  @spec encode!(Config.t(), State.t()) :: String.t()
  def encode!(%Config{} = config, %State{} = state), do: config |> dump(state) |> Jason.encode!()

  @spec read!(Path.t(), Config.t()) :: State.t()
  def read!(path, %Config{} = config) do
    path |> File.read!() |> Jason.decode!() |> load!(config)
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError] ->
      reraise ArgumentError,
              [message: "could not read Fast-Slow checkpoint: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  @spec write!(Path.t(), Config.t(), State.t()) :: :ok
  def write!(path, %Config{} = config, %State{} = state) when is_binary(path) do
    bytes = encode!(config, state)
    directory = Path.dirname(path)
    File.mkdir_p!(directory)

    temporary =
      Path.join(
        directory,
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      {:ok, file} = :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive])

      try do
        :ok = :file.write(file, bytes)
        :ok = :file.sync(file)
      after
        :ok = :file.close(file)
      end

      :ok = File.rename(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp dump_state(state) do
    %{
      "config_fingerprint" => state.config_fingerprint,
      "sampling_config_digest" => state.sampling_config_digest,
      "t" => state.t,
      "k" => state.k,
      "g" => state.g,
      "max_cycles" => state.max_cycles,
      "reuse_rollouts" => state.reuse_rollouts,
      "stage" => Atom.to_string(state.stage),
      "cycle" => state.cycle,
      "slow_step" => state.slow_step,
      "theta_lineage" => Enum.map(state.theta_lineage, &dump_theta/1),
      "current_theta_id" => state.current_theta_id,
      "prompt_population" => dump_population(state.prompt_population),
      "dataset" => dump_dataset(state.dataset),
      "lookahead" => if(state.lookahead, do: dump_lookahead(state.lookahead), else: nil),
      "reuse_cache" => ReuseCache.dump(state.reuse_cache),
      "pending_operations" =>
        state.pending_operations
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&dump_intent/1),
      "budgets" => %{"limits" => state.budgets.limits, "used" => state.budgets.used},
      "rollout_ledger" =>
        state.rollout_ledger |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&dump_rollout/1),
      "events" => Enum.map(state.events, &dump_event/1),
      "terminal" => if(state.terminal, do: dump_terminal(state.terminal), else: nil)
    }
  end

  defp dump_theta(theta) do
    %{
      "id" => theta.id,
      "digest" => theta.digest,
      "cycle" => theta.cycle,
      "parent_id" => theta.parent_id,
      "payload" => theta.payload
    }
  end

  defp dump_population(population) do
    %{
      "revision" => population.revision,
      "digest" => population.digest,
      "candidates" => population.candidates,
      "candidate_ids" => population.candidate_ids,
      "instance_scores" => population.instance_scores,
      "instance_frontier" => population.instance_frontier,
      "parent_digest" => population.parent_digest,
      "anchor_digest" => population.anchor_digest,
      "lookahead_digest" => population.lookahead_digest
    }
  end

  defp dump_lookahead(lookahead) do
    %{
      "cycle" => lookahead.cycle,
      "dataset_cursor" => lookahead.dataset_cursor,
      "digest" => lookahead.digest,
      "checksum" => lookahead.checksum,
      "minibatches" => lookahead.minibatches,
      "consumed_steps" => lookahead.consumed_steps
    }
  end

  defp dump_dataset(dataset),
    do: %{"cursor" => dataset.cursor, "epoch" => dataset.epoch, "rng" => dataset.rng}

  defp dump_intent(intent) do
    %{
      "id" => intent.id,
      "kind" => intent.kind,
      "cycle" => intent.cycle,
      "payload_digest" => intent.payload_digest,
      "payload" => intent.payload,
      "reconciliation" => Atom.to_string(intent.reconciliation),
      "attempts" => intent.attempts,
      "result" => intent.result
    }
  end

  defp dump_rollout(rollout) do
    %{
      "id" => rollout.id,
      "identity_digest" => rollout.identity_digest,
      "cycle" => rollout.cycle,
      "group_id" => rollout.group_id,
      "problem_id" => rollout.problem_id,
      "group_size" => rollout.group_size,
      "member_index" => rollout.member_index,
      "prompt_index" => rollout.prompt_index,
      "theta_id" => rollout.theta_id,
      "prompt_revision" => rollout.prompt_revision,
      "dataset_indices" => rollout.dataset_indices,
      "input_digest" => rollout.input_digest,
      "prompt_digest" => rollout.prompt_digest,
      "behavior_policy_id" => rollout.behavior_policy_id,
      "sampling_config_digest" => rollout.sampling_config_digest,
      "behavior_logprobs" => rollout.behavior_logprobs,
      "response_token_ids" => rollout.response_token_ids,
      "response_mask" => rollout.response_mask,
      "source" => Atom.to_string(rollout.source),
      "generated_at_step" => rollout.generated_at_step,
      "status" => Atom.to_string(rollout.status),
      "claim_id" => rollout.claim_id,
      "output" => rollout.output,
      "output_digest" => rollout.output_digest,
      "score" => rollout.score,
      "metrics" => rollout.metrics,
      "failure" => rollout.failure
    }
  end

  defp dump_event(event) do
    %{
      "sequence" => event.sequence,
      "kind" => event.kind,
      "cycle" => event.cycle,
      "operation_id" => event.operation_id,
      "at" => event.at,
      "data" => event.data
    }
  end

  defp dump_terminal(terminal),
    do: %{
      "reason" => Atom.to_string(terminal.reason),
      "cycle" => terminal.cycle,
      "details" => terminal.details
    }

  defp load_state!(data) do
    %State{
      config_fingerprint: string!(data, "config_fingerprint"),
      sampling_config_digest: string!(data, "sampling_config_digest"),
      t: positive!(data, "t"),
      k: positive!(data, "k"),
      g: positive!(data, "g"),
      max_cycles: positive!(data, "max_cycles"),
      reuse_rollouts: boolean!(data, "reuse_rollouts"),
      stage:
        enum!(data, "stage",
          initialized: :initialized,
          fast: :fast,
          slow: :slow,
          terminal: :terminal
        ),
      cycle: non_negative!(data, "cycle"),
      slow_step: non_negative!(data, "slow_step"),
      theta_lineage: list!(data, "theta_lineage", &load_theta!/1),
      current_theta_id: string!(data, "current_theta_id"),
      prompt_population: data |> Map.fetch!("prompt_population") |> load_population!(),
      dataset: data |> Map.fetch!("dataset") |> load_dataset!(),
      lookahead: load_optional(data, "lookahead", &load_lookahead!/1),
      reuse_cache: data |> Map.fetch!("reuse_cache") |> ReuseCache.load!(),
      pending_operations:
        data
        |> list!("pending_operations", &load_intent!/1)
        |> unique_map!(& &1.id, "operation intent"),
      budgets: data |> Map.fetch!("budgets") |> load_budget!(),
      rollout_ledger:
        data |> list!("rollout_ledger", &load_rollout!/1) |> unique_map!(& &1.id, "rollout"),
      events: list!(data, "events", &load_event!/1),
      terminal: load_optional(data, "terminal", &load_terminal!/1)
    }
  end

  defp load_theta!(data) when is_map(data) do
    theta = %Theta{
      id: string!(data, "id"),
      digest: string!(data, "digest"),
      cycle: non_negative!(data, "cycle"),
      parent_id: optional_string!(data, "parent_id"),
      payload: Map.fetch!(data, "payload")
    }

    Theta.validate!(theta)
  end

  defp load_population!(data) when is_map(data) do
    population = %PromptPopulation{
      revision: non_negative!(data, "revision"),
      digest: string!(data, "digest"),
      candidates: raw_list!(data, "candidates"),
      candidate_ids: string_list!(data, "candidate_ids"),
      instance_scores: map!(data, "instance_scores"),
      instance_frontier: map!(data, "instance_frontier"),
      parent_digest: optional_string!(data, "parent_digest"),
      anchor_digest: optional_string!(data, "anchor_digest"),
      lookahead_digest: optional_string!(data, "lookahead_digest")
    }

    PromptPopulation.validate!(population)
  end

  defp load_lookahead!(data) when is_map(data) do
    lookahead =
      Lookahead.new!(
        non_negative!(data, "cycle"),
        non_negative!(data, "dataset_cursor"),
        raw_list!(data, "minibatches")
      )

    lookahead = %{
      lookahead
      | digest: string!(data, "digest"),
        checksum: string!(data, "checksum"),
        consumed_steps: non_negative!(data, "consumed_steps")
    }

    Lookahead.validate!(lookahead)
  end

  defp load_dataset!(data) when is_map(data),
    do:
      DatasetState.new!(
        non_negative!(data, "cursor"),
        non_negative!(data, "epoch"),
        Map.fetch!(data, "rng")
      )

  defp load_budget!(data) when is_map(data) do
    budget = %Budget{limits: map!(data, "limits"), used: map!(data, "used")}
    Budget.validate!(budget)
  end

  defp load_intent!(data) when is_map(data) do
    intent = %OperationIntent{
      id: string!(data, "id"),
      kind: string!(data, "kind"),
      cycle: non_negative!(data, "cycle"),
      payload_digest: string!(data, "payload_digest"),
      payload: Map.fetch!(data, "payload"),
      reconciliation:
        enum!(data, "reconciliation",
          unreconciled: :unreconciled,
          confirmed: :confirmed,
          retryable: :retryable,
          failed: :failed
        ),
      attempts: non_negative!(data, "attempts"),
      result: Map.fetch!(data, "result")
    }

    OperationIntent.validate!(intent)
  end

  defp load_rollout!(data) when is_map(data) do
    rollout = %Rollout{
      id: string!(data, "id"),
      identity_digest: string!(data, "identity_digest"),
      cycle: non_negative!(data, "cycle"),
      group_id: string!(data, "group_id"),
      problem_id: string!(data, "problem_id"),
      group_size: positive!(data, "group_size"),
      member_index: non_negative!(data, "member_index"),
      prompt_index: non_negative!(data, "prompt_index"),
      theta_id: string!(data, "theta_id"),
      prompt_revision: non_negative!(data, "prompt_revision"),
      dataset_indices: integer_list!(data, "dataset_indices"),
      input_digest: string!(data, "input_digest"),
      prompt_digest: string!(data, "prompt_digest"),
      behavior_policy_id: string!(data, "behavior_policy_id"),
      sampling_config_digest: string!(data, "sampling_config_digest"),
      behavior_logprobs: number_list!(data, "behavior_logprobs"),
      response_token_ids: integer_list!(data, "response_token_ids"),
      response_mask: integer_list!(data, "response_mask"),
      source: enum!(data, "source", live: :live, gepa_cache: :gepa_cache),
      generated_at_step: non_negative!(data, "generated_at_step"),
      status:
        enum!(data, "status",
          available: :available,
          claimed: :claimed,
          complete: :complete,
          failed: :failed
        ),
      claim_id: optional_string!(data, "claim_id"),
      output: Map.fetch!(data, "output"),
      output_digest: optional_string!(data, "output_digest"),
      score: optional_number!(data, "score"),
      metrics: Map.fetch!(data, "metrics"),
      failure: Map.fetch!(data, "failure")
    }

    Rollout.validate!(rollout)
  end

  defp load_event!(data) when is_map(data) do
    Event.new!(%{
      sequence: non_negative!(data, "sequence"),
      kind: string!(data, "kind"),
      cycle: non_negative!(data, "cycle"),
      operation_id: optional_string!(data, "operation_id"),
      at: optional_string!(data, "at"),
      data: Map.fetch!(data, "data")
    })
  end

  defp load_terminal!(data) when is_map(data) do
    Terminal.new!(
      enum!(data, "reason",
        completed: :completed,
        budget_exhausted: :budget_exhausted,
        failed: :failed,
        cancelled: :cancelled
      ),
      non_negative!(data, "cycle"),
      Map.fetch!(data, "details")
    )
  end

  defp list!(data, key, loader) do
    data |> raw_list!(key) |> Enum.map(loader)
  end

  defp raw_list!(data, key) do
    case Map.fetch!(data, key) do
      value when is_list(value) -> value
      _value -> raise ArgumentError, "#{key} must be a list"
    end
  end

  defp map!(data, key) do
    case Map.fetch!(data, key) do
      value when is_map(value) -> value
      _value -> raise ArgumentError, "#{key} must be a map"
    end
  end

  defp string!(data, key) do
    case Map.fetch!(data, key) do
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end

  defp optional_string!(data, key) do
    case Map.fetch!(data, key) do
      nil -> nil
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "#{key} must be a non-empty string or nil"
    end
  end

  defp non_negative!(data, key) do
    case Map.fetch!(data, key) do
      value when is_integer(value) and value >= 0 -> value
      _value -> raise ArgumentError, "#{key} must be a non-negative integer"
    end
  end

  defp positive!(data, key) do
    case Map.fetch!(data, key) do
      value when is_integer(value) and value > 0 -> value
      _value -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp boolean!(data, key) do
    case Map.fetch!(data, key) do
      value when is_boolean(value) -> value
      _value -> raise ArgumentError, "#{key} must be a boolean"
    end
  end

  defp optional_number!(data, key) do
    case Map.fetch!(data, key) do
      nil -> nil
      value when is_number(value) -> value
      _value -> raise ArgumentError, "#{key} must be a number or nil"
    end
  end

  defp integer_list!(data, key) do
    values = raw_list!(data, key)

    if Enum.all?(values, &(is_integer(&1) and &1 >= 0)),
      do: values,
      else: raise(ArgumentError, "#{key} must contain non-negative integers")
  end

  defp number_list!(data, key) do
    values = raw_list!(data, key)

    if values != [] and Enum.all?(values, &is_number/1),
      do: values,
      else: raise(ArgumentError, "#{key} must contain numbers")
  end

  defp string_list!(data, key) do
    values = raw_list!(data, key)

    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: values,
      else: raise(ArgumentError, "#{key} must contain non-empty strings")
  end

  defp enum!(data, key, allowed) do
    value = string!(data, key)

    case Enum.find(allowed, fn {name, _atom} -> Atom.to_string(name) == value end) do
      {_name, atom} -> atom
      nil -> raise ArgumentError, "#{key} has an unsupported value"
    end
  end

  defp unique_map!(values, key_fun, label) do
    result = Map.new(values, &{key_fun.(&1), &1})

    if map_size(result) == length(values),
      do: result,
      else: raise(ArgumentError, "duplicate #{label} ID")
  end

  defp load_optional(data, key, loader) do
    case Map.fetch!(data, key) do
      nil -> nil
      value -> loader.(value)
    end
  end

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end

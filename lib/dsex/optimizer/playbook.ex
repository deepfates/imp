defmodule DSEx.Optimizer.Playbook do
  @behaviour DSEx.Optimizer
  @moduledoc """
  Bounded optimization for persistent `DSEx.Playbook` parameters.

  The proposer receives training trajectories only. Challenger promotion requires
  improvement on source- and group-disjoint promotion and audit splits, bounded
  retained growth, and a content/provenance leakage audit. Every callback runs
  under a declared reservation and returns authoritative usage accounting.

  This is an Elixir-native adaptation of the incremental context-learning loop
  explored by Dynamic Cheatsheet and ACE. It uses DSEx's normal program
  parameter and trajectory contracts; it is not a second agent-memory runtime.
  """

  alias DSEx.Optimizer.Trajectory
  alias DSEx.Optimizer.Trajectory.Parameter
  alias DSEx.Playbook, as: Context
  alias DSEx.Playbook.{Canonical, Delta, Entry}
  alias DSEx.ProgramParameters

  @stages [
    :training_evaluation,
    :proposal,
    :baseline_promotion,
    :candidate_promotion,
    :baseline_audit,
    :candidate_audit
  ]
  @usage_authorities [:provider_reported, :derived, :free]

  @enforce_keys [:proposer, :evaluator, :reservations, :budget]
  defstruct [
    :proposer,
    :evaluator,
    :reservations,
    :budget,
    parameter: :playbook,
    min_lift: 0.0,
    max_growth_bytes: 16_384,
    max_growth_ratio: 2.0,
    authority_source_ids: [],
    checkpoint_fn: nil
  ]

  defmodule Usage do
    @moduledoc "Provider usage admitted by the playbook optimizer."
    @enforce_keys [:requests, :input_tokens, :output_tokens, :cost_usd, :authority]
    defstruct [:requests, :input_tokens, :output_tokens, :cost_usd, :authority, models: []]
  end

  defmodule Result do
    @moduledoc "A promoted or rejected playbook challenger with rollback state."
    @enforce_keys [
      :program,
      :baseline_program,
      :candidate_program,
      :baseline_playbook,
      :candidate_playbook,
      :promoted?,
      :scores,
      :usage,
      :trajectories,
      :checkpoint,
      :rejection_reasons,
      :parameter
    ]
    defstruct [
      :program,
      :baseline_program,
      :candidate_program,
      :baseline_playbook,
      :candidate_playbook,
      :promoted?,
      :scores,
      :usage,
      :trajectories,
      :checkpoint,
      :rejection_reasons,
      :parameter
    ]

    @type t :: %__MODULE__{}
  end

  @type row :: %{
          required(String.t()) => term()
        }

  @doc "Builds a validated optimizer configuration."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    optimizer = %__MODULE__{
      proposer: Keyword.fetch!(opts, :proposer),
      evaluator: Keyword.fetch!(opts, :evaluator),
      reservations: normalize_reservations!(Keyword.fetch!(opts, :reservations)),
      budget: normalize_usage!(Keyword.fetch!(opts, :budget), :budget),
      parameter: Keyword.get(opts, :parameter, :playbook),
      min_lift: Keyword.get(opts, :min_lift, 0.0),
      max_growth_bytes: Keyword.get(opts, :max_growth_bytes, 16_384),
      max_growth_ratio: Keyword.get(opts, :max_growth_ratio, 2.0),
      authority_source_ids: Keyword.get(opts, :authority_source_ids, []),
      checkpoint_fn: Keyword.get(opts, :checkpoint_fn)
    }

    validate_optimizer!(optimizer)
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :workflow,
      datasets: %{
        trainset: :required,
        promotionset: :required,
        auditset: :required,
        validation: :unsupported
      },
      result: :workflow_result
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with {:ok, promotionset} <- Keyword.fetch(opts, :promotionset),
         {:ok, auditset} <- Keyword.fetch(opts, :auditset) do
      compile_opts =
        opts
        |> DSEx.Optimizer.invocation_options()
        |> Keyword.drop([:promotionset, :auditset])

      compile(
        optimizer,
        program,
        DSEx.Optimizer.fetch_dataset!(opts, :trainset),
        promotionset,
        auditset,
        compile_opts
      )
    else
      :error -> {:error, :playbook_splits_required}
    end
  end

  @type t :: %__MODULE__{}

  @doc "Proposes, evaluates, and transactionally promotes one playbook delta."
  @spec compile(t(), struct(), [row()], [row()], [row()], keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def compile(%__MODULE__{} = optimizer, program, trainset, promotionset, auditset, opts \\ []) do
    with {:ok, optimizer, opts} <- apply_runtime_options(optimizer, opts),
         :ok <- validate_compile_options(opts),
         {:ok, baseline} <- fetch_playbook(program, optimizer.parameter),
         {:ok, splits} <- validate_splits(trainset, promotionset, auditset),
         identity <- identity(optimizer, baseline, splits),
         :ok <- validate_reservation_budget(optimizer),
         :fresh <- resume_mode(Keyword.get(opts, :resume_state), identity) do
      run(optimizer, program, baseline, splits, identity)
    else
      {:restored, checkpoint} -> restore(checkpoint, program, optimizer.parameter)
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:optimizer_exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:optimizer_throw, kind, reason}}
  end

  @doc "Restores a completed checkpoint against fresh runtime-bound program callbacks."
  @spec restore(map(), struct(), ProgramParameters.name()) :: {:ok, Result.t()} | {:error, term()}
  def restore(checkpoint, program, parameter \\ :playbook) do
    with {:ok, payload} <- verify_checkpoint(checkpoint),
         "complete" <- payload["status"],
         {:ok, live_playbook} <- fetch_playbook(program, parameter),
         true <- live_playbook.hash == payload["identity"]["baseline_playbook_hash"],
         {:ok, result} <- restore_result(payload, program, parameter) do
      {:ok, result}
    else
      "started" -> {:error, {:ambiguous_started_checkpoint, checkpoint["payload"]["stage"]}}
      false -> {:error, :checkpoint_baseline_mismatch}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_checkpoint, other}}
    end
  rescue
    error -> {:error, {:invalid_checkpoint, Exception.message(error)}}
  end

  @doc "Returns the exact pre-promotion program preserved by a result."
  @spec rollback(Result.t()) :: struct()
  def rollback(%Result{
        baseline_program: program,
        baseline_playbook: baseline,
        parameter: parameter
      }) do
    case fetch_playbook(program, parameter) do
      {:ok, %Context{hash: hash}} when hash == baseline.hash -> program
      _ -> raise ArgumentError, "playbook rollback state is inconsistent"
    end
  end

  @doc "Returns active and historical retained semantic bytes."
  @spec retained_bytes(Context.t()) :: non_neg_integer()
  def retained_bytes(%Context{} = playbook) do
    Enum.reduce(playbook.entries, 0, &(Entry.semantic_bytes(&1) + &2)) +
      Enum.reduce(playbook.tombstones, 0, &(Entry.semantic_bytes(&1.entry) + &2))
  end

  defp run(optimizer, program, baseline, splits, identity) do
    state = %{usage: zero_usage(), trajectories: %{}}

    with {:ok, training, state} <-
           evaluate_stage(
             optimizer,
             :training_evaluation,
             program,
             splits.train,
             state,
             identity,
             baseline
           ),
         {:ok, delta, state} <-
           proposal_stage(optimizer, program, baseline, splits.train, training, state, identity),
         {:ok, candidate} <- Context.apply_delta(baseline, delta),
         :ok <- growth_gate(optimizer, baseline, candidate),
         :ok <- leakage_gate(optimizer, baseline, candidate, splits),
         candidate_program <-
           ProgramParameters.put_playbook(program, optimizer.parameter, candidate),
         {:ok, baseline_promotion, state} <-
           evaluate_stage(
             optimizer,
             :baseline_promotion,
             program,
             splits.promotion,
             state,
             identity,
             baseline
           ),
         {:ok, candidate_promotion, state} <-
           evaluate_stage(
             optimizer,
             :candidate_promotion,
             candidate_program,
             splits.promotion,
             state,
             identity,
             candidate
           ),
         {:ok, baseline_audit, state} <-
           evaluate_stage(
             optimizer,
             :baseline_audit,
             program,
             splits.audit,
             state,
             identity,
             baseline
           ),
         {:ok, candidate_audit, state} <-
           evaluate_stage(
             optimizer,
             :candidate_audit,
             candidate_program,
             splits.audit,
             state,
             identity,
             candidate
           ) do
      scores = %{
        baseline_promotion: mean_score(baseline_promotion),
        candidate_promotion: mean_score(candidate_promotion),
        baseline_audit: mean_score(baseline_audit),
        candidate_audit: mean_score(candidate_audit)
      }

      reasons = rejection_reasons(scores, optimizer.min_lift)
      promoted? = reasons == []

      build_result(
        optimizer,
        identity,
        program,
        candidate_program,
        baseline,
        candidate,
        promoted?,
        scores,
        state,
        reasons
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp evaluate_stage(optimizer, stage, program, rows, state, identity, playbook) do
    reservation = Map.fetch!(optimizer.reservations, stage)
    emit_started(optimizer, identity, stage, state.usage)

    context = %{
      stage: stage,
      reservation: reservation,
      playbook: playbook,
      parameter: optimizer.parameter
    }

    case optimizer.evaluator.(program, rows, context) do
      {:ok, trajectories, usage} ->
        with {:ok, usage} <- admit_usage(usage, reservation, stage),
             {:ok, trajectories} <- admit_trajectories(trajectories, rows, playbook),
             {:ok, aggregate} <- add_usage(state.usage, usage, optimizer.budget) do
          {:ok, trajectories,
           %{
             state
             | usage: aggregate,
               trajectories: Map.put(state.trajectories, stage, trajectories)
           }}
        end

      {:error, reason, usage} ->
        case admit_usage(usage, reservation, stage) do
          {:ok, admitted} -> {:error, {:evaluation_failed, stage, reason, dump_usage(admitted)}}
          {:error, accounting_reason} -> {:error, accounting_reason}
        end

      other ->
        {:error, {:invalid_evaluator_result, stage, result_shape(other)}}
    end
  end

  defp proposal_stage(optimizer, program, baseline, rows, trajectories, state, identity) do
    stage = :proposal
    reservation = Map.fetch!(optimizer.reservations, stage)
    emit_started(optimizer, identity, stage, state.usage)

    request = %{
      program: program,
      playbook: baseline,
      rows: rows,
      trajectories: trajectories,
      reservation: reservation,
      parameter: optimizer.parameter
    }

    case optimizer.proposer.(request) do
      {:ok, %Delta{} = delta, usage} ->
        with {:ok, usage} <- admit_usage(usage, reservation, stage),
             {:ok, aggregate} <- add_usage(state.usage, usage, optimizer.budget) do
          {:ok, delta, %{state | usage: aggregate}}
        end

      {:error, reason, usage} ->
        case admit_usage(usage, reservation, stage) do
          {:ok, admitted} -> {:error, {:proposal_failed, reason, dump_usage(admitted)}}
          {:error, accounting_reason} -> {:error, accounting_reason}
        end

      other ->
        {:error, {:invalid_proposer_result, result_shape(other)}}
    end
  end

  defp admit_trajectories(trajectories, rows, playbook) when is_list(trajectories) do
    if length(trajectories) != length(rows) do
      {:error, {:trajectory_count_mismatch, length(rows), length(trajectories)}}
    else
      try do
        admitted =
          trajectories
          |> Enum.with_index()
          |> Enum.map(fn {%Trajectory{} = trajectory, index} ->
            if trajectory.index != index or trajectory.error != nil or
                 not valid_score?(trajectory.score) do
              raise ArgumentError, "invalid playbook evaluation trajectory at index #{index}"
            end

            parameter = %Parameter{
              name: :playbook,
              kind: :playbook,
              value: playbook.hash,
              metadata: %{id: playbook.id, revision: playbook.revision}
            }

            existing = Enum.reject(trajectory.named_parameters, &playbook_parameter?/1)

            Trajectory.project(trajectory.runtime, trajectory,
              named_parameters: existing ++ [parameter]
            )
          end)
          |> Trajectory.validate_aligned!()

        {:ok, admitted}
      rescue
        error -> {:error, {:invalid_trajectories, Exception.message(error)}}
      end
    end
  end

  defp admit_trajectories(other, _rows, _playbook),
    do: {:error, {:trajectories_must_be_a_list, result_shape(other)}}

  defp playbook_parameter?(%Parameter{kind: kind}) when kind in [:playbook, "playbook"], do: true
  defp playbook_parameter?(_), do: false

  defp validate_splits(train, promotion, audit) do
    with {:ok, train} <- validate_rows(train, :train),
         {:ok, promotion} <- validate_rows(promotion, :promotion),
         {:ok, audit} <- validate_rows(audit, :audit),
         :ok <- disjoint_gate(train, promotion, audit) do
      {:ok, %{train: train, promotion: promotion, audit: audit}}
    end
  end

  defp validate_rows(rows, split) when is_list(rows) and rows != [] do
    required_strings = ~w(id source_id group_id)

    valid? =
      Enum.all?(rows, fn row ->
        is_map(row) and Enum.all?(required_strings, &valid_nonempty_string(row[&1])) and
          is_list(row["leakage_terms"]) and
          Enum.all?(row["leakage_terms"], &valid_leakage_term?/1)
      end)

    ids = Enum.map(rows, & &1["id"])

    cond do
      not valid? -> {:error, {:invalid_split_rows, split}}
      Enum.uniq(ids) != ids -> {:error, {:duplicate_split_ids, split}}
      true -> {:ok, rows}
    end
  end

  defp validate_rows(_rows, split), do: {:error, {:empty_or_invalid_split, split}}

  defp valid_nonempty_string(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp valid_leakage_term?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(String.trim(value)) >= 8

  defp disjoint_gate(train, promotion, audit) do
    Enum.reduce_while(~w(id source_id group_id), :ok, fn key, :ok ->
      sets =
        Enum.map([train, promotion, audit], &MapSet.new(Enum.map(&1, fn row -> row[key] end)))

      if pairwise_disjoint?(sets),
        do: {:cont, :ok},
        else: {:halt, {:error, {:split_leakage, key}}}
    end)
  end

  defp pairwise_disjoint?([first, second, third]) do
    MapSet.disjoint?(first, second) and MapSet.disjoint?(first, third) and
      MapSet.disjoint?(second, third)
  end

  defp growth_gate(optimizer, baseline, candidate) do
    baseline_bytes = retained_bytes(baseline)
    candidate_bytes = retained_bytes(candidate)
    growth = candidate_bytes - baseline_bytes
    ratio = candidate_bytes / max(baseline_bytes, 1)

    cond do
      growth > optimizer.max_growth_bytes ->
        {:error, {:growth_bytes_exceeded, growth, optimizer.max_growth_bytes}}

      ratio > optimizer.max_growth_ratio ->
        {:error, {:growth_ratio_exceeded, ratio, optimizer.max_growth_ratio}}

      true ->
        :ok
    end
  end

  defp leakage_gate(optimizer, baseline, candidate, splits) do
    changed = changed_entries(baseline, candidate)
    heldout_rows = splits.promotion ++ splits.audit

    heldout_ids =
      heldout_rows |> Enum.flat_map(&[&1["id"], &1["source_id"], &1["group_id"]]) |> MapSet.new()

    allowed =
      splits.train
      |> Enum.flat_map(&[&1["id"], &1["source_id"], &1["group_id"]])
      |> Kernel.++(optimizer.authority_source_ids)
      |> MapSet.new()

    provenance_ids = changed |> Enum.flat_map(& &1.provenance.source_ids) |> MapSet.new()
    unauthorized = provenance_ids |> MapSet.difference(allowed) |> MapSet.to_list() |> Enum.sort()
    heldout_provenance = provenance_ids |> MapSet.intersection(heldout_ids) |> MapSet.to_list()
    terms = heldout_rows |> Enum.flat_map(& &1["leakage_terms"]) |> Enum.uniq()

    leaked_terms =
      for entry <- changed,
          term <- terms,
          contains_normalized?(entry.content, term),
          do: %{entry_id: entry.id, term_sha256: sha256(Entry.normalize(term))}

    cond do
      heldout_provenance != [] -> {:error, {:heldout_provenance_leakage, heldout_provenance}}
      unauthorized != [] -> {:error, {:unauthorized_provenance, unauthorized}}
      leaked_terms != [] -> {:error, {:heldout_content_leakage, leaked_terms}}
      true -> :ok
    end
  end

  defp changed_entries(baseline, candidate) do
    baseline_hashes = Map.new(baseline.entries, &{&1.id, &1.hash})
    Enum.reject(candidate.entries, &(baseline_hashes[&1.id] == &1.hash))
  end

  defp contains_normalized?(content, term) do
    content = content |> Entry.normalize() |> String.downcase()
    term = term |> Entry.normalize() |> String.downcase()
    String.contains?(content, term)
  end

  defp build_result(
         optimizer,
         identity,
         baseline_program,
         candidate_program,
         baseline,
         candidate,
         promoted?,
         scores,
         state,
         reasons
       ) do
    program = if promoted?, do: candidate_program, else: baseline_program

    payload = %{
      "schema_version" => 1,
      "status" => "complete",
      "stage" => "complete",
      "identity" => identity,
      "state" => %{
        "baseline_playbook" => Context.dump(baseline),
        "candidate_playbook" => Context.dump(candidate),
        "promoted" => promoted?,
        "scores" => stringify_keys(scores),
        "rejection_reasons" => encode_reasons(reasons),
        "usage" => dump_usage(state.usage),
        "trajectories" => dump_trajectory_map(state.trajectories)
      }
    }

    checkpoint = seal_checkpoint(payload)

    result = %Result{
      program: program,
      baseline_program: baseline_program,
      candidate_program: candidate_program,
      baseline_playbook: baseline,
      candidate_playbook: candidate,
      promoted?: promoted?,
      scores: scores,
      usage: state.usage,
      trajectories: state.trajectories,
      checkpoint: checkpoint,
      rejection_reasons: reasons,
      parameter: optimizer.parameter
    }

    emit_checkpoint(optimizer.checkpoint_fn, checkpoint)
    {:ok, result}
  end

  defp rejection_reasons(scores, min_lift) do
    []
    |> maybe_reject(
      scores.candidate_promotion < scores.baseline_promotion + min_lift,
      {:promotion_lift_below_threshold, scores.candidate_promotion - scores.baseline_promotion,
       min_lift}
    )
    |> maybe_reject(
      scores.candidate_audit < scores.baseline_audit + min_lift,
      {:audit_lift_below_threshold, scores.candidate_audit - scores.baseline_audit, min_lift}
    )
    |> Enum.reverse()
  end

  defp maybe_reject(reasons, true, reason), do: [reason | reasons]
  defp maybe_reject(reasons, false, _reason), do: reasons

  defp mean_score(trajectories),
    do: Enum.sum(Enum.map(trajectories, &(&1.score * 1.0))) / length(trajectories)

  defp identity(optimizer, baseline, splits) do
    %{
      "optimizer" => "dsex_playbook_optimizer",
      "schema_version" => 1,
      "parameter" => encode_name(optimizer.parameter),
      "baseline_playbook_hash" => baseline.hash,
      "split_sha256" => %{
        "train" => Canonical.hash(splits.train),
        "promotion" => Canonical.hash(splits.promotion),
        "audit" => Canonical.hash(splits.audit)
      },
      "min_lift" => optimizer.min_lift,
      "max_growth_bytes" => optimizer.max_growth_bytes,
      "max_growth_ratio" => optimizer.max_growth_ratio,
      "reservations" => dump_usage_map(optimizer.reservations),
      "budget" => dump_usage(optimizer.budget)
    }
  end

  defp resume_mode(nil, _identity), do: :fresh

  defp resume_mode(checkpoint, identity) do
    with {:ok, payload} <- verify_checkpoint(checkpoint),
         true <- payload["identity"] == identity do
      case payload["status"] do
        "complete" -> {:restored, checkpoint}
        "started" -> {:error, {:ambiguous_started_checkpoint, payload["stage"]}}
        other -> {:error, {:invalid_checkpoint_status, other}}
      end
    else
      false -> {:error, :checkpoint_identity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp emit_started(optimizer, identity, stage, usage) do
    payload = %{
      "schema_version" => 1,
      "status" => "started",
      "stage" => Atom.to_string(stage),
      "identity" => identity,
      "state" => %{"usage_before_stage" => dump_usage(usage)}
    }

    emit_checkpoint(optimizer.checkpoint_fn, seal_checkpoint(payload))
  end

  defp emit_checkpoint(nil, _checkpoint), do: :ok

  defp emit_checkpoint(callback, checkpoint) when is_function(callback, 1) do
    case callback.(checkpoint) do
      :ok -> :ok
      other -> raise ArgumentError, "checkpoint callback must return :ok, got: #{inspect(other)}"
    end
  end

  defp seal_checkpoint(payload) do
    %{"payload" => payload, "payload_sha256" => Canonical.hash(payload)}
  end

  defp verify_checkpoint(%{"payload" => payload, "payload_sha256" => digest} = checkpoint)
       when map_size(checkpoint) == 2 and is_map(payload) and is_binary(digest) do
    if :crypto.hash_equals(digest, Canonical.hash(payload)) and payload["schema_version"] == 1,
      do: {:ok, payload},
      else: {:error, :checkpoint_integrity_failure}
  end

  defp verify_checkpoint(_), do: {:error, :malformed_checkpoint}

  defp restore_result(payload, program, parameter) do
    state = payload["state"]
    baseline = Context.load!(state["baseline_playbook"])
    candidate = Context.load!(state["candidate_playbook"])
    baseline_program = ProgramParameters.put_playbook(program, parameter, baseline)
    candidate_program = ProgramParameters.put_playbook(program, parameter, candidate)
    promoted? = state["promoted"]
    selected = if promoted?, do: candidate_program, else: baseline_program

    trajectories =
      state["trajectories"]
      |> Enum.map(fn {stage, values} ->
        {String.to_existing_atom(stage), Enum.map(values, &Trajectory.load!/1)}
      end)
      |> Map.new()

    {:ok,
     %Result{
       program: selected,
       baseline_program: baseline_program,
       candidate_program: candidate_program,
       baseline_playbook: baseline,
       candidate_playbook: candidate,
       promoted?: promoted?,
       scores: atomize_score_keys(state["scores"]),
       usage: load_usage!(state["usage"]),
       trajectories: trajectories,
       checkpoint: seal_checkpoint(payload),
       rejection_reasons: decode_reasons(state["rejection_reasons"]),
       parameter: parameter
     }}
  end

  defp normalize_reservations!(reservations) when is_map(reservations) do
    normalized =
      Enum.map(@stages, fn stage ->
        value = Map.get(reservations, stage, Map.get(reservations, Atom.to_string(stage)))
        {stage, normalize_usage!(value, {:reservation, stage})}
      end)
      |> Map.new()

    actual = Map.keys(reservations) |> Enum.map(&normalize_stage!/1) |> MapSet.new()

    if actual == MapSet.new(@stages),
      do: normalized,
      else: raise(ArgumentError, "reservations must contain exactly #{inspect(@stages)}")
  end

  defp normalize_reservations!(_), do: raise(ArgumentError, "reservations must be a map")

  defp normalize_stage!(stage) when stage in @stages, do: stage

  defp normalize_stage!(stage) when is_binary(stage) do
    case Enum.find(@stages, &(Atom.to_string(&1) == stage)) do
      nil -> raise ArgumentError, "unknown playbook optimizer stage #{inspect(stage)}"
      value -> value
    end
  end

  defp normalize_stage!(stage),
    do: raise(ArgumentError, "unknown playbook optimizer stage #{inspect(stage)}")

  defp normalize_usage!(%Usage{} = usage, context), do: validate_usage!(usage, context)

  defp normalize_usage!(usage, context) when is_map(usage) do
    usage = %Usage{
      requests: get_usage!(usage, :requests),
      input_tokens: get_usage!(usage, :input_tokens),
      output_tokens: get_usage!(usage, :output_tokens),
      cost_usd: get_usage!(usage, :cost_usd),
      authority: normalize_authority!(get_usage!(usage, :authority)),
      models: Map.get(usage, :models, Map.get(usage, "models", []))
    }

    validate_usage!(usage, context)
  end

  defp normalize_usage!(_usage, context),
    do: raise(ArgumentError, "invalid usage for #{inspect(context)}")

  defp get_usage!(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(usage, Atom.to_string(key))
    end
  end

  defp normalize_authority!(authority) when authority in @usage_authorities, do: authority

  defp normalize_authority!(authority) when is_binary(authority) do
    case Enum.find(@usage_authorities, &(Atom.to_string(&1) == authority)) do
      nil -> raise ArgumentError, "invalid usage authority #{inspect(authority)}"
      value -> value
    end
  end

  defp normalize_authority!(authority),
    do: raise(ArgumentError, "invalid usage authority #{inspect(authority)}")

  defp validate_usage!(usage, context) do
    valid_numbers =
      is_integer(usage.requests) and usage.requests >= 0 and is_integer(usage.input_tokens) and
        usage.input_tokens >= 0 and is_integer(usage.output_tokens) and
        usage.output_tokens >= 0 and is_number(usage.cost_usd) and usage.cost_usd >= 0 and
        finite_number?(usage.cost_usd)

    valid_models =
      is_list(usage.models) and Enum.all?(usage.models, &valid_nonempty_string/1) and
        Enum.uniq(usage.models) == usage.models

    authority_valid =
      usage.authority in @usage_authorities and
        if usage.authority == :free,
          do: usage.cost_usd == 0,
          else: usage.requests > 0 and usage.input_tokens > 0 and usage.output_tokens > 0

    if valid_numbers and valid_models and authority_valid,
      do: usage,
      else: raise(ArgumentError, "invalid usage for #{inspect(context)}")
  end

  defp admit_usage(usage, reservation, stage) do
    admitted = normalize_usage!(usage, stage)

    if usage_within?(admitted, reservation),
      do: {:ok, admitted},
      else:
        {:error,
         {:stage_reservation_exceeded, stage, dump_usage(admitted), dump_usage(reservation)}}
  rescue
    error -> {:error, {:invalid_stage_accounting, stage, Exception.message(error)}}
  end

  defp add_usage(left, right, budget) do
    aggregate = %Usage{
      requests: left.requests + right.requests,
      input_tokens: left.input_tokens + right.input_tokens,
      output_tokens: left.output_tokens + right.output_tokens,
      cost_usd: left.cost_usd + right.cost_usd,
      authority: aggregate_authority(left.authority, right.authority),
      models: Enum.uniq(left.models ++ right.models)
    }

    if usage_within?(aggregate, budget),
      do: {:ok, aggregate},
      else: {:error, {:aggregate_budget_exceeded, dump_usage(aggregate), dump_usage(budget)}}
  end

  defp aggregate_authority(:free, authority), do: authority
  defp aggregate_authority(authority, :free), do: authority
  defp aggregate_authority(authority, authority), do: authority
  defp aggregate_authority(_left, _right), do: :derived

  defp usage_within?(usage, limit) do
    usage.requests <= limit.requests and usage.input_tokens <= limit.input_tokens and
      usage.output_tokens <= limit.output_tokens and usage.cost_usd <= limit.cost_usd
  end

  defp validate_reservation_budget(optimizer) do
    reserved =
      Enum.reduce(optimizer.reservations, zero_usage(), fn {_stage, usage}, acc ->
        {:ok, total} = add_usage_unbounded(acc, usage)
        total
      end)

    if usage_within?(reserved, optimizer.budget),
      do: :ok,
      else:
        {:error,
         {:reservations_exceed_budget, dump_usage(reserved), dump_usage(optimizer.budget)}}
  end

  defp add_usage_unbounded(left, right) do
    {:ok,
     %Usage{
       requests: left.requests + right.requests,
       input_tokens: left.input_tokens + right.input_tokens,
       output_tokens: left.output_tokens + right.output_tokens,
       cost_usd: left.cost_usd + right.cost_usd,
       authority: aggregate_authority(left.authority, right.authority),
       models: Enum.uniq(left.models ++ right.models)
     }}
  end

  defp zero_usage do
    %Usage{
      requests: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: 0.0,
      authority: :free,
      models: []
    }
  end

  defp validate_optimizer!(optimizer) do
    cond do
      not is_function(optimizer.proposer, 1) ->
        raise ArgumentError, ":proposer must be arity one"

      not is_function(optimizer.evaluator, 3) ->
        raise ArgumentError, ":evaluator must be arity three"

      not is_number(optimizer.min_lift) or optimizer.min_lift < 0 ->
        raise ArgumentError, ":min_lift must be non-negative"

      not is_integer(optimizer.max_growth_bytes) or optimizer.max_growth_bytes < 0 ->
        raise ArgumentError, ":max_growth_bytes must be non-negative"

      not is_number(optimizer.max_growth_ratio) or optimizer.max_growth_ratio < 1 ->
        raise ArgumentError, ":max_growth_ratio must be at least 1"

      not is_nil(optimizer.checkpoint_fn) and not is_function(optimizer.checkpoint_fn, 1) ->
        raise ArgumentError, ":checkpoint_fn must be arity one or nil"

      not is_list(optimizer.authority_source_ids) or
          not Enum.all?(optimizer.authority_source_ids, &valid_nonempty_string/1) ->
        raise ArgumentError, ":authority_source_ids must contain strings"

      true ->
        optimizer
    end
  end

  defp validate_compile_options(opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:resume_state] do
      [] -> :ok
      unknown -> {:error, {:unknown_compile_options, unknown}}
    end
  end

  defp validate_compile_options(_), do: {:error, :compile_options_must_be_a_keyword_list}

  defp apply_runtime_options(optimizer, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      checkpoint_fn = Keyword.get(opts, :checkpoint_fn, optimizer.checkpoint_fn)

      if is_nil(checkpoint_fn) or is_function(checkpoint_fn, 1),
        do:
          {:ok, %{optimizer | checkpoint_fn: checkpoint_fn}, Keyword.delete(opts, :checkpoint_fn)},
        else: {:error, :checkpoint_fn_must_be_arity_one_or_nil}
    else
      {:error, :compile_options_must_be_a_keyword_list}
    end
  end

  defp apply_runtime_options(_optimizer, _opts),
    do: {:error, :compile_options_must_be_a_keyword_list}

  defp fetch_playbook(program, name) do
    case Enum.find(ProgramParameters.playbooks(program), &(&1.name == name)) do
      %{playbook: playbook} -> {:ok, playbook}
      nil -> {:error, {:playbook_parameter_not_found, name}}
    end
  rescue
    error -> {:error, {:invalid_program_parameters, Exception.message(error)}}
  end

  defp dump_usage(%Usage{} = usage) do
    %{
      "requests" => usage.requests,
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cost_usd" => usage.cost_usd,
      "authority" => Atom.to_string(usage.authority),
      "models" => usage.models
    }
  end

  defp load_usage!(usage), do: normalize_usage!(usage, :checkpoint)

  defp dump_usage_map(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), dump_usage(value)} end)

  defp dump_trajectory_map(map) do
    Map.new(map, fn {stage, trajectories} ->
      {Atom.to_string(stage), Enum.map(trajectories, &Trajectory.dump/1)}
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp atomize_score_keys(map) do
    Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp encode_reasons(reasons) do
    Enum.map(reasons, fn {kind, lift, threshold} ->
      %{
        "kind" => Atom.to_string(kind),
        "lift" => lift,
        "threshold" => threshold
      }
    end)
  end

  defp decode_reasons(reasons) when is_list(reasons) do
    Enum.map(reasons, fn
      %{"kind" => kind, "lift" => lift, "threshold" => threshold}
      when kind in ["promotion_lift_below_threshold", "audit_lift_below_threshold"] and
             is_number(lift) and is_number(threshold) ->
        {String.to_existing_atom(kind), lift, threshold}

      reason when is_binary(reason) ->
        reason

      reason ->
        raise ArgumentError, "invalid checkpoint rejection reason #{inspect(reason)}"
    end)
  end

  defp decode_reasons(reasons),
    do:
      raise(
        ArgumentError,
        "checkpoint rejection reasons must be a list, got: #{inspect(reasons)}"
      )

  defp encode_name(name) when is_atom(name),
    do: %{"type" => "atom", "value" => Atom.to_string(name)}

  defp encode_name(name) when is_binary(name), do: %{"type" => "string", "value" => name}

  defp valid_score?(score),
    do: is_number(score) and finite_number?(score) and score >= 0 and score <= 1

  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value),
    do: value == value and value not in [:infinity, :neg_infinity]

  defp result_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp result_shape(value) when is_list(value), do: {:list, length(value)}
  defp result_shape(%module{}), do: {:struct, module}
  defp result_shape(value), do: {:type, value |> :erlang.term_to_binary() |> byte_size()}
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end

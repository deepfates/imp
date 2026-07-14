defmodule Imp.Optimizer.GEPA.ComBee do
  @moduledoc """
  BEAM-native ComBee-style map-shuffle-reduce aggregation for GEPA reflections.

  The original `n` records determine `k = floor(sqrt(n))`. Records are copied
  `p` times, deterministically shuffled, divided into balanced groups, reduced
  concurrently, and then reduced once more in group order. Every reducer call
  receives the unchanged current candidate and component.
  """

  alias Imp.Optimizer.GEPA.ComBee.{BatchController, Options}
  alias Imp.Optimizer.GEPA.Coordinator

  defmodule Policy do
    @moduledoc "Resolved, checkpoint-identifiable ComBee runtime policy."

    defstruct [
      :enabled,
      :duplication_factor,
      :max_concurrency_requested,
      :max_concurrency,
      :timeout_requested,
      :timeout,
      :seed,
      :trainset_size,
      :effective_batch_size,
      :batch_controller_options,
      :batch_controller,
      :identity
    ]
  end

  defmodule Plan do
    @moduledoc "Deterministic augmented-shuffle and balanced-group plan."

    defstruct [
      :source_count,
      :duplication_factor,
      :augmented_count,
      :group_count,
      :shuffle_seed,
      groups: []
    ]
  end

  defmodule Report do
    @moduledoc "Auditable report for one component's ComBee aggregation."

    defstruct [
      :status,
      :failure,
      :component,
      :iteration,
      :source_count,
      :duplication_factor,
      :augmented_count,
      :group_count,
      :group_sizes,
      :group_assignments,
      :shuffle_seed,
      :max_concurrency,
      :first_level_calls,
      :final_calls,
      :reflection_calls
    ]
  end

  @type proposer ::
          (map(), atom(), [map()], non_neg_integer() -> String.t() | {:ok, String.t()})
          | (map(), atom(), [map()], non_neg_integer(), map() ->
               String.t() | {:ok, String.t()})

  @doc false
  def resolve(value, trainset_size, requested_batch_size, seed) do
    case normalize_options(value) do
      false ->
        %Policy{
          enabled: false,
          max_concurrency_requested: 1,
          max_concurrency: 1,
          timeout_requested: nil,
          timeout: :infinity,
          seed: seed,
          trainset_size: trainset_size,
          effective_batch_size: requested_batch_size,
          identity: identity(%{enabled: false})
        }

      %Options{} = options ->
        batch_report =
          case options.batch_controller do
            %BatchController.Options{mode: :offline_measurements} = controller ->
              BatchController.select(controller, trainset_size)

            %BatchController.Options{mode: :runtime} = controller ->
              BatchController.new_profile(controller, trainset_size)

            nil ->
              nil
          end

        effective_batch_size =
          if batch_report && batch_report.status in [:ok, :degenerate],
            do: batch_report.selected_batch_size,
            else: requested_batch_size

        %Policy{
          enabled: true,
          duplication_factor: options.duplication_factor,
          max_concurrency_requested: options.max_concurrency,
          timeout_requested: options.timeout,
          timeout: options.timeout,
          seed: seed,
          trainset_size: trainset_size,
          effective_batch_size: effective_batch_size,
          batch_controller_options: options.batch_controller,
          batch_controller: batch_report
        }
    end
  end

  @doc false
  def resolve_concurrency(%Policy{enabled: false} = policy, _workers, _proposal_concurrency),
    do: policy

  def resolve_concurrency(%Policy{} = policy, workers, proposal_concurrency)
      when is_integer(workers) and workers > 0 and is_integer(proposal_concurrency) and
             proposal_concurrency > 0 do
    available = div(workers, proposal_concurrency)

    if available < 1 do
      raise ArgumentError,
            "ComBee cannot compose with proposal_concurrency=#{proposal_concurrency} " <>
              "and async_max_workers=#{workers}"
    end

    resolved =
      case policy.max_concurrency_requested do
        :auto ->
          available

        requested when requested <= available ->
          requested

        requested ->
          raise ArgumentError,
                "ComBee max_concurrency=#{requested} with " <>
                  "proposal_concurrency=#{proposal_concurrency} exceeds " <>
                  "async_max_workers=#{workers}"
      end

    policy = %{policy | max_concurrency: resolved}
    %{policy | identity: identity(policy_identity_payload(policy))}
  end

  @doc false
  def bound_timeout(%Policy{} = policy, proposal_timeout) do
    timeout =
      if policy.enabled,
        do: minimum_timeout(policy.timeout_requested, proposal_timeout),
        else: proposal_timeout

    policy = %{policy | timeout: timeout}
    %{policy | identity: identity(policy_identity_payload(policy))}
  end

  @doc "Returns the exact maximum reducer calls required for these records."
  def reflection_call_reservation(_records, %Policy{enabled: false}), do: 1
  def reflection_call_reservation([], %Policy{enabled: true}), do: 0

  def reflection_call_reservation(records, %Policy{enabled: true}) when is_list(records),
    do: floor_sqrt(length(records)) + 1

  @doc "Builds the seeded augmented-shuffle plan used by `aggregate/6`."
  def plan(records, component, iteration, %Policy{enabled: true} = policy)
      when is_list(records) and is_atom(component) and is_integer(iteration) and iteration >= 0 do
    source_count = length(records)

    if source_count == 0 do
      %Plan{
        source_count: 0,
        duplication_factor: policy.duplication_factor,
        augmented_count: 0,
        group_count: 0,
        shuffle_seed: shuffle_seed(policy, component, iteration, 0),
        groups: []
      }
    else
      group_count = floor_sqrt(source_count)
      seed = shuffle_seed(policy, component, iteration, source_count)

      augmented =
        records
        |> Enum.with_index()
        |> Enum.flat_map(fn {record, source_index} ->
          Enum.map(0..(policy.duplication_factor - 1), fn duplicate_index ->
            %{record: record, source_index: source_index, duplicate_index: duplicate_index}
          end)
        end)
        |> seeded_shuffle(seed)

      %Plan{
        source_count: source_count,
        duplication_factor: policy.duplication_factor,
        augmented_count: length(augmented),
        group_count: group_count,
        shuffle_seed: Tuple.to_list(seed),
        groups: balanced_groups(augmented, group_count)
      }
    end
  end

  @doc "Runs first-level reducers concurrently and one final ordered reduction."
  def aggregate(
        proposer,
        candidate,
        component,
        records,
        iteration,
        %Policy{enabled: true} = policy
      )
      when (is_function(proposer, 4) or is_function(proposer, 5)) and is_map(candidate) and
             is_atom(component) and is_list(records) do
    plan = plan(records, component, iteration, policy)
    report = report(plan, component, iteration, policy)

    if plan.source_count == 0 do
      reason = {:combee_degenerate, :empty_reflective_dataset}
      {:error, reason, %{report | status: :error, failure: reason}}
    else
      deadline = Coordinator.deadline(policy.timeout)

      first_level_run =
        Coordinator.run_with_report(
          plan.groups,
          {:deadline, deadline},
          policy.max_concurrency,
          fn group ->
            metadata = local_metadata(plan, group)

            invoke(
              proposer,
              candidate,
              component,
              Enum.map(group.entries, & &1.record),
              iteration,
              metadata
            )
          end
        )

      first_level = Enum.map(first_level_run.results, &unwrap_coordinator_result/1)

      report = %{
        report
        | first_level_calls: first_level_run.dispatched,
          reflection_calls: first_level_run.dispatched
      }

      case first_failure(first_level, first_level_run.terminal_index) do
        nil ->
          updates = Enum.map(first_level, fn {:ok, update} -> update end)
          final_records = final_records(updates)
          metadata = final_metadata(plan)

          final_run =
            Coordinator.run_with_report([:final], {:deadline, deadline}, 1, fn :final ->
              invoke(proposer, candidate, component, final_records, iteration, metadata)
            end)

          final =
            final_run.results
            |> hd()
            |> unwrap_coordinator_result()

          case final do
            {:ok, update} ->
              {:ok, update,
               %{
                 report
                 | status: :ok,
                   final_calls: final_run.dispatched,
                   reflection_calls: report.reflection_calls + final_run.dispatched
               }}

            {:error, reason} ->
              failure = {:combee_final_aggregation_failed, reason}

              {:error, failure,
               %{
                 report
                 | status: :error,
                   failure: failure,
                   final_calls: final_run.dispatched,
                   reflection_calls: report.reflection_calls + final_run.dispatched
               }}
          end

        {index, reason} ->
          failure = {:combee_first_level_failed, index, reason}
          {:error, failure, %{report | status: :error, failure: failure}}
      end
    end
  end

  @doc false
  def propose(
        proposer,
        candidate,
        component,
        records,
        iteration,
        %Policy{enabled: false, timeout: :infinity}
      ) do
    case invoke(proposer, candidate, component, records, iteration, %{
           aggregation: :naive,
           phase: :single
         }) do
      {:ok, text} -> {:ok, text, 1, nil}
      {:error, reason} -> {:error, reason, 1, nil}
    end
  end

  def propose(
        proposer,
        candidate,
        component,
        records,
        iteration,
        %Policy{enabled: false} = policy
      ) do
    result =
      Coordinator.run([:single], policy.timeout, 1, fn :single ->
        invoke(proposer, candidate, component, records, iteration, %{
          aggregation: :naive,
          phase: :single
        })
      end)
      |> hd()
      |> unwrap_coordinator_result()

    case result do
      {:ok, text} -> {:ok, text, 1, nil}
      {:error, reason} -> {:error, reason, 1, nil}
    end
  end

  def propose(proposer, candidate, component, records, iteration, %Policy{} = policy) do
    case aggregate(proposer, candidate, component, records, iteration, policy) do
      {:ok, text, report} -> {:ok, text, report.reflection_calls, report}
      {:error, reason, report} -> {:error, reason, report.reflection_calls, report}
    end
  end

  @doc false
  def metadata(%Policy{} = policy) do
    %{
      enabled: policy.enabled,
      identity: policy.identity,
      duplication_factor: policy.duplication_factor,
      max_concurrency_requested: policy.max_concurrency_requested,
      max_concurrency: policy.max_concurrency,
      timeout_requested: policy.timeout_requested,
      timeout: policy.timeout,
      effective_batch_size: policy.effective_batch_size,
      batch_controller: policy.batch_controller
    }
  end

  @doc false
  def put_batch_controller_report(%Policy{} = policy, %BatchController.Report{} = report) do
    report = BatchController.validate_report!(report)

    effective_batch_size =
      if report.status in [:ok, :degenerate],
        do: report.selected_batch_size,
        else: policy.effective_batch_size

    %{policy | batch_controller: report, effective_batch_size: effective_batch_size}
  end

  @doc false
  def dump_policy(%Policy{} = policy) do
    %{
      "enabled" => policy.enabled,
      "identity" => policy.identity,
      "duplication_factor" => policy.duplication_factor,
      "max_concurrency_requested" => dump_special(policy.max_concurrency_requested),
      "max_concurrency" => policy.max_concurrency,
      "timeout_requested" => dump_special(policy.timeout_requested),
      "timeout" => dump_special(policy.timeout),
      "seed" => policy.seed,
      "trainset_size" => policy.trainset_size,
      "effective_batch_size" => policy.effective_batch_size,
      "batch_controller_options" => dump_batch_options(policy.batch_controller_options),
      "batch_controller" => dump_batch_report(policy.batch_controller)
    }
  end

  @doc false
  def load_policy!(dumped) when is_map(dumped) do
    require_exact_keys!(
      dumped,
      ~w(enabled identity duplication_factor max_concurrency_requested max_concurrency timeout_requested timeout seed trainset_size effective_batch_size batch_controller_options batch_controller),
      "ComBee policy"
    )

    policy = %Policy{
      enabled: Map.fetch!(dumped, "enabled"),
      identity: Map.fetch!(dumped, "identity"),
      duplication_factor: Map.fetch!(dumped, "duplication_factor"),
      max_concurrency_requested: load_special(Map.fetch!(dumped, "max_concurrency_requested")),
      max_concurrency: Map.fetch!(dumped, "max_concurrency"),
      timeout_requested: load_special(Map.fetch!(dumped, "timeout_requested")),
      timeout: load_special(Map.fetch!(dumped, "timeout")),
      seed: Map.fetch!(dumped, "seed"),
      trainset_size: Map.fetch!(dumped, "trainset_size"),
      effective_batch_size: Map.fetch!(dumped, "effective_batch_size"),
      batch_controller_options:
        load_batch_options(Map.fetch!(dumped, "batch_controller_options")),
      batch_controller: load_batch_report(Map.fetch!(dumped, "batch_controller"))
    }

    unless policy.identity == identity(policy_identity_payload(policy)) do
      raise ArgumentError, "ComBee policy identity mismatch"
    end

    policy
  rescue
    error in KeyError ->
      reraise ArgumentError,
              [message: "invalid ComBee policy: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  @doc false
  def dump_report(nil), do: nil

  def dump_report(%Report{} = report) do
    report
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key), Imp.Optimizer.Report.json_safe(value)}
    end)
  end

  @doc false
  def load_report(nil), do: nil

  def load_report(report) when is_map(report) do
    values =
      Map.new(report, fn {key, value} ->
        {String.to_existing_atom(key), Imp.Optimizer.Report.restore_json_safe(value)}
      end)

    struct!(Report, values)
  end

  defp normalize_options(false), do: false
  defp normalize_options(nil), do: false
  defp normalize_options(true), do: %Options{}
  defp normalize_options(%Options{} = options), do: Options.new!(options)
  defp normalize_options(options), do: Options.new!(options)

  defp report(plan, component, iteration, policy) do
    %Report{
      component: component,
      iteration: iteration,
      source_count: plan.source_count,
      duplication_factor: plan.duplication_factor,
      augmented_count: plan.augmented_count,
      group_count: plan.group_count,
      group_sizes: Enum.map(plan.groups, & &1.size),
      group_assignments:
        Enum.map(plan.groups, fn group ->
          Enum.map(group.entries, &{&1.source_index, &1.duplicate_index})
        end),
      shuffle_seed: plan.shuffle_seed,
      max_concurrency: policy.max_concurrency,
      first_level_calls: 0,
      final_calls: 0,
      reflection_calls: 0
    }
  end

  defp balanced_groups(entries, count) do
    base_size = div(length(entries), count)
    extra = rem(length(entries), count)

    {groups, []} =
      Enum.map_reduce(0..(count - 1), entries, fn index, remaining ->
        size = base_size + if(index < extra, do: 1, else: 0)
        {current, rest} = Enum.split(remaining, size)
        {%{index: index, size: size, entries: current}, rest}
      end)

    groups
  end

  defp seeded_shuffle(entries, seed) do
    {decorated, _rng_state} =
      Enum.map_reduce(entries, :rand.seed_s(:exsss, seed), fn entry, rng_state ->
        {key, rng_state} = :rand.uniform_s(rng_state)
        {{key, entry.source_index, entry.duplicate_index, entry}, rng_state}
      end)

    decorated
    |> Enum.sort()
    |> Enum.map(&elem(&1, 3))
  end

  defp shuffle_seed(policy, component, iteration, source_count) do
    data =
      :erlang.term_to_binary(
        {policy.seed, component, iteration, source_count, policy.duplication_factor},
        [:deterministic]
      )

    <<first::unsigned-32, second::unsigned-32, third::unsigned-32, _rest::binary>> =
      :crypto.hash(:sha256, data)

    {first + 1, second + 1, third + 1}
  end

  defp local_metadata(plan, group) do
    %{
      aggregation: :combee,
      phase: :first_level,
      group_index: group.index,
      group_count: plan.group_count,
      source_count: plan.source_count,
      duplication_factor: plan.duplication_factor,
      source_assignments: Enum.map(group.entries, &{&1.source_index, &1.duplicate_index})
    }
  end

  defp final_metadata(plan) do
    %{
      aggregation: :combee,
      phase: :final,
      group_count: plan.group_count,
      source_count: plan.source_count,
      duplication_factor: plan.duplication_factor
    }
  end

  defp final_records(updates) do
    updates
    |> Enum.with_index()
    |> Enum.map(fn {update, index} ->
      %{
        "ComBeeGroupIndex" => index,
        "ComBeeIntermediateUpdate" => update
      }
    end)
  end

  defp invoke(proposer, candidate, component, records, iteration, metadata) do
    result =
      if is_function(proposer, 5),
        do: proposer.(candidate, component, records, iteration, metadata),
        else: proposer.(candidate, component, records, iteration)

    case result do
      {:ok, text} when is_binary(text) -> {:ok, text}
      text when is_binary(text) -> {:ok, text}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_proposal, other}}
    end
  rescue
    error -> {:error, {:proposal_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:proposal_throw, kind, reason}}
  end

  defp unwrap_coordinator_result({:ok, result}), do: result
  defp unwrap_coordinator_result({:error, reason}), do: {:error, reason}

  defp first_failure(_results, nil), do: nil

  defp first_failure(results, index) do
    case Enum.fetch!(results, index) do
      {:error, reason} -> {index, reason}
      other -> {index, {:terminal_scheduler_result, other}}
    end
  end

  defp floor_sqrt(number), do: number |> :math.sqrt() |> floor() |> max(1)

  defp policy_identity_payload(%Policy{enabled: false} = policy) do
    %{enabled: false, timeout: policy.timeout}
  end

  defp policy_identity_payload(%Policy{} = policy) do
    payload = %{
      enabled: true,
      duplication_factor: policy.duplication_factor,
      max_concurrency_requested: policy.max_concurrency_requested,
      max_concurrency: policy.max_concurrency,
      timeout_requested: policy.timeout_requested,
      timeout: policy.timeout,
      seed: policy.seed,
      trainset_size: policy.trainset_size,
      effective_batch_size: policy.effective_batch_size,
      batch_controller_options: batch_options_identity(policy.batch_controller_options)
    }

    case policy.batch_controller_options do
      %BatchController.Options{mode: :runtime} -> Map.delete(payload, :effective_batch_size)
      _ -> payload
    end
  end

  defp minimum_timeout(:infinity, timeout), do: timeout
  defp minimum_timeout(timeout, :infinity), do: timeout
  defp minimum_timeout(left, right), do: min(left, right)

  defp identity(payload) do
    payload
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> canonical()
  defp canonical(value), do: value

  defp dump_batch_options(nil), do: nil

  defp dump_batch_options(%BatchController.Options{} = options) do
    %{
      "mode" => Atom.to_string(options.mode),
      "measurements" => Enum.map(options.measurements, &Tuple.to_list/1),
      "candidate_batch_sizes" => options.candidate_batch_sizes,
      "min_batch_size" => options.min_batch_size,
      "max_batch_size" => options.max_batch_size,
      "slope_threshold_ratio" => options.slope_threshold_ratio,
      "profiling_timeout" => dump_special(options.profiling_timeout)
    }
  end

  defp load_batch_options(nil), do: nil

  defp load_batch_options(options) do
    require_exact_keys!(
      options,
      ~w(mode measurements candidate_batch_sizes min_batch_size max_batch_size slope_threshold_ratio profiling_timeout),
      "ComBee batch controller options"
    )

    BatchController.options!(
      mode: options |> Map.fetch!("mode") |> String.to_existing_atom(),
      measurements: options |> Map.fetch!("measurements") |> Enum.map(&List.to_tuple/1),
      candidate_batch_sizes: Map.fetch!(options, "candidate_batch_sizes"),
      min_batch_size: Map.fetch!(options, "min_batch_size"),
      max_batch_size: Map.fetch!(options, "max_batch_size"),
      slope_threshold_ratio: Map.fetch!(options, "slope_threshold_ratio"),
      profiling_timeout: options |> Map.fetch!("profiling_timeout") |> load_special()
    )
  end

  defp batch_options_identity(nil), do: nil

  defp batch_options_identity(%BatchController.Options{mode: :offline_measurements} = options) do
    %{
      "measurements" => Enum.map(options.measurements, &Tuple.to_list/1),
      "min_batch_size" => options.min_batch_size,
      "max_batch_size" => options.max_batch_size,
      "slope_threshold_ratio" => options.slope_threshold_ratio
    }
  end

  defp batch_options_identity(%BatchController.Options{mode: :runtime} = options),
    do: dump_batch_options(options)

  defp dump_batch_report(nil), do: nil

  defp dump_batch_report(%BatchController.Report{} = report) do
    report
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key), Imp.Optimizer.Report.json_safe(value)}
    end)
  end

  defp load_batch_report(nil), do: nil

  defp load_batch_report(report) do
    expected_keys =
      BatchController.Report.__struct__()
      |> Map.delete(:__struct__)
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)

    require_exact_keys!(report, expected_keys, "ComBee batch controller report")

    values =
      Map.new(report, fn {key, value} ->
        {String.to_existing_atom(key), Imp.Optimizer.Report.restore_json_safe(value)}
      end)

    values =
      Map.update!(values, :trials, fn trials ->
        Enum.map(trials, fn
          %BatchController.Trial{} = trial -> trial
          trial when is_map(trial) -> struct!(BatchController.Trial, trial)
        end)
      end)

    values
    |> then(&struct!(BatchController.Report, &1))
    |> BatchController.load_report!()
  end

  defp dump_special(:auto), do: "auto"
  defp dump_special(:infinity), do: "infinity"
  defp dump_special(nil), do: nil
  defp dump_special(value), do: value
  defp load_special("auto"), do: :auto
  defp load_special("infinity"), do: :infinity
  defp load_special(value), do: value

  defp require_exact_keys!(map, keys, context) do
    unless MapSet.new(Map.keys(map)) == MapSet.new(keys) do
      raise ArgumentError, "#{context} has unexpected or missing keys"
    end

    :ok
  end
end

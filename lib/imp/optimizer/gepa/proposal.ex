defmodule Imp.Optimizer.GEPA.Proposal do
  @moduledoc false

  defmodule Context do
    @moduledoc false
    @enforce_keys [:slot, :iteration, :parent_id, :minibatch_ids]
    defstruct [
      :slot,
      :iteration,
      :parent_id,
      :minibatch_ids,
      :parent_result,
      :parent_metric_calls,
      :parent_ambiguous,
      :child_result,
      :child_metric_calls,
      :child_ambiguous,
      :reflection_calls,
      :reflection_ambiguous,
      :components,
      :next_component,
      :action,
      :error,
      :dataset,
      :aggregation_reports,
      :replacements,
      :candidate
    ]
  end

  defmodule Batch do
    @moduledoc false
    @enforce_keys [:id, :phase, :status, :contexts]
    defstruct [:id, :phase, :status, :contexts, :deferred_stop_reason]
  end

  def new_batch(phase, contexts, deferred_stop_reason \\ nil)
      when phase in [:parent, :reflection, :child] and is_list(contexts) and contexts != [] do
    id_payload =
      Enum.map(contexts, fn context ->
        {context.slot, context.iteration, context.parent_id, context.minibatch_ids}
      end)

    id = digest({phase, id_payload})

    %Batch{
      id: id,
      phase: phase,
      status: :prepared,
      contexts: contexts,
      deferred_stop_reason: deferred_stop_reason
    }
  end

  def started(%Batch{} = batch), do: %{batch | status: :started}

  def checkpoint_integrity(batch, ledger, policy), do: digest({batch, ledger, policy})

  def checkpoint_integrity(batch, ledger, policy, combee_policy),
    do: digest({batch, ledger, policy, combee_policy})

  def dump(nil, _dump_result), do: nil

  def dump(%Batch{} = batch, dump_result) when is_function(dump_result, 1) do
    payload = %{
      "id" => batch.id,
      "phase" => Atom.to_string(batch.phase),
      "status" => Atom.to_string(batch.status),
      "contexts" => Enum.map(batch.contexts, &dump_context(&1, dump_result)),
      "deferred_stop_reason" => Imp.Optimizer.Report.encode_term(batch.deferred_stop_reason)
    }

    Map.put(payload, "integrity", digest(payload))
  end

  def load!(nil, _load_result), do: nil

  def load!(%{"integrity" => integrity} = dumped, load_result)
      when is_function(load_result, 1) do
    require_exact_keys!(
      dumped,
      ~w(id phase status contexts deferred_stop_reason integrity),
      "GEPA pending proposal batch"
    )

    payload = Map.delete(dumped, "integrity")

    unless secure_equal?(integrity, digest(payload)) do
      raise ArgumentError, "GEPA pending proposal batch integrity mismatch"
    end

    phase = enum!(Map.fetch!(payload, "phase"), [:parent, :reflection, :child], :phase)
    status = enum!(Map.fetch!(payload, "status"), [:prepared, :started], :status)
    contexts = Enum.map(Map.fetch!(payload, "contexts"), &load_context!(&1, load_result))

    batch = %Batch{
      id: Map.fetch!(payload, "id"),
      phase: phase,
      status: status,
      contexts: contexts,
      deferred_stop_reason:
        payload |> Map.fetch!("deferred_stop_reason") |> Imp.Optimizer.Report.decode_term()
    }

    expected = new_batch(phase, contexts, batch.deferred_stop_reason).id

    unless batch.id == expected do
      raise ArgumentError, "GEPA pending proposal batch identity mismatch"
    end

    batch
  rescue
    error in [KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid GEPA pending proposal batch: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  def load!(value, _load_result),
    do: raise(ArgumentError, "invalid GEPA pending proposal batch: #{inspect(value)}")

  defp dump_context(%Context{} = context, dump_result) do
    %{
      "slot" => context.slot,
      "iteration" => context.iteration,
      "parent_id" => context.parent_id,
      "minibatch_ids" => context.minibatch_ids,
      "parent_result" => if(context.parent_result, do: dump_result.(context.parent_result)),
      "parent_metric_calls" => context.parent_metric_calls,
      "parent_ambiguous" => context.parent_ambiguous || false,
      "child_result" => if(context.child_result, do: dump_result.(context.child_result)),
      "child_metric_calls" => context.child_metric_calls,
      "child_ambiguous" => context.child_ambiguous || false,
      "reflection_calls" => context.reflection_calls,
      "reflection_ambiguous" => context.reflection_ambiguous || false,
      "components" => Imp.Optimizer.Report.encode_term(context.components),
      "next_component" => context.next_component,
      "action" => if(context.action, do: Atom.to_string(context.action)),
      "error" => Imp.Optimizer.Report.encode_term(context.error),
      "dataset" => Imp.Optimizer.Report.encode_term(context.dataset),
      "aggregation_reports" =>
        Enum.map(context.aggregation_reports || [], &Imp.Optimizer.GEPA.ComBee.dump_report/1),
      "replacements" => Imp.Optimizer.Report.encode_term(context.replacements),
      "candidate" => Imp.Optimizer.Report.encode_term(context.candidate)
    }
  end

  defp load_context!(context, load_result) do
    require_exact_keys!(
      context,
      ~w(slot iteration parent_id minibatch_ids parent_result parent_metric_calls parent_ambiguous child_result child_metric_calls child_ambiguous reflection_calls reflection_ambiguous components next_component action error dataset aggregation_reports replacements candidate),
      "GEPA pending proposal context"
    )

    action =
      case Map.fetch!(context, "action") do
        nil -> nil
        value -> enum!(value, [:reflect, :child, :skip, :error, :budget_stop], :action)
      end

    %Context{
      slot: non_negative!(Map.fetch!(context, "slot"), :slot),
      iteration: non_negative!(Map.fetch!(context, "iteration"), :iteration),
      parent_id: non_negative!(Map.fetch!(context, "parent_id"), :parent_id),
      minibatch_ids: Enum.map(Map.fetch!(context, "minibatch_ids"), &non_negative!(&1, :id)),
      parent_result:
        case Map.fetch!(context, "parent_result") do
          nil -> nil
          result -> load_result.(result)
        end,
      parent_metric_calls: Map.fetch!(context, "parent_metric_calls"),
      parent_ambiguous: Map.fetch!(context, "parent_ambiguous"),
      child_result:
        case Map.fetch!(context, "child_result") do
          nil -> nil
          result -> load_result.(result)
        end,
      child_metric_calls: Map.fetch!(context, "child_metric_calls"),
      child_ambiguous: Map.fetch!(context, "child_ambiguous"),
      reflection_calls: Map.fetch!(context, "reflection_calls"),
      reflection_ambiguous: Map.fetch!(context, "reflection_ambiguous"),
      components: context |> Map.fetch!("components") |> Imp.Optimizer.Report.decode_term(),
      next_component: Map.fetch!(context, "next_component"),
      action: action,
      error: context |> Map.fetch!("error") |> Imp.Optimizer.Report.decode_term(),
      dataset: context |> Map.fetch!("dataset") |> Imp.Optimizer.Report.decode_term(),
      aggregation_reports:
        context
        |> Map.fetch!("aggregation_reports")
        |> Enum.map(&Imp.Optimizer.GEPA.ComBee.load_report/1),
      replacements: context |> Map.fetch!("replacements") |> Imp.Optimizer.Report.decode_term(),
      candidate: context |> Map.fetch!("candidate") |> Imp.Optimizer.Report.decode_term()
    }
  end

  defp enum!(value, allowed, name) when is_binary(value) do
    atom = Enum.find(allowed, &(Atom.to_string(&1) == value))
    atom || raise(ArgumentError, "invalid proposal #{name}: #{inspect(value)}")
  end

  defp non_negative!(value, _name) when is_integer(value) and value >= 0, do: value

  defp non_negative!(value, name),
    do: raise(ArgumentError, "invalid proposal #{name}: #{inspect(value)}")

  defp digest(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> canonical()
  defp canonical(value), do: value

  defp require_exact_keys!(map, keys, context) do
    unless MapSet.new(Map.keys(map)) == MapSet.new(keys) do
      raise ArgumentError, "#{context} has unexpected or missing keys"
    end

    :ok
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right),
    do: left == right

  defp secure_equal?(_left, _right), do: false
end

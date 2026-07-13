Mix.Task.run("app.start")

alias DSEx.Optimizer.GEPA.ComBee

record_count = 64
retention_capacity = 12
records = Enum.map(0..(record_count - 1), &%{id: &1})
candidate = %{main: "current instruction"}

reducer = fn _candidate, _component, reducer_records, _iteration, metadata ->
  Process.sleep(2 + length(reducer_records) * 3)

  retained =
    case metadata.phase do
      :final ->
        reducer_records
        |> Enum.take(retention_capacity)
        |> Enum.flat_map(fn record ->
          record
          |> Map.fetch!("ComBeeIntermediateUpdate")
          |> Jason.decode!()
        end)

      _phase ->
        reducer_records |> Enum.take(retention_capacity) |> Enum.map(& &1.id)
    end
    |> Enum.uniq()

  Jason.encode!(retained)
end

measure = fn fun ->
  started = System.monotonic_time(:microsecond)
  result = fun.()
  elapsed = System.monotonic_time(:microsecond) - started
  {result, elapsed / 1_000}
end

{naive_update, naive_ms} =
  measure.(fn ->
    reducer.(candidate, :main, records, 1, %{aggregation: :naive, phase: :single})
  end)

policy =
  [duplication_factor: 2, max_concurrency: 8]
  |> ComBee.resolve(record_count, record_count, 17)
  |> ComBee.resolve_concurrency(8, 1)
  |> ComBee.bound_timeout(5_000)

{{:ok, combee_update, report}, combee_ms} =
  measure.(fn -> ComBee.aggregate(reducer, candidate, :main, records, 1, policy) end)

naive_retained = Jason.decode!(naive_update)
combee_retained = Jason.decode!(combee_update)

output = %{
  harness: "provider-free-capacity-simulation-v1",
  claim_scope: "structural only; not paper or dataset parity",
  configuration: %{
    records: record_count,
    reducer_input_capacity_per_call: retention_capacity,
    simulated_delay_ms: "2 + 3 * reducer_input_count",
    seed: 17,
    duplication_factor: policy.duplication_factor,
    group_count: report.group_count
  },
  naive_large_batch: %{
    wall_time_ms: naive_ms,
    reducer_calls: 1,
    retained_unique_records: length(naive_retained),
    retention_ratio: length(naive_retained) / record_count
  },
  combee: %{
    wall_time_ms: combee_ms,
    reducer_calls: report.reflection_calls,
    dispatched_first_level_calls: report.first_level_calls,
    dispatched_final_calls: report.final_calls,
    retained_unique_records: length(combee_retained),
    retention_ratio: length(combee_retained) / record_count,
    status: report.status
  }
}

IO.puts(Jason.encode!(output, pretty: true))

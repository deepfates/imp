defmodule DSEx.BenchmarkTruth.FailureCampaign do
  @moduledoc false

  alias DSEx.Streaming.Messages.{StatusMessage, StreamListener, StreamResponse}

  @local_cases [
    "task_cancellation_releases_admission",
    "async_concurrency_is_bounded",
    "partial_stream_failure_is_terminal",
    "optimizer_checkpoint_round_trip_and_tamper"
  ]

  def run(opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 10)
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)
    validate_positive!(:iterations, iterations)
    validate_positive!(:max_concurrency, max_concurrency)
    baseline = runtime_snapshot()

    cases = [
      repeat("task_cancellation_releases_admission", iterations, &cancellation_iteration/0),
      repeat("async_concurrency_is_bounded", iterations, fn ->
        concurrency_iteration(max_concurrency)
      end),
      repeat("partial_stream_failure_is_terminal", iterations, &partial_stream_iteration/0),
      repeat(
        "optimizer_checkpoint_round_trip_and_tamper",
        iterations,
        &checkpoint_iteration/0
      )
    ]

    settle_runtime()
    final = runtime_snapshot()
    local_complete? = Enum.all?(cases, & &1["passing"])

    %{
      "schema_version" => 1,
      "evidence_tier" => "t0_deterministic_failure_recovery",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "configuration" => %{
        "iterations" => iterations,
        "max_concurrency" => max_concurrency
      },
      "summary" => %{
        "local_cases" => length(cases),
        "local_passing" => Enum.count(cases, & &1["passing"]),
        "local_complete" => local_complete?,
        "release_complete" => false,
        "remaining_live_lanes" => 2
      },
      "runtime" => %{
        "before" => baseline,
        "after" => final,
        "leak_free" => leak_free?(baseline, final)
      },
      "cases" => cases,
      "remaining" => [
        %{
          "id" => "provider_retry_timeout_idempotency_live",
          "status" => "blocked_on_live_probe",
          "required" => true
        },
        %{
          "id" => "training_retrieval_tool_agent_recovery_live",
          "status" => "blocked_on_live_probe",
          "required" => true
        }
      ],
      "scope" => @local_cases
    }
  end

  defp repeat(id, iterations, fun) do
    outcomes = Enum.map(1..iterations, fn iteration -> normalize(fun, iteration) end)
    passing = Enum.count(outcomes, & &1["passing"])

    %{
      "id" => id,
      "iterations" => iterations,
      "passing_iterations" => passing,
      "failing_iterations" => iterations - passing,
      "flake_rate" => (iterations - passing) / iterations,
      "passing" => passing == iterations,
      "outcomes" => outcomes
    }
  end

  defp normalize(fun, iteration) do
    started = System.monotonic_time()

    result =
      try do
        case fun.() do
          {:ok, evidence} -> {true, evidence}
          {:error, reason} -> {false, %{reason: inspect(reason)}}
          other -> {false, %{reason: "invalid campaign result", result: inspect(other)}}
        end
      rescue
        error -> {false, %{exception: Exception.message(error)}}
      catch
        kind, reason -> {false, %{caught: inspect({kind, reason})}}
      end

    {passing?, evidence} = result

    %{
      "iteration" => iteration,
      "passing" => passing?,
      "duration_native" => System.monotonic_time() - started,
      "evidence" => json_safe(evidence)
    }
  end

  defp cancellation_iteration do
    owner = self()

    task =
      DSEx.Tasks.async_nolink(fn ->
        send(owner, {:campaign_started, self()})
        Process.sleep(:infinity)
      end)

    receive do
      {:campaign_started, pid} when pid == task.pid -> :ok
    after
      1_000 -> raise "campaign task did not start"
    end

    _ = DSEx.Tasks.cancel(task, 100)
    settle_runtime()
    status = DSEx.Tasks.admission_status()

    if not Process.alive?(task.pid) and status == %{active: 0, queued: 0} do
      {:ok, %{admission: status, task_alive: false}}
    else
      {:error, %{admission: status, task_alive: Process.alive?(task.pid)}}
    end
  end

  defp concurrency_iteration(max_concurrency) do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, peak: 0} end)

    results =
      DSEx.context([async_max_workers: max_concurrency], fn ->
        1..(max_concurrency * 3)
        |> DSEx.Tasks.async_stream(
          fn value ->
            Agent.update(tracker, fn state ->
              active = state.active + 1
              %{active: active, peak: max(state.peak, active)}
            end)

            Process.sleep(2)
            Agent.update(tracker, &%{&1 | active: &1.active - 1})
            value
          end,
          max_concurrency: max_concurrency,
          timeout: 1_000
        )
        |> Enum.to_list()
      end)

    state = Agent.get(tracker, & &1)
    Agent.stop(tracker)
    ordered? = results == Enum.map(1..(max_concurrency * 3), &{:ok, &1})

    if ordered? and state.active == 0 and state.peak <= max_concurrency do
      {:ok, %{peak: state.peak, limit: max_concurrency, ordered: true}}
    else
      {:error, %{state: state, ordered: ordered?}}
    end
  end

  defp partial_stream_iteration do
    owner = self()
    reason = {:provider_failed, 503}

    listener =
      StreamListener.new(
        field: :answer,
        on_chunk: &send(owner, {:campaign_chunk, &1}),
        on_status: &send(owner, {:campaign_status, &1})
      )

    events = [
      %StreamResponse{chunk: "[[ ## answer ## ]]partial"},
      %StreamResponse{chunk: {:error, reason}, done: true}
    ]

    ^events = listener |> StreamListener.attach(events) |> Enum.to_list()
    messages = drain_messages([])

    terminal_errors =
      Enum.count(messages, fn
        {:campaign_chunk, %StreamResponse{chunk: {:error, ^reason}, done: true}} -> true
        _ -> false
      end)

    statuses =
      for {:campaign_status, %StatusMessage{status: status}} <- messages, do: status

    if terminal_errors == 1 and statuses == [:started, :error] do
      {:ok, %{terminal_errors: terminal_errors, statuses: statuses}}
    else
      {:error, %{terminal_errors: terminal_errors, statuses: statuses}}
    end
  end

  defp checkpoint_iteration do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-failure-campaign-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    program = DSEx.predict("question -> answer", config: [temperature: 0.2])
    candidate = DSEx.Optimizer.Artifact.candidate("champion", program, score: 1.0)
    artifact = DSEx.Optimizer.Artifact.new(candidate, [], provenance: %{campaign: true})

    try do
      :ok = DSEx.Optimizer.Artifact.write!(artifact, path)
      restored = DSEx.Optimizer.Artifact.read!(path)
      summary = DSEx.Optimizer.Artifact.inspect(restored)
      encoded = File.read!(path)
      tampered = String.replace(encoded, "0.2", "0.3", global: false)
      File.write!(path, tampered)

      tamper_rejected? =
        try do
          DSEx.Optimizer.Artifact.read!(path)
          false
        rescue
          _error -> true
        end

      if summary.champion_id == "champion" and summary.revision == 1 and tamper_rejected? do
        {:ok, %{champion_id: summary.champion_id, revision: 1, tamper_rejected: true}}
      else
        {:error, %{summary: summary, tamper_rejected: tamper_rejected?}}
      end
    after
      File.rm(path)
    end
  end

  defp drain_messages(acc) do
    receive do
      {tag, _payload} = message when tag in [:campaign_chunk, :campaign_status] ->
        drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp runtime_snapshot do
    %{
      "admission" => json_safe(DSEx.Tasks.admission_status()),
      "linked_tasks" => active_children(DSEx.Tasks.supervisor()),
      "unlinked_tasks" => active_children(DSEx.Tasks.unlinked_supervisor())
    }
  end

  defp active_children(supervisor) do
    supervisor |> Task.Supervisor.children() |> Enum.count(&Process.alive?/1)
  end

  defp settle_runtime do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      if DSEx.Tasks.admission_status() == %{active: 0, queued: 0} do
        {:halt, :ok}
      else
        Process.sleep(2)
        {:cont, nil}
      end
    end)
  end

  defp leak_free?(before, after_snapshot) do
    after_snapshot["admission"] == %{"active" => 0, "queued" => 0} and
      after_snapshot["linked_tasks"] <= before["linked_tasks"] and
      after_snapshot["unlinked_tasks"] <= before["unlinked_tasks"]
  end

  defp validate_positive!(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(name, value) do
    raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
  end

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_atom(value), do: to_string(value)
  defp json_safe(value), do: value
end

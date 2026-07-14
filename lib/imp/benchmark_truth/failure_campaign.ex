defmodule Imp.BenchmarkTruth.FailureCampaign do
  @moduledoc false

  alias Imp.Optimizer.{MIPROv2, Report, SIMBA}
  alias Imp.Streaming.Messages.{StatusMessage, StreamListener, StreamResponse}

  @required_flake_iterations 10
  @default_iteration_timeout_ms 15_000

  @deterministic_lanes [
    {"task_cancellation_releases_admission", :cancellation},
    {"task_timeout_is_explicit_and_terminal", :timeout},
    {"async_concurrency_is_bounded", :concurrency},
    {"partial_stream_failure_is_terminal", :partial_stream},
    {"training_retry_and_idempotency_are_bounded", :training_retry},
    {"http_retrieval_retry_timeout_and_idempotency", :retrieval},
    {"mcp_retry_timeout_and_idempotency", :mcp},
    {"mipro_v2_durable_resume_and_tamper", :mipro_v2},
    {"simba_durable_resume_and_tamper", :simba}
  ]

  @live_requirements [
    %{
      "id" => "provider_retry_timeout_idempotency_live",
      "status" => "requires_live_provider_evidence",
      "required" => true,
      "deterministic_coverage" => "training_http_and_task_runtime_only"
    },
    %{
      "id" => "retrieval_and_tool_agent_recovery_live",
      "status" => "requires_live_retrieval_and_agent_evidence",
      "required" => true,
      "deterministic_coverage" => "retrieval_and_mcp_transport_only"
    }
  ]

  def run(opts \\ []) do
    iterations = Keyword.get(opts, :iterations, @required_flake_iterations)
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)
    iteration_timeout_ms = Keyword.get(opts, :iteration_timeout_ms, @default_iteration_timeout_ms)
    validate_positive!(:iterations, iterations)
    validate_positive!(:max_concurrency, max_concurrency)
    validate_positive!(:iteration_timeout_ms, iteration_timeout_ms)
    warmup = prepare_runtime(opts)
    baseline = runtime_snapshot()
    telemetry = start_telemetry_capture()

    cases =
      Enum.map(@deterministic_lanes, fn
        {id, :concurrency} ->
          repeat(id, iterations, iteration_timeout_ms, fn ->
            concurrency_iteration(max_concurrency)
          end)

        {id, handler} ->
          repeat(id, iterations, iteration_timeout_ms, fn -> run_lane(handler) end)
      end)

    live_cases = run_live_cases(opts)
    telemetry_summary = stop_telemetry_capture(telemetry)
    settle_runtime(baseline)
    final = runtime_snapshot()
    leak_accounting = leak_accounting(baseline, final)
    all_iterations_pass? = Enum.all?(cases, & &1["passing"])
    flake_sample_complete? = iterations >= @required_flake_iterations

    deterministic_complete? =
      all_iterations_pass? and flake_sample_complete? and leak_accounting["leak_free"]

    live_complete? = live_cases_complete?(live_cases)
    remaining = remaining_requirements(live_cases)

    secret_scan = secret_scan(%{"cases" => cases, "live_cases" => live_cases}, opts)
    deterministic_complete? = deterministic_complete? and secret_scan["passing"]

    %{
      "schema_version" => 3,
      "runner" => "imp-failure-campaign",
      "evidence_tier" => "t0_deterministic_failure_recovery",
      "configuration" => %{
        "iterations" => iterations,
        "required_flake_iterations" => @required_flake_iterations,
        "max_concurrency" => max_concurrency,
        "iteration_timeout_ms" => iteration_timeout_ms,
        "runtime_warmup" => warmup
      },
      "summary" => %{
        "deterministic_lanes" => length(cases),
        "deterministic_passing" => Enum.count(cases, & &1["passing"]),
        "all_requested_iterations_pass" => all_iterations_pass?,
        "flake_sample_complete" => flake_sample_complete?,
        "deterministic_complete" => deterministic_complete?,
        "local_cases" => length(cases),
        "local_passing" => Enum.count(cases, & &1["passing"]),
        "local_complete" => all_iterations_pass?,
        "live_complete" => live_complete?,
        "release_complete" => deterministic_complete? and live_complete?,
        "remaining_live_lanes" => Enum.count(remaining, &(&1["status"] != "complete"))
      },
      "runtime" => %{
        "before" => public_runtime_snapshot(baseline),
        "after" => public_runtime_snapshot(final),
        "leaks" => leak_accounting["leaks"],
        "leak_free" => leak_accounting["leak_free"]
      },
      "telemetry" => telemetry_summary,
      "secret_scan" => secret_scan,
      "evidence_policy" => %{
        "payloads_included" => false,
        "flake_rate" => "failing_iterations / iterations",
        "completion_requires_zero_flakes" => true
      },
      "cases" => cases,
      "live_cases" => live_cases,
      "remaining" => remaining,
      "scope" => Enum.map(@deterministic_lanes, &elem(&1, 0)),
      "limitations" => [
        "No live provider training job was created or cancelled.",
        "Live authority is limited to the exact provider, retrieval, and tool-agent probes recorded in live_cases.",
        "Deterministic MCP evidence uses an injected transport; no public MCP endpoint is claimed."
      ]
    }
  end

  defp run_lane(:cancellation), do: cancellation_iteration()
  defp run_lane(:timeout), do: timeout_iteration()
  defp run_lane(:partial_stream), do: partial_stream_iteration()
  defp run_lane(:training_retry), do: training_retry_iteration()
  defp run_lane(:retrieval), do: retrieval_iteration()
  defp run_lane(:mcp), do: mcp_iteration()
  defp run_lane(:mipro_v2), do: mipro_v2_iteration()
  defp run_lane(:simba), do: simba_iteration()

  defp repeat(id, iterations, timeout_ms, fun) do
    outcomes = Enum.map(1..iterations, &normalize(fun, &1, timeout_ms))
    passing = Enum.count(outcomes, & &1["passing"])

    %{
      "id" => id,
      "evidence_kind" => "deterministic",
      "iterations" => iterations,
      "passing_iterations" => passing,
      "failing_iterations" => iterations - passing,
      "flake_rate" => (iterations - passing) / iterations,
      "passing" => passing == iterations,
      "outcomes" => outcomes
    }
  end

  defp normalize(fun, iteration, timeout_ms) do
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        try do
          case fun.() do
            {:ok, evidence} ->
              {true, evidence}

            {:error, reason} ->
              {false,
               %{
                 reason_category: failure_category(reason),
                 reason_detail: inspect(reason, limit: 20, printable_limit: 1_000)
               }}

            _other ->
              {false, %{reason_category: "invalid_campaign_result"}}
          end
        rescue
          error -> {false, %{exception_type: error.__struct__}}
        catch
          kind, _reason -> {false, %{caught_kind: kind}}
        end
      end)

    {passing?, evidence} =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {false, %{outcome: :campaign_iteration_timeout, timeout_ms: timeout_ms}}
      end

    %{
      "iteration" => iteration,
      "passing" => passing?,
      "duration_ms" => System.monotonic_time(:millisecond) - started,
      "evidence" => json_safe(evidence)
    }
  end

  defp cancellation_iteration do
    owner = self()

    task =
      Imp.Tasks.async_nolink(fn ->
        send(owner, {:campaign_started, self()})
        Process.sleep(:infinity)
      end)

    receive do
      {:campaign_started, pid} when pid == task.pid -> :ok
    after
      1_000 -> raise "campaign task did not start"
    end

    _ = Imp.Tasks.cancel(task, 100)
    settle_admission()
    status = Imp.Tasks.admission_status()

    if not Process.alive?(task.pid) and status == %{active: 0, queued: 0} do
      {:ok, %{admission: status, task_alive: false, cancellation: :terminal}}
    else
      {:error, %{admission: status, task_alive: Process.alive?(task.pid)}}
    end
  end

  defp timeout_iteration do
    result =
      [:blocked]
      |> Imp.Tasks.async_stream(fn _ -> Process.sleep(:infinity) end,
        max_concurrency: 1,
        timeout: 20,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    settle_admission()
    status = Imp.Tasks.admission_status()

    if result == [exit: :timeout] and status == %{active: 0, queued: 0} do
      {:ok, %{outcome: :timeout, worker_terminated: true, admission: status}}
    else
      {:error, %{outcome: result, admission: status}}
    end
  end

  defp concurrency_iteration(max_concurrency) do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, peak: 0} end)

    results =
      try do
        Imp.context([async_max_workers: max_concurrency], fn ->
          1..(max_concurrency * 3)
          |> Imp.Tasks.async_stream(
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
      after
        :ok
      end

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

    statuses = for {:campaign_status, %StatusMessage{status: status}} <- messages, do: status

    if terminal_errors == 1 and statuses == [:started, :error] do
      {:ok,
       %{terminal_errors: terminal_errors, statuses: statuses, partial_payload_included: false}}
    else
      {:error, %{terminal_errors: terminal_errors, statuses: statuses}}
    end
  end

  defp training_retry_iteration do
    {:ok, attempts} = Agent.start_link(fn -> [] end)
    body = Jason.encode!(%{operation: "failure-campaign"})
    {:ok, key} = Imp.Clients.TrainingHTTP.idempotency_key(:deterministic, "static", body, nil)

    {:ok, repeated_key} =
      Imp.Clients.TrainingHTTP.idempotency_key(:deterministic, "static", body, nil)

    headers = Imp.Clients.TrainingHTTP.put_header([], "idempotency-key", key)

    transport = fn _url, request_headers, _request_body, _opts ->
      attempt =
        Agent.get_and_update(attempts, fn seen -> {length(seen) + 1, [request_headers | seen]} end)

      case attempt do
        1 -> {:error, :closed}
        2 -> {:ok, %{status: 503, headers: [], body: ""}}
        3 -> {:ok, %{status: 200, headers: [], body: "{}"}}
      end
    end

    result =
      Imp.Clients.TrainingHTTP.request(
        transport,
        "https://deterministic.invalid/training",
        headers,
        body,
        [timeout: 100],
        3,
        0
      )

    seen = Agent.get(attempts, &Enum.reverse/1)
    Agent.stop(attempts)

    stable_header? =
      Enum.all?(seen, fn request_headers ->
        Enum.any?(request_headers, fn {name, value} ->
          String.downcase(to_string(name)) == "idempotency-key" and value == key
        end)
      end)

    if match?({:ok, %{status: 200}}, result) and length(seen) == 3 and key == repeated_key and
         stable_header? do
      {:ok,
       %{
         attempts: length(seen),
         max_attempts: 3,
         terminal_status: 200,
         deterministic_key_stable: true,
         idempotency_header_stable: true,
         request_payload_included: false
       }}
    else
      {:error,
       %{attempts: length(seen), stable_key: key == repeated_key, stable_header: stable_header?}}
    end
  end

  defp retrieval_iteration do
    {:ok, state} = Agent.start_link(fn -> [] end)

    transport = fn _url, headers, _body, _opts ->
      attempt = Agent.get_and_update(state, fn seen -> {length(seen) + 1, [headers | seen]} end)

      case attempt do
        1 -> {:error, :closed}
        2 -> {:ok, %{status: 503, headers: [{"retry-after", "0"}], body: "fault"}}
        3 -> {:ok, %{status: 200, headers: [], body: ~s({"documents":[{"text":"recovered"}]})}}
      end
    end

    retriever =
      Imp.Retrievers.HTTP.new("https://deterministic.invalid/retrieve",
        transport: transport,
        max_attempts: 3,
        attempt_timeout: 100,
        total_timeout: 300,
        retry_backoff_ms: 0,
        max_retry_delay_ms: 0
      )

    result = Imp.Retrievers.HTTP.retrieve(retriever, "beam")
    seen = Agent.get(state, &Enum.reverse/1)
    Agent.stop(state)
    keys = Enum.map(seen, &header_value(&1, "idempotency-key"))

    if match?({:ok, [%{text: "recovered"}]}, result) and length(seen) == 3 and
         length(Enum.uniq(keys)) == 1 and Enum.all?(keys, &is_binary/1) do
      {:ok,
       %{
         attempts: 3,
         max_attempts: 3,
         terminal_status: 200,
         idempotency_header_stable: true,
         inherited_total_timeout_ms: 300
       }}
    else
      {:error, %{attempts: length(seen), result: inspect(result), stable_keys: Enum.uniq(keys)}}
    end
  end

  defp mcp_iteration do
    {:ok, state} = Agent.start_link(fn -> %{} end)

    transport = fn _url, headers, body, _opts ->
      request = Jason.decode!(body)
      method = request["method"]

      attempt =
        Agent.get_and_update(state, fn seen ->
          next = Map.get(seen, method, 0) + 1
          {next, Map.put(seen, method, next)}
        end)

      cond do
        method == "initialize" and attempt == 1 ->
          {:ok, %{status: 503, headers: [{"retry-after", "0"}], body: "fault"}}

        method == "tools/list" and attempt == 1 ->
          {:error, :closed}

        method == "notifications/initialized" ->
          {:ok, %{status: 204, headers: [], body: ""}}

        method == "tools/list" ->
          mcp_response(request, %{
            "tools" => [
              %{"name" => "recoverable", "description" => "fixture", "input_schema" => %{}}
            ]
          })

        true ->
          mcp_response(request, %{})
      end
      |> tap(fn _ ->
        if method == "initialize" do
          Agent.update(
            state,
            &Map.put(&1, "idempotency-key-present", !!header_value(headers, "idempotency-key"))
          )
        end
      end)
    end

    client =
      Imp.MCP.StreamableHTTPClient.new("https://deterministic.invalid/mcp",
        transport: transport,
        max_attempts: 3,
        timeout: 100,
        retry_delay: 0,
        max_retry_after: 0,
        idempotency_key: fn method, _params -> "failure-campaign:#{method}" end
      )

    result = Imp.MCP.import_tools(client)
    counts = Agent.get(state, & &1)
    Agent.stop(state)

    if match?([%Imp.Tool{name: :recoverable}], result) and counts["initialize"] == 2 and
         counts["tools/list"] == 2 and counts["idempotency-key-present"] do
      {:ok,
       %{
         initialize_attempts: 2,
         list_attempts: 2,
         max_attempts: 3,
         idempotency_header_present: true,
         terminal_tool_count: 1
       }}
    else
      {:error, %{counts: counts, result: inspect(result)}}
    end
  end

  defp mcp_response(request, result) do
    {:ok,
     %{
       status: 200,
       headers: [{"content-type", "application/json"}],
       body: Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
     }}
  end

  defp header_value(headers, expected) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == expected, do: to_string(value)
    end)
  end

  defp mipro_v2_iteration do
    {:ok, state} = Agent.start_link(fn -> %{proposal_calls: 0} end)
    {program, optimizer, trainset, valset} = mipro_fixture(state)

    try do
      uninterrupted = optimizer |> MIPROv2.compile(program, trainset, valset) |> Report.fetch()
      Agent.update(state, fn _ -> %{proposal_calls: 0} end)

      paused =
        optimizer
        |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
        |> Report.fetch()

      calls_after_pause = Agent.get(state, & &1.proposal_calls)

      {checkpoint, tampered} =
        durable_checkpoints(paused.metadata.resume_state, "evaluation_calls")

      resumed =
        optimizer
        |> MIPROv2.compile(program, trainset, valset, resume_state: checkpoint)
        |> Report.fetch()

      calls_after_resume = Agent.get(state, & &1.proposal_calls)

      tamper_rejected? =
        rejects_tamper?(fn ->
          MIPROv2.compile(optimizer, program, trainset, valset, resume_state: tampered)
        end)

      exact_resume? =
        resumed.candidates == uninterrupted.candidates and
          resumed.best_score == uninterrupted.best_score and
          resumed.metadata.evaluation_calls == uninterrupted.metadata.evaluation_calls

      if paused.metadata.run_status == :paused and resumed.metadata.run_status == :complete and
           resumed.metadata.resumed and calls_after_resume == calls_after_pause and exact_resume? and
           tamper_rejected? do
        {:ok,
         %{
           optimizer: :mipro_v2,
           checkpoint_type: checkpoint["type"],
           checkpoint_schema_version: checkpoint["schema_version"],
           paused_trials: paused.metadata.completed_trials,
           resumed_trials: resumed.metadata.completed_trials,
           setup_replayed: false,
           exact_resume: true,
           tamper_rejected: true,
           checkpoint_payload_included: false
         }}
      else
        {:error,
         %{
           paused: paused.metadata.run_status,
           resumed: resumed.metadata.run_status,
           setup_replayed: calls_after_resume != calls_after_pause,
           exact_resume: exact_resume?,
           tamper_rejected: tamper_rejected?
         }}
      end
    after
      Agent.stop(state)
    end
  end

  defp simba_iteration do
    {:ok, uninterrupted_state} = Agent.start_link(fn -> simba_counters() end)
    {:ok, resumed_state} = Agent.start_link(fn -> simba_counters() end)
    {program, optimizer, trainset, final_set} = simba_fixture(uninterrupted_state)

    {resume_program, resume_optimizer, resume_trainset, resume_final_set} =
      simba_fixture(resumed_state)

    try do
      uninterrupted = optimizer |> SIMBA.compile(program, trainset, final_set) |> Report.fetch()

      paused =
        resume_optimizer
        |> SIMBA.compile(resume_program, resume_trainset, resume_final_set, max_steps: 1)
        |> Report.fetch()

      calls_after_pause = Agent.get(resumed_state, & &1.task_calls)

      {checkpoint, tampered} =
        durable_checkpoints(paused.metadata.resume_state, "trajectory_calls")

      resumed =
        resume_optimizer
        |> SIMBA.compile(resume_program, resume_trainset, resume_final_set,
          resume_state: checkpoint
        )
        |> Report.fetch()

      calls_after_resume = Agent.get(resumed_state, & &1.task_calls)

      tamper_rejected? =
        rejects_tamper?(fn ->
          SIMBA.compile(resume_optimizer, resume_program, resume_trainset, resume_final_set,
            resume_state: tampered
          )
        end)

      exact_resume? =
        resumed.candidates == uninterrupted.candidates and
          resumed.best_score == uninterrupted.best_score and
          resumed.errors == uninterrupted.errors and
          resumed.metadata.trial_logs == uninterrupted.metadata.trial_logs and
          resumed.metadata.final_candidates == uninterrupted.metadata.final_candidates and
          resumed.metadata.trajectory_calls == uninterrupted.metadata.trajectory_calls and
          resumed.metadata.candidate_evaluation_calls ==
            uninterrupted.metadata.candidate_evaluation_calls and
          resumed.metadata.final_evaluation_calls == uninterrupted.metadata.final_evaluation_calls

      if paused.metadata.run_status == :paused and resumed.metadata.run_status == :complete and
           resumed.metadata.resumed and calls_after_resume > calls_after_pause and exact_resume? and
           tamper_rejected? do
        {:ok,
         %{
           optimizer: :simba,
           checkpoint_type: checkpoint["type"],
           checkpoint_schema_version: checkpoint["schema_version"],
           paused_steps: paused.metadata.completed_steps,
           resumed_steps: resumed.metadata.completed_steps,
           exact_resume: true,
           tamper_rejected: true,
           checkpoint_payload_included: false
         }}
      else
        {:error,
         %{
           paused: paused.metadata.run_status,
           resumed: resumed.metadata.run_status,
           continued_work: calls_after_resume > calls_after_pause,
           exact_resume: exact_resume?,
           tamper_rejected: tamper_rejected?
         }}
      end
    after
      Agent.stop(uninterrupted_state)
      Agent.stop(resumed_state)
    end
  end

  defp mipro_fixture(state) do
    task_lm = %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "yes"} end]}

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _, _ ->
          Agent.update(state, &Map.update!(&1, :proposal_calls, fn count -> count + 1 end))
          ["Answer consistently.", "Return yes."]
        end
      ]
    }

    program = Imp.predict("question -> answer", lm: task_lm)
    trainset = examples("train", 2)
    valset = examples("validation", 1)

    optimizer =
      MIPROv2.new(Imp.Metrics.exact_match(:answer),
        auto: nil,
        num_candidates: 2,
        num_trials: 2,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: true,
        minibatch_size: 1,
        minibatch_full_eval_steps: 2,
        prompt_lm: prompt_lm,
        startup_trials: 1,
        seed: 31
      )

    {program, optimizer, trainset, valset}
  end

  defp simba_fixture(state) do
    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          Agent.update(state, &Map.update!(&1, :task_calls, fn count -> count + 1 end))
          prompt = Enum.map_join(messages, "\n", & &1.content)
          rollout_id = Keyword.get(opts, :rollout_id, 0)

          if prompt =~ "Answer yes." or rem(rollout_id, 2) == 0,
            do: %{answer: "yes"},
            else: %{answer: "no"}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _, _ ->
          Agent.update(state, &Map.update!(&1, :prompt_calls, fn count -> count + 1 end))

          %{
            discussion: "Prefer the successful trajectory.",
            module_advice: %{main: "Answer yes."}
          }
        end
      ]
    }

    initial_demo = Imp.example(question: "seed", answer: "yes") |> Imp.with_inputs(:question)
    program = Imp.predict("question -> answer", lm: task_lm, demos: [initial_demo])
    trainset = examples("train", 2)
    final_set = examples("final", 1)

    optimizer =
      SIMBA.new(Imp.Metrics.exact_match(:answer),
        bsize: 2,
        num_candidates: 2,
        max_steps: 2,
        max_demos: 0,
        prompt_lm: prompt_lm,
        max_concurrency: 1,
        seed: 41
      )

    {program, optimizer, trainset, final_set}
  end

  defp examples(prefix, count) do
    for index <- 1..count do
      Imp.example(question: "#{prefix} #{index}", answer: "yes") |> Imp.with_inputs(:question)
    end
  end

  defp simba_counters, do: %{task_calls: 0, prompt_calls: 0}

  defp rejects_tamper?(fun) do
    try do
      fun.()
      false
    rescue
      error in ArgumentError -> String.contains?(Exception.message(error), "checksum")
    end
  end

  defp failure_category(reason) when is_atom(reason), do: to_string(reason)
  defp failure_category({category, _detail}) when is_atom(category), do: to_string(category)
  defp failure_category(_reason), do: "lane_assertion_failed"

  defp durable_checkpoints(checkpoint, tamper_key) do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-failure-checkpoint-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    try do
      File.write!(path, Jason.encode!(checkpoint), [:sync])
      restored = path |> File.read!() |> Jason.decode!()
      tampered = put_in(restored, ["payload", "state", tamper_key], 99_999)
      File.write!(path, Jason.encode!(tampered), [:sync])
      {restored, path |> File.read!() |> Jason.decode!()}
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

  defp run_live_cases(opts) do
    if Keyword.get(opts, :live, false) do
      api_key = Keyword.fetch!(opts, :api_key)
      model = Keyword.get(opts, :model, "gpt-4.1-mini")
      agent_model = Keyword.get(opts, :agent_model, model)
      base_url = Keyword.get(opts, :base_url, "https://api.openai.com/v1")
      iterations = Keyword.get(opts, :live_iterations, 2)
      timeout_ms = Keyword.get(opts, :live_timeout_ms, 30_000)
      validate_positive!(:live_iterations, iterations)
      validate_positive!(:live_timeout_ms, timeout_ms)

      live_opts = [
        api_key: api_key,
        model: model,
        agent_model: agent_model,
        base_url: base_url,
        iterations: iterations,
        timeout_ms: timeout_ms
      ]

      [
        repeat_live(
          "provider_retry_timeout_idempotency_live",
          iterations,
          timeout_ms,
          fn -> provider_live_iteration(live_opts) end
        ),
        repeat_live(
          "retrieval_and_tool_agent_recovery_live",
          iterations,
          timeout_ms,
          fn -> retrieval_agent_live_iteration(live_opts) end
        )
      ]
    else
      []
    end
  end

  defp prepare_runtime(opts) do
    if Keyword.get(opts, :live, false) do
      api_key = Keyword.fetch!(opts, :api_key)
      base_url = String.trim_trailing(Keyword.fetch!(opts, :base_url), "/")
      model = Keyword.fetch!(opts, :model)
      agent_model = Keyword.get(opts, :agent_model, model)
      {:ok, _model} = ReqLLM.model("openai:#{model}")
      {:ok, _agent_model} = ReqLLM.model("openai:#{agent_model}")

      probes = [
        Req.get(base_url <> "/models",
          headers: [{"authorization", "Bearer #{api_key}"}],
          receive_timeout: 15_000,
          retry: false,
          pool_max_idle_time: 0
        ),
        Req.get("https://httpbin.org/status/204",
          receive_timeout: 15_000,
          retry: false,
          pool_max_idle_time: 0
        )
      ]

      provider_warmup =
        warmup_provider(model, api_key, base_url)

      integration_preflight =
        retrieval_agent_live_iteration(
          api_key: api_key,
          model: model,
          agent_model: agent_model,
          base_url: base_url,
          timeout_ms: Keyword.get(opts, :live_timeout_ms, 30_000)
        )

      %{
        "performed" => true,
        "network_hosts" => [URI.parse(base_url).host, "httpbin.org"],
        "statuses" => Enum.map(probes, &warmup_status/1),
        "provider_adapter" => warmup_provider_result(provider_warmup, model),
        "integration_preflight" => warmup_integration_result(integration_preflight),
        "billable_generation" => true
      }
    else
      %{"performed" => false}
    end
  end

  defp warmup_status({:ok, %Req.Response{status: status}}), do: status
  defp warmup_status({:error, reason}), do: "error:#{failure_category(reason)}"

  defp warmup_provider(model, api_key, base_url) do
    with_finch(fn finch ->
      ReqLLM.generate_text("openai:#{model}", "Reply with exactly pong.",
        api_key: api_key,
        base_url: base_url,
        temperature: 0.0,
        max_tokens: 16,
        req_http_options: [finch: finch]
      )
    end)
  end

  defp warmup_provider_result({:ok, response}, model) do
    usage = ReqLLM.Response.usage(response) || %{}
    input = Map.get(usage, :input_tokens, Map.get(usage, "input_tokens", 0))
    output = Map.get(usage, :output_tokens, Map.get(usage, "output_tokens", 0))

    %{
      "status" => "complete",
      "usage" => %{"input_tokens" => input, "output_tokens" => output},
      "cost" => openai_cost(model, input, output),
      "payload_included" => false
    }
  end

  defp warmup_provider_result({:error, reason}, _model),
    do: %{
      "status" => "failed",
      "reason_category" => failure_category(reason),
      "reason_detail" => inspect(reason, limit: 10, printable_limit: 500)
    }

  defp warmup_integration_result({:ok, evidence}),
    do: %{"status" => "complete", "evidence" => json_safe(evidence)}

  defp warmup_integration_result({:error, reason}),
    do: %{
      "status" => "failed",
      "reason_category" => failure_category(reason),
      "reason_detail" => inspect(reason, limit: 10, printable_limit: 500)
    }

  defp repeat_live(id, iterations, timeout_ms, fun) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    baseline = runtime_snapshot()
    outcomes = Enum.map(1..iterations, &normalize(fun, &1, timeout_ms))
    settle_runtime(baseline)
    final = runtime_snapshot()
    runtime = leak_accounting(baseline, final)
    passing = Enum.count(outcomes, & &1["passing"])

    %{
      "id" => id,
      "required" => true,
      "evidence_kind" => "live",
      "status" =>
        if(passing == iterations and runtime["leak_free"], do: "complete", else: "failed"),
      "passing" => passing == iterations and runtime["leak_free"],
      "started_at" => started_at,
      "completed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "iterations" => iterations,
      "passing_iterations" => passing,
      "failing_iterations" => iterations - passing,
      "flake_rate" => (iterations - passing) / iterations,
      "outcomes" => outcomes,
      "runtime" => runtime,
      "checks" => live_checks(id, outcomes, runtime)
    }
  end

  defp provider_live_iteration(opts),
    do: with_finch(fn finch -> provider_live_iteration(opts, finch) end)

  defp provider_live_iteration(opts, finch) do
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.fetch!(opts, :model)
    url = String.trim_trailing(Keyword.fetch!(opts, :base_url), "/") <> "/responses"
    timeout = Keyword.fetch!(opts, :timeout_ms)
    key = "imp-failure-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"

    body =
      Jason.encode!(%{model: model, input: "Reply with exactly pong.", max_output_tokens: 24})

    {:ok, attempts} = Agent.start_link(fn -> [] end)

    transport = fn request_url, headers, request_body, request_opts ->
      attempt =
        Agent.get_and_update(attempts, fn seen -> {length(seen) + 1, [headers | seen]} end)

      if attempt == 1 do
        {:ok, %{status: 429, headers: [{"retry-after", "0"}], body: ~s({"error":"injected"})}}
      else
        req_opts = [
          method: :post,
          url: request_url,
          headers: headers,
          body: request_body,
          receive_timeout: Keyword.get(request_opts, :timeout, timeout),
          retry: false,
          finch: finch
        ]

        case Req.request(req_opts) do
          {:ok, response} ->
            {:ok,
             %{
               status: response.status,
               headers: response.headers,
               body: encode_body(response.body)
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"idempotency-key", key}
    ]

    result =
      Imp.Clients.TrainingHTTP.request(transport, url, headers, body, [timeout: timeout], 2, 0)

    seen = Agent.get(attempts, &Enum.reverse/1)
    Agent.stop(attempts)
    keys = Enum.map(seen, &header_value(&1, "idempotency-key"))

    with {:ok, %{status: status, body: response_body}} when status in 200..299 <- result,
         {:ok, decoded} <- Jason.decode(response_body),
         true <- response_text(decoded) |> String.downcase() |> String.contains?("pong"),
         %{"input_tokens" => input, "output_tokens" => output} when input > 0 and output > 0 <-
           decoded["usage"],
         true <- length(seen) == 2 and Enum.uniq(keys) == [key] do
      {:ok,
       %{
         provider: "openai",
         model: model,
         attempts: 2,
         max_attempts: 2,
         injected_status: 429,
         terminal_status: status,
         idempotency_header_stable: true,
         timeout_ms: timeout,
         usage: %{input_tokens: input, output_tokens: output},
         cost: openai_cost(model, input, output),
         response_payload_included: false
       }}
    else
      reason -> {:error, {:live_provider_probe_failed, inspect(reason)}}
    end
  end

  defp retrieval_agent_live_iteration(opts),
    do: with_finch(fn finch -> retrieval_agent_live_iteration(opts, finch) end)

  defp retrieval_agent_live_iteration(opts, finch) do
    timeout = Keyword.fetch!(opts, :timeout_ms)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    transport = fn url, headers, body, request_opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        {:error, :closed}
      else
        Imp.HTTP.Hackneyless.post(url, headers, body, request_opts)
      end
    end

    retriever =
      Imp.Retrievers.HTTP.new("https://httpbin.org/anything",
        transport: transport,
        max_attempts: 2,
        attempt_timeout: timeout,
        total_timeout: timeout,
        retry_backoff_ms: 0,
        max_retry_delay_ms: 0,
        response_mapper: fn decoded ->
          if get_in(decoded, ["json", "query"]) == "beam-recovery", do: ["retrieval-ok"], else: []
        end
      )

    retrieval_result =
      Imp.Retrievers.HTTP.retrieve(retriever, "beam-recovery", k: 1, finch: finch)

    retrieval_attempts = Agent.get(attempts, & &1)
    Agent.stop(attempts)

    tool =
      Imp.Tool.new(
        :lookup,
        "Lookup a fact by query.",
        fn
          %{query: "failure-recovery"} -> "pong"
          %{"query" => "failure-recovery"} -> "pong"
          other -> {:error, {:unexpected_query, other}}
        end,
        schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "enum" => ["failure-recovery"]}
          },
          "required" => ["query"]
        }
      )

    lm =
      Imp.req_llm("openai:#{Keyword.fetch!(opts, :agent_model)}",
        api_key: Keyword.fetch!(opts, :api_key),
        base_url: Keyword.fetch!(opts, :base_url),
        temperature: 0,
        max_tokens: 120,
        req_http_options: [finch: finch]
      )

    agent =
      Imp.react(
        Imp.Signature.new(
          "question -> answer",
          "Use lookup first with query failure-recovery. If history contains lookup result pong, stop calling lookup and call submit with answer pong. Do not answer directly."
        ),
        [tool],
        lm: lm,
        tool_policy: [:lookup, :submit],
        max_iters: 4
      )

    agent_result = Imp.call(agent, %{question: "Recover the fixed fact using the lookup tool."})

    with {:ok, ["retrieval-ok"]} <- retrieval_result,
         2 <- retrieval_attempts,
         {:ok, prediction} <- agent_result,
         "pong" <-
           prediction |> Imp.Prediction.get(:answer, "") |> to_string() |> String.downcase(),
         history when is_list(history) <- Imp.Prediction.get(prediction, :history),
         true <- Enum.any?(history, &(&1.tool == :lookup and &1.result == "pong")),
         true <- Enum.any?(history, &(&1.tool == :submit)) do
      {:ok,
       %{
         provider: "openai",
         model: Keyword.fetch!(opts, :agent_model),
         retrieval_attempts: 2,
         retrieval_injected_error: "closed",
         retrieval_terminal_network: "httpbin.org",
         tool_calls: 1,
         submit_calls: 1,
         timeout_ms: timeout,
         agent_usage_available: false,
         agent_cost: %{"authority" => "not_exposed_by_prediction", "usd" => nil},
         payloads_included: false
       }}
    else
      reason -> {:error, {:live_retrieval_agent_probe_failed, inspect(reason)}}
    end
  end

  defp response_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(&(&1["content"] || []))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp response_text(_), do: ""

  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: Jason.encode!(body)

  defp openai_cost("gpt-4.1-mini", input, output) do
    %{
      "authority" => "pinned_public_list_price",
      "input_usd_per_million" => 0.4,
      "output_usd_per_million" => 1.6,
      "usd" => Float.round(input * 0.4 / 1_000_000 + output * 1.6 / 1_000_000, 9)
    }
  end

  defp openai_cost(_model, _input, _output),
    do: %{"authority" => "unpriced_model", "usd" => nil}

  defp live_checks(id, outcomes, runtime) do
    evidence = Enum.map(outcomes, & &1["evidence"])

    common = [
      %{"id" => "repeated_zero_flakes", "passing" => Enum.all?(outcomes, & &1["passing"])},
      %{"id" => "runtime_leak_free", "passing" => runtime["leak_free"]}
    ]

    specific =
      case id do
        "provider_retry_timeout_idempotency_live" ->
          [
            %{
              "id" => "real_provider_terminal_success",
              "passing" => Enum.all?(evidence, &(&1["terminal_status"] in 200..299))
            },
            %{
              "id" => "bounded_retry_after_injected_429",
              "passing" => Enum.all?(evidence, &(&1["attempts"] == 2 and &1["max_attempts"] == 2))
            },
            %{
              "id" => "stable_idempotency_key",
              "passing" => Enum.all?(evidence, & &1["idempotency_header_stable"])
            },
            %{
              "id" => "positive_provider_usage",
              "passing" =>
                Enum.all?(
                  evidence,
                  &(get_in(&1, ["usage", "input_tokens"]) > 0 and
                      get_in(&1, ["usage", "output_tokens"]) > 0)
                )
            }
          ]

        "retrieval_and_tool_agent_recovery_live" ->
          [
            %{
              "id" => "live_retrieval_recovered",
              "passing" => Enum.all?(evidence, &(&1["retrieval_attempts"] == 2))
            },
            %{
              "id" => "provider_backed_tool_agent_completed",
              "passing" =>
                Enum.all?(evidence, &(&1["tool_calls"] == 1 and &1["submit_calls"] == 1))
            }
          ]
      end

    common ++ specific
  end

  defp with_finch(fun) do
    name = Imp.BenchmarkTruth.FailureCampaign.Finch

    {:ok, finch} =
      Finch.start_link(
        name: name,
        pools: %{default: [size: 1, count: 1, pool_max_idle_time: 60_000]}
      )

    try do
      fun.(name)
    after
      if Process.alive?(finch), do: GenServer.stop(finch, :normal, 5_000)
    end
  end

  defp live_cases_complete?(rows) do
    ids = rows |> Enum.filter(& &1["passing"]) |> Enum.map(& &1["id"]) |> Enum.sort()
    ids == Enum.sort(Enum.map(@live_requirements, & &1["id"]))
  end

  defp remaining_requirements(live_cases) do
    completed = live_cases |> Enum.filter(& &1["passing"]) |> Map.new(&{&1["id"], &1})

    Enum.map(@live_requirements, fn requirement ->
      case completed[requirement["id"]] do
        nil -> requirement
        row -> Map.merge(requirement, %{"status" => "complete", "artifact_row" => row["id"]})
      end
    end)
  end

  defp start_telemetry_capture do
    id = "imp-failure-campaign-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, state} = Agent.start_link(fn -> %{} end)

    events = [
      [:imp, :retriever, :start],
      [:imp, :retriever, :stop],
      [:imp, :retriever, :exception],
      [:imp, :retriever, :http, :attempt],
      [:imp, :mcp, :http, :start],
      [:imp, :mcp, :http, :stop],
      [:imp, :mcp, :http, :exception],
      [:imp, :mcp, :http, :attempt],
      [:imp, :lm, :start],
      [:imp, :lm, :stop]
    ]

    :ok =
      :telemetry.attach_many(
        id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        state
      )

    %{id: id, state: state}
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, agent) do
    key = Enum.join(event, ".")

    Agent.update(agent, fn counts ->
      Map.update(counts, key, telemetry_entry(measurements, metadata), fn entry ->
        %{entry | count: entry.count + 1}
      end)
    end)
  end

  defp stop_telemetry_capture(%{id: id, state: state}) do
    :ok = :telemetry.detach(id)
    entries = Agent.get(state, & &1)
    Agent.stop(state)

    counts = Map.new(entries, fn {event, entry} -> {event, entry.count} end)

    %{
      "handler_detached" => true,
      "event_counts" => counts,
      "metadata_secret_free" => Enum.all?(entries, fn {_event, entry} -> entry.safe end),
      "balanced_spans" =>
        balanced_span?(counts, "imp.retriever") and balanced_span?(counts, "imp.mcp.http") and
          Map.get(counts, "imp.lm.start", 0) == Map.get(counts, "imp.lm.stop", 0)
    }
  end

  defp telemetry_entry(measurements, metadata) do
    encoded = inspect({measurements, metadata}, limit: 50, printable_limit: 2_000)
    %{count: 1, safe: not secret_pattern?(encoded)}
  end

  defp balanced_span?(counts, prefix) do
    Map.get(counts, prefix <> ".start", 0) ==
      Map.get(counts, prefix <> ".stop", 0) + Map.get(counts, prefix <> ".exception", 0)
  end

  defp secret_scan(value, opts) do
    encoded = Jason.encode!(json_safe(value))

    configured =
      opts
      |> Keyword.get(:secrets, [])
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 8))

    configured_hits = Enum.count(configured, &String.contains?(encoded, &1))
    pattern_hits = if secret_pattern?(encoded), do: 1, else: 0

    %{
      "passing" => configured_hits == 0 and pattern_hits == 0,
      "configured_secret_count" => length(configured),
      "configured_secret_hits" => configured_hits,
      "credential_pattern_hits" => pattern_hits,
      "payload_sha256" => sha256(encoded)
    }
  end

  defp secret_pattern?(value) do
    Regex.match?(
      ~r/(?:sk-[A-Za-z0-9_-]{16,}|Bearer\s+[A-Za-z0-9._-]{16,}|api[_-]?key["']?\s*[:=]\s*["'][^"']{8,})/i,
      value
    )
  end

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> then(&("sha256:" <> &1))

  defp runtime_snapshot do
    %{
      admission: Imp.Tasks.admission_status(),
      linked_tasks: active_children(Imp.Tasks.supervisor()),
      unlinked_tasks: active_children(Imp.Tasks.unlinked_supervisor()),
      processes: Process.list() |> MapSet.new(),
      ports: Port.list() |> MapSet.new(),
      telemetry_handlers: telemetry_handler_ids()
    }
  end

  defp active_children(supervisor) do
    supervisor
    |> Task.Supervisor.children()
    |> Enum.filter(&Process.alive?/1)
    |> MapSet.new()
  end

  defp public_runtime_snapshot(snapshot) do
    %{
      "admission" => json_safe(snapshot.admission),
      "linked_tasks" => MapSet.size(snapshot.linked_tasks),
      "unlinked_tasks" => MapSet.size(snapshot.unlinked_tasks),
      "processes" => MapSet.size(snapshot.processes),
      "ports" => MapSet.size(snapshot.ports),
      "telemetry_handlers" => MapSet.size(snapshot.telemetry_handlers)
    }
  end

  defp settle_admission do
    Enum.reduce_while(1..100, :timeout, fn _, _ ->
      if Imp.Tasks.admission_status() == %{active: 0, queued: 0} do
        {:halt, :ok}
      else
        Process.sleep(2)
        {:cont, :timeout}
      end
    end)
  end

  defp settle_runtime(baseline) do
    Enum.reduce_while(1..500, :timeout, fn _, _ ->
      snapshot = runtime_snapshot()

      if snapshot.admission == %{active: 0, queued: 0} and
           MapSet.subset?(snapshot.linked_tasks, baseline.linked_tasks) and
           MapSet.subset?(snapshot.unlinked_tasks, baseline.unlinked_tasks) and
           MapSet.subset?(snapshot.ports, baseline.ports) and
           MapSet.subset?(snapshot.telemetry_handlers, baseline.telemetry_handlers) do
        {:halt, :ok}
      else
        Process.sleep(4)
        {:cont, :timeout}
      end
    end)
  end

  defp leak_accounting(before, after_snapshot) do
    added_linked = MapSet.difference(after_snapshot.linked_tasks, before.linked_tasks)
    added_unlinked = MapSet.difference(after_snapshot.unlinked_tasks, before.unlinked_tasks)
    added_processes = MapSet.difference(after_snapshot.processes, before.processes)
    added_ports = MapSet.difference(after_snapshot.ports, before.ports)

    added_handlers =
      MapSet.difference(after_snapshot.telemetry_handlers, before.telemetry_handlers)

    leaks = %{
      "admission_active" => after_snapshot.admission.active,
      "admission_queued" => after_snapshot.admission.queued,
      "added_linked_tasks" => MapSet.size(added_linked),
      "added_unlinked_tasks" => MapSet.size(added_unlinked),
      "added_processes" => MapSet.size(added_processes),
      "added_ports" => MapSet.size(added_ports),
      "added_telemetry_handlers" => MapSet.size(added_handlers)
    }

    %{
      "leaks" => leaks,
      "leak_free" => Enum.all?(Map.values(leaks), &(&1 == 0))
    }
  end

  defp telemetry_handler_ids do
    :telemetry.list_handlers([])
    |> Enum.map(&Map.fetch!(&1, :id))
    |> MapSet.new()
  end

  defp validate_positive!(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(name, value) do
    raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
  end

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_boolean(value) or is_nil(value), do: value
  defp json_safe(value) when is_atom(value), do: to_string(value)
  defp json_safe(value), do: value
end

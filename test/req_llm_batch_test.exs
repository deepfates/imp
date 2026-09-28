defmodule ReqLLMBatchTest do
  use ExUnit.Case, async: true

  alias Imp.Clients.ReqLLM, as: ReqLLMClient
  alias Imp.Clients.ReqLLMBatch

  defmodule Idle do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_program, _inputs), do: Process.sleep(:infinity)
  end

  test "retries transient failures and records explicit terminal and malformed outcomes" do
    checkpoint = checkpoint_path("outcomes")
    {:ok, attempts} = Agent.start_link(fn -> %{} end)

    dispatcher = fn request, _context ->
      attempt =
        Agent.get_and_update(attempts, fn counts ->
          next = Map.get(counts, request.id, 0) + 1
          {next, Map.put(counts, request.id, next)}
        end)

      case {request.id, attempt} do
        {"retry", 1} -> {:transient, :rate_limited}
        {"retry", 2} -> {:ok, %{answer: "done"}}
        {"terminal", 1} -> {:terminal, :unauthorized}
        {"malformed", 1} -> {:malformed, :invalid_json}
        {"exhausted", _attempt} -> {:transient, :overloaded}
      end
    end

    requests = [
      %{id: "retry", payload: %{prompt: "a"}},
      %{id: "terminal", payload: %{prompt: "b"}},
      %{id: "malformed", payload: %{prompt: "c"}},
      %{id: "exhausted", payload: %{prompt: "d"}}
    ]

    assert {:ok, summary} =
             ReqLLMBatch.run(requests, dispatcher,
               checkpoint: checkpoint,
               max_attempts: 3,
               num_threads: 2,
               clock: fake_clock()
             )

    assert summary.complete?

    assert %{
             succeeded: 1,
             transient_failure: 1,
             terminal_failure: 1,
             malformed_output: 1
           } = summary.counts

    assert %{status: :succeeded, attempts: 2, output: %{"answer" => "done"}} =
             find_request(summary, "retry")

    assert %{status: :terminal_failure, attempts: 1, reason: "unauthorized"} =
             find_request(summary, "terminal")

    assert %{status: :malformed_output, attempts: 1, reason: "invalid_json"} =
             find_request(summary, "malformed")

    assert %{status: :transient_failure, attempts: 3, reason: "overloaded"} =
             find_request(summary, "exhausted")

    checkpoint_state = checkpoint |> File.read!() |> Jason.decode!()
    sequences = Enum.map(checkpoint_state["events"], & &1["sequence"])
    assert sequences == Enum.to_list(1..length(sequences))

    assert Enum.count(checkpoint_state["events"], &(&1["kind"] == "attempt_outcome")) == 7
  end

  test "a dispatcher that crashes after it may have sent is ambiguous and not re-dispatched" do
    checkpoint = checkpoint_path("dispatcher-crash")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    dispatcher = fn _request, _context ->
      Agent.update(counter, &(&1 + 1))
      raise "provider process failed"
    end

    assert {:ok, summary} =
             ReqLLMBatch.run([%{id: "one", payload: []}], dispatcher,
               checkpoint: checkpoint,
               max_attempts: 3
             )

    assert Agent.get(counter, & &1) == 1
    assert %{status: :ambiguous, attempts: 1} = find_request(summary, "one")
    assert summary.complete?
  end

  test "a dispatch still running at the timeout is ambiguous and not re-dispatched" do
    checkpoint = checkpoint_path("dispatcher-timeout")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    dispatcher = fn _request, _context ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(:infinity)
    end

    assert {:ok, summary} =
             ReqLLMBatch.run([%{id: "slow", payload: []}], dispatcher,
               checkpoint: checkpoint,
               max_attempts: 3,
               timeout: 50
             )

    assert Agent.get(counter, & &1) == 1
    assert %{status: :ambiguous, attempts: 1} = find_request(summary, "slow")
  end

  test "a dispatcher that throws or exits is ambiguous and not re-dispatched" do
    checkpoint = checkpoint_path("dispatcher-throw-exit")
    {:ok, calls} = Agent.start_link(fn -> %{} end)

    dispatcher = fn request, _context ->
      Agent.update(calls, &Map.update(&1, request.id, 1, fn count -> count + 1 end))

      case request.id do
        "throws" -> throw(:sent_then_lost)
        "exits" -> exit(:sent_then_lost)
      end
    end

    requests = [%{id: "throws", payload: []}, %{id: "exits", payload: []}]

    assert {:ok, summary} =
             ReqLLMBatch.run(requests, dispatcher, checkpoint: checkpoint, max_attempts: 3)

    assert Agent.get(calls, & &1) == %{"throws" => 1, "exits" => 1}
    assert %{status: :ambiguous, attempts: 1} = find_request(summary, "throws")
    assert %{status: :ambiguous, attempts: 1} = find_request(summary, "exits")
  end

  test "req_llm_dispatcher retries only failures that say the request did not run" do
    checkpoint = checkpoint_path("lm-errors")
    {:ok, calls} = Agent.start_link(fn -> %{} end)

    client =
      ReqLLMClient.new("anthropic:test",
        req_module: __MODULE__.FailingStub,
        calls: calls
      )

    # {name, calls expected, final status}
    cases = [
      # No answer after the request may have left: sent once.
      {"timeout", 1, :ambiguous},
      {"closed", 1, :ambiguous},
      # A status that may follow a request that ran: sent once.
      {"server_error", 1, :ambiguous},
      {"bad_gateway", 1, :ambiguous},
      {"gateway_timeout", 1, :ambiguous},
      # Never sent, or not processed and try later: retried.
      {"refused", 2, :succeeded},
      {"pool", 2, :succeeded},
      {"finch_pool", 2, :succeeded},
      {"rate_limited", 2, :succeeded},
      {"request_timeout", 2, :succeeded},
      {"overloaded", 2, :succeeded},
      {"unavailable", 2, :succeeded},
      # Rejected without running, and a retry will not help.
      {"unauthorized", 1, :terminal_failure},
      {"bad_request", 1, :terminal_failure}
    ]

    requests =
      Enum.map(
        cases,
        fn {name, _calls, _status} ->
          %{id: name, payload: %{"messages" => [%{"role" => "user", "content" => name}]}}
        end
      )

    assert {:ok, summary} =
             ReqLLMBatch.run(requests, ReqLLMBatch.req_llm_dispatcher(client),
               checkpoint: checkpoint,
               max_attempts: 3,
               clock: fake_clock()
             )

    invocations = Agent.get(calls, & &1)

    for {name, expected_calls, expected_status} <- cases do
      assert {name, invocations[name], find_request(summary, name).status} ==
               {name, expected_calls, expected_status}
    end
  end

  test "an error ReqLLM built with every header keeps only retry-after" do
    client =
      ReqLLMClient.new("anthropic:test", req_module: __MODULE__.HeaderedErrorStub)

    assert {:error, %Imp.LMError{reason: reason} = error} =
             ReqLLMClient.generate(client, [%{role: :user, content: "hi"}], [])

    assert reason.headers == %{"retry-after" => ["1"]}
    assert reason.cause.headers == %{"retry-after" => ["1"]}
    refute inspect(error, limit: :infinity) =~ "cookie-secret-value"
  end

  test "a streaming HTTP error keeps only retry-after of the response's headers" do
    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        {429,
         [
           {"retry-after", "3"},
           {"set-cookie", "session=cookie-secret-value"},
           {"openai-organization", "org-secret-value"}
         ], %{error: %{message: "rate limited"}}}
      end)

    client =
      Imp.req_llm(%{provider: :openai, id: "stream-leak-model", base_url: base_url},
        api_key: "local-test-key",
        max_retries: 0
      )

    result =
      try do
        client |> ReqLLMClient.stream([%{role: :user, content: "hi"}]) |> Enum.to_list()
      rescue
        error -> error
      catch
        kind, reason -> {kind, reason}
      end

    text = inspect(result, limit: :infinity, printable_limit: :infinity)

    assert [%{chunk: {:error, %Imp.LMError{reason: %ReqLLM.Error.API.Stream{} = error}}}] =
             result

    assert error.cause.headers == %{"retry-after" => ["3"]}
    refute text =~ "cookie-secret-value"
    refute text =~ "org-secret-value"
  end

  test "an error keeps only retry-after of the response's headers" do
    secret_headers = [
      {"set-cookie", "session=cookie-secret-value"},
      {"openai-organization", "org-secret-value"},
      {"x-request-id", "req-secret-value"}
    ]

    checkpoint = checkpoint_path("header-leak")
    {:ok, script} = Agent.start_link(fn -> [401, 429] end)

    adapter = fn request ->
      status = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)

      headers =
        if status == 429, do: [{"retry-after", "0"} | secret_headers], else: secret_headers

      {request, Req.Response.new(status: status, headers: headers)}
    end

    client =
      Imp.req_llm(%{provider: :openai, id: "leak-model"},
        api_key: "local-test-key",
        cache: false,
        max_retries: 0,
        req_http_options: [adapter: adapter]
      )

    messages = [%{role: :user, content: "hi"}]

    assert {:error, %Imp.LMError{status: 401} = unauthorized} =
             ReqLLMClient.generate(client, messages, [])

    assert {:error, %Imp.LMError{status: 429} = limited} =
             ReqLLMClient.generate(client, messages, [])

    assert unauthorized.reason.headers == nil
    assert limited.reason.headers == %{"retry-after" => ["0"]}

    {:ok, run} = Imp.Run.start(%__MODULE__.Idle{}, %{})

    Imp.Run.with_context(run.control, fn ->
      Imp.Run.emit(:model_response, error: unauthorized)
      Imp.Run.emit(:model_response, error: limited)
    end)

    events = Imp.Run.events(run)
    :ok = Imp.Run.cancel(run)

    Agent.update(script, fn _ -> [429] end)

    {:ok, _summary} =
      ReqLLMBatch.run(
        [%{id: "only", payload: %{"messages" => [%{"role" => "user", "content" => "hi"}]}}],
        ReqLLMBatch.req_llm_dispatcher(client),
        checkpoint: checkpoint,
        max_attempts: 1
      )

    seen = [
      inspect(unauthorized, limit: :infinity, printable_limit: :infinity),
      inspect(limited, limit: :infinity, printable_limit: :infinity),
      inspect(events, limit: :infinity, printable_limit: :infinity),
      events |> Enum.map(&Imp.Run.Event.to_map/1) |> Jason.encode!(),
      File.read!(checkpoint)
    ]

    for text <- seen, secret <- ~w(cookie-secret-value org-secret-value req-secret-value) do
      refute text =~ secret
    end
  end

  describe "req_llm_dispatcher through the Req transport" do
    # Counts every request that reaches the Req adapter, which is where
    # ReqLLM's own retry step would send again.
    test "a timeout is sent once, not retried by ReqLLM or the batch" do
      {summary, sends} = run_through_transport([:timeout, :timeout, :timeout, :timeout])

      assert sends == 1
      assert %{status: :ambiguous, attempts: 1} = find_request(summary, "only")
    end

    test "a timeout followed by a refused connection is sent once" do
      {summary, sends} =
        run_through_transport([:timeout, :econnrefused, :econnrefused, :econnrefused])

      assert sends == 1
      assert %{status: :ambiguous, attempts: 1} = find_request(summary, "only")
    end

    test "a refused connection is retried by the batch, one send per attempt" do
      {summary, sends} = run_through_transport(List.duplicate(:econnrefused, 12))

      assert sends == 3
      assert %{status: :transient_failure, attempts: 3} = find_request(summary, "only")
    end

    test "an exhausted pool, as Req reports it, is retried by the batch" do
      pool = %Req.HTTPError{protocol: :http1, reason: :pool_not_available}
      {summary, sends} = run_through_transport(List.duplicate(pool, 12))

      assert sends == 3
      assert %{status: :transient_failure, attempts: 3} = find_request(summary, "only")
    end
  end

  test "resume treats a 0.5.0 checkpoint's transient failures as ambiguous" do
    checkpoint = checkpoint_path("schema-1")

    assert {:ok, _summary} =
             ReqLLMBatch.run(
               [%{id: "timed-out", payload: []}, %{id: "not-started", payload: []}],
               fn _request, _context -> {:ok, "done"} end,
               checkpoint: checkpoint,
               max_attempts: 3
             )

    # Rewrite it as 0.5.0 would have left it: a timeout recorded as a
    # transient failure with attempts left, and a request not yet sent.
    state = checkpoint |> File.read!() |> Jason.decode!()

    requests =
      Enum.map(state["requests"], fn
        %{"id" => "timed-out"} = request ->
          request
          |> Map.merge(%{
            "status" => "transient_failure",
            "attempts" => 1,
            "reason" => ~s({:dispatcher_exit, "{:timeout, ...}"})
          })
          |> Map.delete("output")

        request ->
          request |> Map.merge(%{"status" => "pending", "attempts" => 0}) |> Map.delete("output")
      end)

    File.write!(
      checkpoint,
      Jason.encode!(%{state | "schema_version" => 1, "requests" => requests})
    )

    parent = self()

    resume_dispatcher = fn request, _context ->
      send(parent, {:resumed_dispatch, request.id})
      {:ok, "done"}
    end

    assert {:ok, summary} = ReqLLMBatch.resume(checkpoint, resume_dispatcher)
    assert_receive {:resumed_dispatch, "not-started"}
    refute_receive {:resumed_dispatch, "timed-out"}

    assert %{status: :ambiguous, attempts: 1} = find_request(summary, "timed-out")
    assert %{status: :succeeded, attempts: 1} = find_request(summary, "not-started")

    saved = checkpoint |> File.read!() |> Jason.decode!()
    assert saved["schema_version"] == 2

    assert Enum.any?(saved["events"], fn event ->
             event["request_id"] == "timed-out" and event["kind"] == "schema_migration" and
               event["status"] == "ambiguous"
           end)
  end

  describe "the wait before a retry" do
    test "honours retry-after in seconds and as an HTTP date" do
      clock = fake_clock()

      {dispatcher, sent} =
        scripted_dispatcher(clock, %{
          "seconds" => [rate_limited(%{"retry-after" => ["2"]}), {:ok, "done"}],
          "date" => [
            rate_limited([{"Retry-After", "Sun, 27 Sep 2026 12:00:07 GMT"}]),
            {:ok, "done"}
          ]
        })

      assert {:ok, summary} =
               ReqLLMBatch.run(
                 [%{id: "seconds", payload: []}, %{id: "date", payload: []}],
                 dispatcher,
                 checkpoint: checkpoint_path("retry-after"),
                 num_threads: 2,
                 clock: clock
               )

      assert summary.counts == %{succeeded: 2}
      # Both failed at 0; the batch slept until each could be sent again.
      # The first sends run concurrently, so their order is not fixed.
      assert MapSet.new(sent.()) ==
               MapSet.new([{"seconds", 0}, {"date", 0}, {"seconds", 2_000}, {"date", 7_000}])

      assert sleeps(clock) == [2_000, 5_000]
    end

    test "a waiting request holds no dispatch slot" do
      clock = fake_clock()

      {dispatcher, sent} =
        scripted_dispatcher(clock, %{
          "limited" => [rate_limited(%{"retry-after" => ["5"]}), {:ok, "done"}],
          "other" => [{:ok, "done"}]
        })

      assert {:ok, _summary} =
               ReqLLMBatch.run(
                 [%{id: "limited", payload: []}, %{id: "other", payload: []}],
                 dispatcher,
                 checkpoint: checkpoint_path("no-slot"),
                 num_threads: 1,
                 clock: clock
               )

      assert sent.() == [{"limited", 0}, {"other", 0}, {"limited", 5_000}]
    end

    test "backs off exponentially, with jitter, when the provider gives no wait" do
      clock = fake_clock()
      failures = List.duplicate({:transient, :overloaded}, 4)
      {dispatcher, sent} = scripted_dispatcher(clock, %{"backoff" => failures})

      assert {:ok, summary} =
               ReqLLMBatch.run([%{id: "backoff", payload: []}], dispatcher,
                 checkpoint: checkpoint_path("backoff"),
                 max_attempts: 4,
                 clock: clock
               )

      assert %{status: :transient_failure, attempts: 4} = find_request(summary, "backoff")
      assert length(sent.()) == 4
      [first, second, third] = sleeps(clock)
      assert first in 250..500
      assert second in 500..1_000
      assert third in 1_000..2_000
    end

    test "backoff is capped by :max_retry_wait" do
      clock = fake_clock()

      {dispatcher, _sent} =
        scripted_dispatcher(clock, %{"capped" => List.duplicate({:transient, :x}, 4)})

      assert {:ok, _summary} =
               ReqLLMBatch.run([%{id: "capped", payload: []}], dispatcher,
                 checkpoint: checkpoint_path("capped"),
                 max_attempts: 4,
                 max_retry_wait: 300,
                 clock: clock
               )

      assert Enum.all?(sleeps(clock), &(&1 <= 300))
    end

    test "a retry-after past the deadline stops retrying, and resume retries it" do
      clock = fake_clock()

      {dispatcher, sent} =
        scripted_dispatcher(clock, %{
          "limited" => [rate_limited(%{"retry-after" => ["30"]}), {:ok, "done"}]
        })

      checkpoint = checkpoint_path("deadline")

      assert {:ok, summary} =
               Imp.Deadline.with_deadline(10_000, fn ->
                 ReqLLMBatch.run([%{id: "limited", payload: []}], dispatcher,
                   checkpoint: checkpoint,
                   clock: clock
                 )
               end)

      assert sleeps(clock) == []
      assert sent.() == [{"limited", 0}]
      assert %{status: :transient_failure, attempts: 1} = find_request(summary, "limited")
      refute summary.complete?

      state = checkpoint |> File.read!() |> Jason.decode!()

      assert Enum.any?(state["events"], fn event ->
               event["kind"] == "retry_stopped" and event["details"]["reason"] == "deadline"
             end)

      assert {:ok, resumed} = ReqLLMBatch.resume(checkpoint, dispatcher, clock: clock)
      assert %{status: :succeeded, attempts: 2} = find_request(resumed, "limited")
    end

    test "a retry-after longer than :max_retry_wait stops retrying" do
      clock = fake_clock()

      {dispatcher, sent} =
        scripted_dispatcher(clock, %{"limited" => [rate_limited(%{"retry-after" => ["120"]})]})

      assert {:ok, summary} =
               ReqLLMBatch.run([%{id: "limited", payload: []}], dispatcher,
                 checkpoint: checkpoint_path("over-cap"),
                 clock: clock
               )

      assert sleeps(clock) == []
      assert sent.() == [{"limited", 0}]
      assert %{status: :transient_failure, attempts: 1} = find_request(summary, "limited")
      refute summary.complete?
    end

    test "resume waits for the retry time the checkpoint holds" do
      clock = fake_clock()

      {dispatcher, sent} =
        scripted_dispatcher(clock, %{
          "limited" => [rate_limited(%{"retry-after" => ["2"]}), {:ok, "done"}]
        })

      checkpoint = checkpoint_path("resume-not-before")

      assert {:ok, summary} =
               Imp.Deadline.with_deadline(1_000, fn ->
                 ReqLLMBatch.run([%{id: "limited", payload: []}], dispatcher,
                   checkpoint: checkpoint,
                   clock: clock
                 )
               end)

      assert %{status: :transient_failure, attempts: 1} = find_request(summary, "limited")
      saved = checkpoint |> File.read!() |> Jason.decode!()
      assert [%{"not_before" => "2026-09-27T12:00:02.000Z"}] = saved["requests"]

      # Resumed at once: nothing is sent before 12:00:02.
      assert {:ok, resumed} = ReqLLMBatch.resume(checkpoint, dispatcher, clock: clock)
      assert %{status: :succeeded, attempts: 2} = find_request(resumed, "limited")
      assert sent.() == [{"limited", 0}, {"limited", 2_000}]
      assert sleeps(clock) == [2_000]
    end

    test "resume stops a retry again, unsent, when its time is past the deadline" do
      clock = fake_clock()

      {dispatcher, sent} =
        scripted_dispatcher(clock, %{"limited" => [rate_limited(%{"retry-after" => ["30"]})]})

      checkpoint = checkpoint_path("resume-deadline")

      Imp.Deadline.with_deadline(1_000, fn ->
        ReqLLMBatch.run([%{id: "limited", payload: []}], dispatcher,
          checkpoint: checkpoint,
          clock: clock
        )
      end)

      assert {:ok, resumed} =
               Imp.Deadline.with_deadline(10_000, fn ->
                 ReqLLMBatch.resume(checkpoint, dispatcher, clock: clock)
               end)

      assert sent.() == [{"limited", 0}]
      assert sleeps(clock) == []
      assert %{status: :transient_failure, attempts: 1} = find_request(resumed, "limited")
      refute resumed.complete?
    end

    test "reads retry-after in the RFC 850 and asctime date forms" do
      clock = fake_clock()

      {dispatcher, sent} =
        scripted_dispatcher(clock, %{
          "rfc850" => [
            rate_limited(%{"retry-after" => ["Sunday, 27-Sep-26 12:00:03 GMT"]}),
            {:ok, "done"}
          ],
          "asctime" => [
            rate_limited(%{"retry-after" => ["Sun Sep 27 12:00:05 2026"]}),
            {:ok, "done"}
          ]
        })

      assert {:ok, summary} =
               ReqLLMBatch.run(
                 [%{id: "rfc850", payload: []}, %{id: "asctime", payload: []}],
                 dispatcher,
                 checkpoint: checkpoint_path("date-forms"),
                 num_threads: 2,
                 clock: clock
               )

      assert summary.counts == %{succeeded: 2}

      assert MapSet.new(sent.()) ==
               MapSet.new([{"rfc850", 0}, {"asctime", 0}, {"rfc850", 3_000}, {"asctime", 5_000}])
    end

    test "a trapping process stopped by its parent during the wait exits at once" do
      test_pid = self()

      parent =
        spawn(fn ->
          {:ok, worker} =
            Task.start_link(fn ->
              Process.flag(:trap_exit, true)

              dispatcher = fn _request, _context ->
                send(test_pid, :dispatched)
                rate_limited(%{"retry-after" => ["30"]})
              end

              ReqLLMBatch.run([%{id: "limited", payload: []}], dispatcher,
                checkpoint: checkpoint_path("trapping")
              )
            end)

          send(test_pid, {:worker, worker})

          receive do
            :stop -> Process.exit(worker, :shutdown)
          end

          Process.sleep(:infinity)
        end)

      assert_receive {:worker, worker}, 5_000
      ref = Process.monitor(worker)
      assert_receive :dispatched, 5_000
      Process.sleep(50)
      send(parent, :stop)

      assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}, 500
      Process.exit(parent, :kill)
    end

    test "a 429 through the Req transport waits for its retry-after" do
      clock = fake_clock()
      limited = {429, [{"retry-after", "2"}]}
      {summary, sends} = run_through_transport([limited, limited, limited], clock)

      assert sends == 3
      assert %{status: :transient_failure, attempts: 3} = find_request(summary, "only")
      assert sleeps(clock) == [2_000, 2_000]
    end
  end

  test "resume fails closed for an uncommitted post-dispatch request" do
    checkpoint = checkpoint_path("ambiguous-resume")
    parent = self()

    blocking_dispatcher = fn request, context ->
      case request.id do
        "committed" ->
          send(parent, {:dispatched, request.id, context.attempt})
          {:ok, "already-safe"}

        "in-flight" ->
          send(parent, {:dispatched, request.id, context.attempt})

          receive do
            :never_sent -> {:ok, "unexpected"}
          end
      end
    end

    task =
      Task.async(fn ->
        ReqLLMBatch.run(
          [
            %{id: "committed", payload: %{prompt: "zero"}},
            %{id: "in-flight", payload: %{prompt: "first"}},
            %{id: "not-started", payload: %{prompt: "second"}}
          ],
          blocking_dispatcher,
          checkpoint: checkpoint,
          num_threads: 1
        )
      end)

    assert_receive {:dispatched, "committed", 1}, 1_000
    assert_receive {:dispatched, "in-flight", 1}, 1_000
    Task.shutdown(task, :brutal_kill)

    resume_dispatcher = fn request, context ->
      send(parent, {:resumed_dispatch, request.id, context.attempt})
      {:ok, "committed"}
    end

    assert {:ok, summary} = ReqLLMBatch.resume(checkpoint, resume_dispatcher)
    assert_receive {:resumed_dispatch, "not-started", 1}, 1_000
    refute_receive {:resumed_dispatch, "committed", _attempt}
    refute_receive {:resumed_dispatch, "in-flight", _attempt}

    assert %{status: :succeeded, attempts: 1} = find_request(summary, "committed")
    assert %{status: :ambiguous, attempts: 1} = find_request(summary, "in-flight")
    assert %{status: :succeeded, attempts: 1} = find_request(summary, "not-started")

    state = checkpoint |> File.read!() |> Jason.decode!()

    assert Enum.any?(state["events"], fn event ->
             event["request_id"] == "in-flight" and
               event["kind"] == "resume_reconciliation" and event["status"] == "ambiguous"
           end)
  end

  test "never exceeds configured concurrency" do
    checkpoint = checkpoint_path("concurrency")
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, maximum: 0} end)

    dispatcher = fn request, _context ->
      Agent.update(tracker, fn state ->
        active = state.active + 1
        %{active: active, maximum: max(state.maximum, active)}
      end)

      Process.sleep(30)
      Agent.update(tracker, &%{&1 | active: &1.active - 1})
      {:ok, request.id}
    end

    requests = Enum.map(1..6, &%{id: "request-#{&1}", payload: %{index: &1}})

    assert {:ok, summary} =
             ReqLLMBatch.run(requests, dispatcher,
               checkpoint: checkpoint,
               num_threads: 2
             )

    assert summary.counts == %{succeeded: 6}
    assert Agent.get(tracker, & &1.maximum) == 2
  end

  test "rejects duplicate stable IDs before creating a checkpoint" do
    checkpoint = checkpoint_path("duplicates")
    requests = [%{id: "same", payload: 1}, %{id: "same", payload: 2}]

    assert {:error, {:duplicate_request_ids, ["same"]}} =
             ReqLLMBatch.run(requests, fn _request, _context -> {:ok, nil} end,
               checkpoint: checkpoint
             )

    refute File.exists?(checkpoint)
  end

  test "ReqLLM adapter delegates through the configured provider-neutral client" do
    client =
      ReqLLMClient.new("anthropic:test", req_module: __MODULE__.ReqLLMStub, test_pid: self())

    dispatcher = ReqLLMBatch.req_llm_dispatcher(client, temperature: 0)

    assert {:ok,
            %{
              __imp_lm_output__: %{"answer" => "pong"},
              __imp_lm_metadata__: %{req_llm: %{provider: "anthropic", model: "anthropic:test"}}
            }} =
             dispatcher.(
               %{
                 id: "adapter",
                 payload: %{"messages" => [%{"role" => "user", "content" => "ping"}]}
               },
               %{request_id: "adapter", attempt: 1}
             )

    assert_receive {:req_llm_batch, "anthropic:test", temperature}
    assert temperature == 0.0
  end

  # run/3 JSON-round-trips every payload for checkpoint durability, which turns
  # atom message keys (:role, :content) into strings. The client must match both
  # shapes: a message that falls through to the inspect/1 catch-all reaches the
  # provider as an inspected map while the batch still reports success.
  test "run/3 delivers the documented payload shape to the transport as real messages" do
    checkpoint = checkpoint_path("api-guide-payload")

    client =
      ReqLLMClient.new("anthropic:test",
        req_module: __MODULE__.MessageCapturingStub,
        test_pid: self()
      )

    dispatcher = ReqLLMBatch.req_llm_dispatcher(client, temperature: 0)

    # The exact request payload shape req_llm_dispatcher accepts.
    requests = [
      %{
        id: "question-001",
        payload: %{messages: [%{role: :user, content: "Capital of France?"}]}
      }
    ]

    assert {:ok, summary} = ReqLLMBatch.run(requests, dispatcher, checkpoint: checkpoint)
    assert %{status: :succeeded} = find_request(summary, "question-001")

    assert_receive {:req_llm_batch_messages, transport_messages}

    assert [
             %ReqLLM.Message{
               role: :user,
               content: [%ReqLLM.Message.ContentPart{type: :text, text: "Capital of France?"}]
             }
           ] = transport_messages
  end

  test "req_llm_dispatcher preserves roles for string-keyed round-tripped messages" do
    client =
      ReqLLMClient.new("anthropic:test",
        req_module: __MODULE__.MessageCapturingStub,
        test_pid: self()
      )

    dispatcher = ReqLLMBatch.req_llm_dispatcher(client)

    # This is what a payload looks like after Jason round-trip: string keys,
    # string roles.
    payload = %{
      "messages" => [
        %{"role" => "system", "content" => "You answer tersely."},
        %{"role" => "assistant", "content" => "Previously: Paris."},
        %{"role" => "user", "content" => "Capital of Peru?"}
      ]
    }

    assert {:ok, _output} =
             dispatcher.(
               %{id: "roles", payload: payload},
               %{request_id: "roles", attempt: 1}
             )

    assert_receive {:req_llm_batch_messages, transport_messages}

    assert [
             %ReqLLM.Message{role: :system, content: [%{text: "You answer tersely."}]},
             %ReqLLM.Message{role: :assistant, content: [%{text: "Previously: Paris."}]},
             %ReqLLM.Message{role: :user, content: [%{text: "Capital of Peru?"}]}
           ] = transport_messages
  end

  defmodule HeaderedErrorStub do
    def generate_text(_model, _messages, _opts) do
      headers = %{"set-cookie" => ["session=cookie-secret-value"], "retry-after" => ["1"]}

      {:error,
       %ReqLLM.Error.API.Request{
         reason: "slow down",
         status: 429,
         headers: headers,
         cause: %ReqLLM.Error.API.Request{reason: "inner", headers: headers}
       }}
    end
  end

  defmodule FailingStub do
    # Fails each request's first call in the way its content names, then
    # answers.
    def generate_text(model, [message], opts) do
      [%{text: kind}] = message.content

      call =
        Agent.get_and_update(Keyword.fetch!(opts, :calls), fn calls ->
          next = Map.get(calls, kind, 0) + 1
          {next, Map.put(calls, kind, next)}
        end)

      if call == 1, do: {:error, failure(kind)}, else: answer(model, [message])
    end

    defp failure("timeout"), do: %Req.TransportError{reason: :timeout}
    defp failure("closed"), do: %Mint.TransportError{reason: :closed}
    defp failure("refused"), do: %Req.TransportError{reason: :econnrefused}
    defp failure("pool"), do: %Req.HTTPError{protocol: :http1, reason: :pool_not_available}
    defp failure("finch_pool"), do: %Finch.Error{reason: :pool_not_available}
    defp failure("rate_limited"), do: status_error(429)
    defp failure("request_timeout"), do: status_error(408)
    defp failure("overloaded"), do: status_error(529)
    defp failure("server_error"), do: status_error(500)
    defp failure("bad_gateway"), do: status_error(502)
    defp failure("unavailable"), do: status_error(503)
    defp failure("gateway_timeout"), do: status_error(504)
    defp failure("unauthorized"), do: status_error(401)
    defp failure("bad_request"), do: status_error(400)

    defp status_error(status),
      do: %ReqLLM.Error.API.Request{reason: "status #{status}", status: status}

    defp answer(model, messages) do
      {:ok,
       %ReqLLM.Response{
         id: "after-failure",
         model: model,
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(~s({"answer":"pong"})),
         object: %{"answer" => "pong"}
       }}
    end
  end

  defmodule MessageCapturingStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_batch_messages, messages})

      {:ok,
       %ReqLLM.Response{
         id: "captured-response",
         model: model,
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(~s({"answer":"pong"})),
         object: %{"answer" => "pong"}
       }}
    end
  end

  defmodule ReqLLMStub do
    def generate_text(model, messages, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:req_llm_batch, model, Keyword.fetch!(opts, :temperature)}
      )

      {:ok,
       %ReqLLM.Response{
         id: "batch-response",
         model: model,
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(~s({"answer":"pong"})),
         object: %{"answer" => "pong"}
       }}
    end
  end

  defp find_request(summary, id), do: Enum.find(summary.requests, &(&1.id == id))

  # Runs one request through a real ReqLLM client whose Req adapter fails each
  # send with the next reason in `failures`, and returns the summary and the
  # number of sends that reached the adapter.
  defp run_through_transport(failures, clock \\ fake_clock()) do
    {:ok, script} = Agent.start_link(fn -> %{failures: failures, sends: 0} end)

    adapter = fn request ->
      failure =
        Agent.get_and_update(script, fn %{failures: [next | rest], sends: sends} ->
          {next, %{failures: rest, sends: sends + 1}}
        end)

      case failure do
        reason when is_atom(reason) -> {request, %Req.TransportError{reason: reason}}
        {status, headers} -> {request, Req.Response.new(status: status, headers: headers)}
        exception -> {request, exception}
      end
    end

    client =
      Imp.req_llm(%{provider: :openai, id: "counting-model"},
        api_key: "local-test-key",
        cache: false,
        req_http_options: [adapter: adapter]
      )

    {:ok, summary} =
      ReqLLMBatch.run(
        [%{id: "only", payload: %{"messages" => [%{"role" => "user", "content" => "hi"}]}}],
        ReqLLMBatch.req_llm_dispatcher(client),
        checkpoint: checkpoint_path("transport"),
        max_attempts: 3,
        clock: clock
      )

    {summary, Agent.get(script, & &1.sends)}
  end

  # A clock that moves only when the batch sleeps, and records each sleep.
  defp fake_clock do
    {:ok, agent} = Agent.start_link(fn -> %{now: 0, sleeps: []} end)

    %{
      now: fn -> Agent.get(agent, & &1.now) end,
      utc_now: fn ->
        DateTime.add(~U[2026-09-27 12:00:00Z], Agent.get(agent, & &1.now), :millisecond)
      end,
      sleep: fn ms ->
        Agent.update(agent, &%{&1 | now: &1.now + ms, sleeps: &1.sleeps ++ [ms]})
      end,
      agent: agent
    }
  end

  defp sleeps(clock), do: Agent.get(clock.agent, & &1.sleeps)

  defp rate_limited(headers) do
    {:transient,
     %Imp.LMError{
       status: 429,
       retryable: true,
       reason: %ReqLLM.Error.API.Request{reason: "slow down", status: 429, headers: headers}
     }}
  end

  # Records each dispatch with the clock's time, and answers with the next
  # outcome scripted for the request.
  defp scripted_dispatcher(clock, script) do
    {:ok, log} = Agent.start_link(fn -> %{script: script, sent: []} end)

    dispatcher = fn request, _context ->
      Agent.get_and_update(log, fn %{script: script, sent: sent} = state ->
        [outcome | rest] = Map.fetch!(script, request.id)
        sent = sent ++ [{request.id, clock.now.()}]
        {outcome, %{state | script: Map.put(script, request.id, rest), sent: sent}}
      end)
    end

    {dispatcher, fn -> Agent.get(log, & &1.sent) end}
  end

  defp checkpoint_path(name) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    Path.join(
      System.tmp_dir!(),
      "imp-req-llm-batch-#{name}-#{nonce}.json"
    )
  end
end

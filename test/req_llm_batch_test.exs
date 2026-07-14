defmodule ReqLLMBatchTest do
  use ExUnit.Case, async: true

  alias Imp.Clients.ReqLLM, as: ReqLLMClient
  alias Imp.Clients.ReqLLMBatch

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
               max_concurrency: 2
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

  test "dispatcher crashes are transient and consume retry attempts" do
    checkpoint = checkpoint_path("dispatcher-crash")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    dispatcher = fn _request, _context ->
      attempt = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
      if attempt == 1, do: raise("provider process failed"), else: {:ok, "recovered"}
    end

    assert {:ok, summary} =
             ReqLLMBatch.run([%{id: "one", payload: []}], dispatcher,
               checkpoint: checkpoint,
               max_attempts: 2
             )

    assert %{status: :succeeded, attempts: 2, output: "recovered"} =
             find_request(summary, "one")
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
          max_concurrency: 1
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
               max_concurrency: 2
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

  defp checkpoint_path(name) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    Path.join(
      System.tmp_dir!(),
      "imp-req-llm-batch-#{name}-#{nonce}.json"
    )
  end
end

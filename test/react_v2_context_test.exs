defmodule Imp.ReActV2ContextTest do
  use ExUnit.Case

  test "real structured provider overflow shrinks prompts while full repeated-turn history survives" do
    {:ok, state} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    url =
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        messages = body["messages"]
        Agent.update(state, &(&1 ++ [messages]))

        if length(messages) > 8 do
          {400,
           %{
             "error" => %{
               "message" => "fixture limit",
               "type" => "invalid_request_error",
               "code" => "context_length_exceeded"
             }
           }}
        else
          {200,
           %{
             "id" => "reply",
             "object" => "chat.completion",
             "model" => body["model"],
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => nil,
                   "tool_calls" => [
                     %{
                       "id" => "done",
                       "type" => "function",
                       "function" => %{
                         "name" => "submit",
                         "arguments" => Jason.encode!(%{answer: "done"})
                       }
                     }
                   ]
                 },
                 "finish_reason" => "tool_calls"
               }
             ]
           }}
        end
      end)

    lm =
      Imp.req_llm(%{provider: :openai, id: "fixture", model: "fixture", base_url: url <> "/v1"},
        api_key: "fixture",
        cache: false,
        req_http_options: [retry: false, max_retries: 0]
      )

    program = Imp.react_v2("intent -> answer", [], lm: lm)

    history =
      Enum.reduce(1..12, Imp.history(), fn n, history ->
        {:ok, run} = Imp.Run.start(program, %{intent: "question #{n}", history: history})
        {:ok, prediction} = Task.await(run.task, 30_000)
        assert Imp.get(prediction, :answer) == "done"
        next = Imp.get(prediction, :history)
        assert length(next.messages) == n
        assert Enum.take(next.messages, n - 1) == history.messages

        if projection = Imp.get(prediction, :context_projection) do
          assert projection.omitted_prior_entries > 0
          events = Imp.Run.events(run)
          assert Enum.any?(events, &(&1.kind == :context_projected))
          atif = events |> Enum.map(&Imp.Run.Event.to_map/1) |> Imp.Trajectory.to_atif()

          assert Enum.any?(atif["extra"]["diagnostics"], fn event ->
                   event["event_kind"] == "context_projected" and
                     event["metadata"]["omitted_prior_entries"] > 0
                 end)
        end

        Imp.Run.stop(run)
        next
      end)

    assert length(history.messages) == 12
    requests = Agent.get(state, & &1)
    assert Enum.any?(requests, &(length(&1) > 8))

    for [before, after_request] <- Enum.chunk_every(requests, 2, 1, :discard),
        length(before) > 8 do
      assert length(after_request) < length(before)
      assert byte_size(Jason.encode!(after_request)) < byte_size(Jason.encode!(before))
    end
  end

  test "unrelated structured HTTP errors are not context refusals" do
    url =
      Imp.Test.LocalHTTP.start(fn _ ->
        {400,
         %{
           "error" => %{
             "code" => "invalid_api_key",
             "message" => "context_length_exceeded mentioned in prose"
           }
         }}
      end)

    lm =
      Imp.req_llm(%{provider: :openai, id: "fixture", model: "fixture", base_url: url <> "/v1"},
        api_key: "fixture",
        cache: false,
        req_http_options: [retry: false, max_retries: 0]
      )

    assert {:error, error} =
             Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "test"}], [])

    refute match?(%Imp.ContextWindowExceededError{}, error)
  end

  test "current-call tool observations survive irreducible overflow without replay" do
    {:ok, counter} = Agent.start_link(fn -> %{calls: 0, effects: 0, sizes: []} end)

    lm = fn messages, _ ->
      n =
        Agent.get_and_update(counter, fn state ->
          {state.calls,
           %{state | calls: state.calls + 1, sizes: state.sizes ++ [length(messages)]}}
        end)

      if n == 0,
        do: {:ok, %{tool_calls: [%{id: "effect", name: "write", arguments: %{}}]}},
        else: {:error, %Imp.ContextWindowExceededError{message: "fixture overflow"}}
    end

    tool =
      Imp.tool(:write, "write", fn _ ->
        Agent.update(counter, &%{&1 | effects: &1.effects + 1})
        "observed-write"
      end)

    prior = Imp.history([%{intent: "earlier", answer: "old"}])

    {:ok, prediction} =
      Imp.call(Imp.react_v2("intent -> answer", [tool], lm: lm), %{intent: "now", history: prior})

    assert Imp.get(prediction, :answer) == nil
    assert Imp.get(prediction, :termination_reason) == :context_window_exceeded
    assert Agent.get(counter, & &1.effects) == 1
    assert length(Imp.get(prediction, :history).messages) == 2
    assert inspect(Imp.get(prediction, :history)) =~ "observed-write"
    assert Imp.get(prediction, :context_projection).omitted_prior_entries == 1
    assert Agent.get(counter, & &1.calls) == 3
  end

  test "whole prior groups are omitted together, including a trailing unfinished group" do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    lm = fn messages, _ ->
      n = Agent.get_and_update(requests, fn seen -> {length(seen), seen ++ [messages]} end)

      if n < 2,
        do: {:error, %Imp.ContextWindowExceededError{message: "limit"}},
        else:
          {:ok, %{tool_calls: [%{id: "done", name: "submit", arguments: %{answer: "continued"}}]}}
    end

    prior =
      Imp.history([
        %{
          intent: "first episode start",
          tool_calls: [%{id: "first", name: "read", args: %{}}],
          tool_call_results: [%{id: "first", result: "first observation"}]
        },
        %{answer: "first episode end"},
        %{
          intent: "unfinished episode",
          tool_calls: [%{id: "unfinished", name: "read", args: %{}}],
          tool_call_results: [%{id: "unfinished", result: "unfinished observation"}]
        }
      ])

    {:ok, prediction} =
      Imp.call(Imp.react_v2("intent -> answer", [], lm: lm), %{intent: "now", history: prior})

    assert Imp.get(prediction, :answer) == "continued"
    assert Enum.take(Imp.get(prediction, :history).messages, 3) == prior.messages
    [first, second, third] = Agent.get(requests, & &1)
    assert inspect(first) =~ "first observation"
    refute inspect(second) =~ "first observation"
    refute inspect(second) =~ "first episode"
    assert inspect(second) =~ "unfinished observation"
    refute inspect(third) =~ "unfinished"
    assert Imp.get(prediction, :context_projection).omitted_prior_entries == 3
  end

  test "a successful smaller retry preserves the current effect and never executes it again" do
    {:ok, state} = Agent.start_link(fn -> %{calls: 0, effects: 0} end)

    lm = fn messages, _ ->
      n = Agent.get_and_update(state, &{&1.calls, %{&1 | calls: &1.calls + 1}})

      case n do
        0 ->
          {:ok, %{tool_calls: [%{id: "effect", name: "write", arguments: %{}}]}}

        1 ->
          {:error, %Imp.ContextWindowExceededError{message: "limit"}}

        2 ->
          assert inspect(messages) =~ "current-observation"

          assert Enum.any?(messages, fn m ->
                   m.role == :user and String.contains?(m.content, "[[ ## intent ## ]]\ncurrent")
                 end)

          refute inspect(messages) =~ "prior-answer"
          {:ok, %{tool_calls: [%{id: "done", name: "submit", arguments: %{answer: "done"}}]}}
      end
    end

    tool =
      Imp.tool(:write, "fixture effect", fn _ ->
        Agent.update(state, &%{&1 | effects: &1.effects + 1})
        "current-observation"
      end)

    prior = Imp.history([%{intent: "prior", answer: "prior-answer"}])

    {:ok, prediction} =
      Imp.call(Imp.react_v2("intent -> answer", [tool], lm: lm), %{
        intent: "current",
        history: prior
      })

    assert Imp.get(prediction, :answer) == "done"
    assert length(Imp.get(prediction, :history).messages) == 3
    assert Agent.get(state, & &1.effects) == 1
  end

  test "an irreducible first request does not make an unchanged forced-submit request" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm = fn _, _ ->
      Agent.update(calls, &(&1 + 1))
      {:error, %Imp.ContextWindowExceededError{message: "instructions alone exceed window"}}
    end

    {:ok, prediction} = Imp.call(Imp.react_v2("intent -> answer", [], lm: lm), %{intent: "now"})
    assert Imp.get(prediction, :answer) == nil
    assert Imp.get(prediction, :termination_reason) == :context_window_exceeded
    assert Agent.get(calls, & &1) == 1
  end

  test "recovery is finite even when every reduced prompt is refused" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm = fn _, _ ->
      Agent.update(calls, &(&1 + 1))
      {:error, %Imp.ContextWindowExceededError{message: "fixed input too large"}}
    end

    prior = Imp.history(Enum.map(1..1024, &%{intent: "old #{&1}", answer: "old"}))

    {:ok, prediction} =
      Imp.call(Imp.react_v2("intent -> answer", [], lm: lm), %{intent: "now", history: prior})

    assert Imp.get(prediction, :history) == prior
    assert Imp.get(prediction, :context_projection).recovery_requests == 8
    assert Imp.get(prediction, :context_projection).omitted_prior_entries == 1024
    assert Agent.get(calls, & &1) == 9
  end

  test "non-context failure does not trigger adaptive history retries" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm = fn _, _ ->
      Agent.update(calls, &(&1 + 1))
      {:error, :unrelated_provider_failure}
    end

    prior = Imp.history([%{intent: "prior", answer: "old"}])

    {:ok, prediction} =
      Imp.call(Imp.react_v2("intent -> answer", [], lm: lm), %{intent: "now", history: prior})

    assert Imp.get(prediction, :history) == prior
    assert Imp.get(prediction, :context_projection) == nil
    # Existing forced-submit strategy remains; there are no history retries.
    assert Agent.get(calls, & &1) == 2
  end
end

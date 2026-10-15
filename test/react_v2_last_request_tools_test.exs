defmodule ReActV2LastRequestToolsTest do
  use ExUnit.Case, async: true

  # A program that acts through a tool (it posts, sends or records something)
  # and whose text only reports what it did names that tool in
  # `last_request_tools`. When its turn is interrupted, the last request may
  # still take that action: calls to the listed tools run as any step's calls
  # do, and the text is the answer. Calls to any other tool are not run.

  defp tools(owner) do
    [
      Imp.tool(:post, "Post a message", fn %{"text" => text} ->
        send(owner, {:posted, text})
        "posted"
      end),
      Imp.tool(:look, "Look at a thing", fn _arguments ->
        send(owner, :looked)
        "seen"
      end)
    ]
  end

  # The first request fails, as a provider error does; the last request
  # posts, looks, and reports.
  defp failing_then(owner, last) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn _messages, _opts ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(owner, {:request, n})
        if n == 1, do: raise(RuntimeError, "provider unavailable"), else: last
      end
    )
  end

  @last %{
    answer: "Posted the summary.",
    tool_calls: [
      %{id: "p1", name: "post", arguments: %{"text" => "summary"}},
      %{id: "l1", name: "look", arguments: %{}}
    ]
  }

  defp results(prediction) do
    for step <- Imp.History.messages(prediction.metadata.history),
        result <- Map.get(step, :tool_call_results, []),
        do: {result.id, result.result}
  end

  test "an interrupted turn's last request runs a listed tool and records its result" do
    owner = self()

    program =
      Imp.react("intent -> answer", tools(owner),
        lm: failing_then(owner, @last),
        last_request_tools: [:post]
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "summarise and post"})

    assert_received {:posted, "summary"}
    assert Imp.get(prediction, :answer) == "Posted the summary."
    assert prediction.metadata.termination_reason == :last_text
    assert prediction.metadata.termination_cause == :prediction_error
    assert results(prediction) == [{"p1", "posted"}]

    # The executed call is in the history with its result, so the turn
    # replays as it happened.
    last = prediction.metadata.history |> Imp.History.messages() |> List.last()
    assert [%{id: "p1", name: "post"}] = last.tool_calls.tool_calls
    assert last.answer == "Posted the summary."

    assert_received {:request, 2}
    refute_received {:request, 3}
  end

  test "an unlisted tool in the same request is not run and is listed as unexecuted" do
    owner = self()

    program =
      Imp.react("intent -> answer", tools(owner),
        lm: failing_then(owner, @last),
        last_request_tools: ["post"]
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "summarise and post"})

    refute_received :looked
    assert [%{id: "l1", name: "look"}] = prediction.metadata.unexecuted_tool_calls
    refute Enum.any?(results(prediction), fn {id, _result} -> id == "l1" end)
  end

  test "by default no tool runs in the last request" do
    owner = self()
    default = Imp.react("intent -> answer", tools(owner), lm: failing_then(owner, @last))
    assert default.last_request_tools == []

    explicit =
      Imp.react("intent -> answer", tools(owner),
        lm: failing_then(owner, @last),
        last_request_tools: []
      )

    for program <- [default, explicit] do
      assert {:ok, prediction} = Imp.call(program, %{intent: "summarise and post"})
      refute_received {:posted, _}
      refute_received :looked
      assert results(prediction) == []

      assert [%{id: "p1"}, %{id: "l1"}] = prediction.metadata.unexecuted_tool_calls
    end
  end

  test "a listed call goes through the tool policy and the run's authorization, with events" do
    owner = self()

    program =
      Imp.react("intent -> answer", tools(owner),
        lm: failing_then(owner, @last),
        last_request_tools: [:post],
        tool_policy: fn
          name, _arguments when name in [:post, "post"] -> {:deny, :not_today}
          _name, _arguments -> :allow
        end
      )

    assert {:ok, run} =
             Imp.start_run(program, %{intent: "summarise and post"},
               event_sink: fn event -> send(owner, {:event, event}) end
             )

    assert {:ok, prediction} = Task.await(run.task)
    :ok = Imp.Run.stop(run)

    refute_received {:posted, _}
    assert [{"p1", {:error, _refused}}] = results(prediction)

    events = collect_events([])

    assert Enum.any?(events, &(&1.kind == :tool_call and &1.tool_name == "post"))

    assert Enum.any?(
             events,
             &(&1.kind == :tool_result and &1.metadata[:outcome] == :refused)
           )

    authorized =
      Imp.react("intent -> answer", tools(owner),
        lm: failing_then(owner, @last),
        last_request_tools: [:post]
      )

    assert {:ok, run} =
             Imp.start_run(authorized, %{intent: "summarise and post"},
               authorize: fn _request -> {:deny, :held} end
             )

    assert {:ok, prediction} = Task.await(run.task)
    :ok = Imp.Run.stop(run)

    refute_received {:posted, _}
    assert [{"p1", {:error, {:tool_denied, :post, :held}}}] = results(prediction)
  end

  test "a finish_on hook a listed call meets may end the turn with its outputs" do
    owner = self()

    program =
      Imp.react("intent -> answer", tools(owner),
        lm: failing_then(owner, @last),
        last_request_tools: [:post],
        finish_on: %{
          post: fn %{"text" => text}, _result, _inputs -> {:finish, %{answer: text}} end
        }
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "summarise and post"})
    assert Imp.get(prediction, :answer) == "summary"
    assert prediction.metadata.termination_reason == :finished_by_tool
    assert prediction.metadata.finished_by_tool == "post"
    assert prediction.metadata.termination_cause == :prediction_error
  end

  test "the names must be tools the program holds, for a signature with a text answer" do
    assert_raise ArgumentError, ~r/names no tool: send/, fn ->
      Imp.react("intent -> answer", tools(self()), last_request_tools: [:send])
    end

    assert_raise ArgumentError, ~r/one unconstrained text output/, fn ->
      Imp.react("intent -> answer, confidence: float", tools(self()), last_request_tools: [:post])
    end
  end

  test "saving and loading carry the list, and an older file loads with none" do
    runner = fn _arguments -> "ok" end
    registry = Imp.Saving.Registry.new(post_runner: runner)
    tool = Imp.tool(:post, "Post a message", runner)

    dumped =
      Imp.react("intent -> answer", [tool], last_request_tools: [:post])
      |> Imp.dump(registry: registry)

    assert dumped["last_request_tools"] == ["post"]
    assert Imp.load!(dumped, registry: registry).last_request_tools == ["post"]

    older = Map.delete(dumped, "last_request_tools")
    assert Imp.load!(older, registry: registry).last_request_tools == []
  end

  defp collect_events(acc) do
    receive do
      {:event, event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

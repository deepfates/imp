defmodule ReActV2LastProseTest do
  use ExUnit.Case, async: true

  # `on_max_iters: :last_prose` ends a turn that reaches the step limit with one
  # request that carries no tools, so the only thing the model can do is speak.
  # What it says is the single text output; what it does not say is an empty
  # answer, not an error.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> %{"seen" => true} end)

  defp recording_lm(owner, last) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages, opts})

        if Keyword.has_key?(opts, :tools) do
          %{
            next_thought: "look first",
            tool_calls: [%{id: "c#{n}", name: "look", arguments: %{}}]
          }
        else
          last
        end
      end
    )
  end

  defp requests(n), do: for(i <- 1..n, do: receive(do: ({:request, ^i, m, o} -> {m, o})))

  defp user_contents(messages),
    do: messages |> Enum.filter(&(&1[:role] == :user)) |> Enum.map(& &1[:content])

  test "the step limit spends one request with no tools and takes its prose as the answer" do
    owner = self()
    prose = "Two looks were enough: the thing is there."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, prose),
        max_iters: 2,
        on_max_iters: :last_prose
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == prose
    assert Imp.get(prediction, :termination_reason) == :last_prose

    [{_first, first_opts}, {_second, _}, {last, last_opts}] = requests(3)
    refute_received {:request, 4, _messages, _opts}

    assert Keyword.fetch!(first_opts, :tool_choice) == "auto"
    refute Keyword.has_key?(last_opts, :tools)
    refute Keyword.has_key?(last_opts, :tool_choice)

    # Nothing was said on the model's behalf: the last request is the second
    # request plus that step's exchange.
    refute Enum.any?(user_contents(last), &(&1 =~ "step"))

    # The prose is this turn's history event, as an answered step's is.
    messages = prediction |> Imp.get(:history) |> Imp.History.messages()
    assert Enum.any?(messages, &(Map.get(&1, :next_thought) == prose))
  end

  test "the note is the last user message of that request and reaches the history" do
    owner = self()
    note = "You have used every step. Answer now, in your own words."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, "The thing is there."),
        max_iters: 1,
        on_max_iters: :last_prose,
        last_prose_note: note
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "The thing is there."

    [_first, {last, _}] = requests(2)
    assert List.last(user_contents(last)) =~ note

    history = Imp.get(prediction, :history)
    assert Enum.any?(Imp.History.messages(history), &(Map.get(&1, :intent) == note))
  end

  test "no note leaves the last request carrying only the run so far" do
    owner = self()

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, "The thing is there."),
        max_iters: 1,
        on_max_iters: :last_prose
      )

    assert {:ok, _prediction} = Imp.call(program, %{intent: "hello"})
    [{first, _}, {last, _}] = requests(2)

    # Only the first step's exchange separates the two requests: assistant tool
    # call and tool result.
    assert length(last) == length(first) + 2
  end

  test "a last request that says nothing is an empty answer, not an error" do
    owner = self()

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, ""),
        max_iters: 1,
        on_max_iters: :last_prose
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == nil
    assert Imp.get(prediction, :termination_reason) == :last_prose
    refute Imp.get(prediction, :termination_error)
  end

  test "the last request and its completion are recorded as events" do
    owner = self()
    prose = "The thing is there."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, prose),
        max_iters: 1,
        on_max_iters: :last_prose
      )

    assert {:ok, run} =
             Imp.start_run(program, %{intent: "hello"},
               event_sink: fn event -> send(owner, {:run_event, event}) end
             )

    assert {:ok, prediction} = Task.await(run.task)
    assert Imp.get(prediction, :answer) == prose
    :ok = Imp.Run.stop(run)

    kinds = run_event_kinds([])
    assert Enum.count(kinds, &(&1 == :model_request)) == 2
    assert Enum.count(kinds, &(&1 == :model_response)) == 2
    assert Enum.count(kinds, &(&1 == :final)) == 1
  end

  defp run_event_kinds(kinds) do
    receive do
      {:run_event, event} -> run_event_kinds([event.kind | kinds])
    after
      0 -> Enum.reverse(kinds)
    end
  end

  test "a signature that is not one text output refuses the option" do
    assert_raise ArgumentError, ~r/exactly one output of type :string/, fn ->
      Imp.react_v2("intent -> answer, confidence: float", [look()], on_max_iters: :last_prose)
    end
  end

  test "the default still forces a submit at the step limit" do
    owner = self()

    program =
      Imp.react_v2("intent -> answer", [look()], lm: recording_lm(owner, ""), max_iters: 1)

    assert {:ok, _prediction} = Imp.call(program, %{intent: "hello"})
    [_first, {_forced, forced_opts}] = requests(2)
    assert forced_opts[:tool_choice] == %{type: "tool", name: "submit"}
  end

  test "dump and load round-trip the options, and an older dump forces a submit" do
    runner = fn _arguments -> %{"seen" => true} end
    registry = Imp.Saving.Registry.new(look_runner: runner)
    tool = Imp.tool(:look, "Look at a thing", runner)

    dumped =
      Imp.react_v2("intent -> answer", [tool],
        on_max_iters: :last_prose,
        last_prose_note: "Answer now."
      )
      |> Imp.dump(registry: registry)

    assert dumped["on_max_iters"] == "last_prose"
    assert dumped["last_prose_note"] == "Answer now."

    loaded = Imp.load(dumped, registry: registry)
    assert loaded.on_max_iters == :last_prose
    assert loaded.last_prose_note == "Answer now."

    older =
      Imp.load(Map.drop(dumped, ["on_max_iters", "last_prose_note"]), registry: registry)

    assert older.on_max_iters == :forced_submit
    assert older.last_prose_note == nil
  end
end

defmodule ReActV2SubmitEndingTest do
  use ExUnit.Case, async: true

  # How a ReActV2 turn ends, for every signature, as in DSPy's ReActV2: the
  # model calls `submit`. A step that calls no tool is a thought. It stays in
  # the history as the step it was, and one forced `submit` request follows:
  # the same request with the thought appended and `tool_choice` naming
  # `submit`, and nothing else added. A forced request that still gets no
  # `submit` leaves the turn without an answer, unless the program asks for the
  # extractor. `finish: :text` keeps the plain-text ending.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> %{"seen" => true} end)

  # Answers request n with `Enum.at(replies, n - 1)`, and tells the test about
  # each request.
  defp lm(replies) do
    owner = self()
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(owner, {:request, n, messages, opts})
        Enum.at(replies, n - 1) || flunk("unexpected request #{n}")
      end
    )
  end

  defp requests(acc \\ []) do
    receive do
      {:request, _n, messages, opts} -> requests([{messages, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp submit(arguments), do: %{tool_calls: [%{id: "s1", name: "submit", arguments: arguments}]}

  @thought "It is a cat. I will say so."

  test "a text step is a thought, kept in the history, and the forced submit is the same request plus tool_choice" do
    program =
      Imp.react("intent -> answer", [look()], lm: lm([@thought, submit(%{answer: "A cat."})]))

    assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
    assert Imp.get(prediction, :answer) == "A cat."
    assert Imp.Prediction.complete?(prediction)
    assert prediction.metadata.termination_reason == :forced_submit
    assert prediction.metadata.termination_cause == :empty_tool_calls

    [{step_messages, step_opts}, {forced_messages, forced_opts}] = requests()

    # The forced request's messages are the step's, then the thought as the
    # assistant's reply; no user message follows it.
    assert Enum.take(forced_messages, length(step_messages)) == step_messages

    assert [%{role: :assistant, content: content}] =
             Enum.drop(forced_messages, length(step_messages))

    assert content =~ @thought

    # Its options are the step's, with `tool_choice` naming `submit` and
    # reasoning effort unset, as DSPy's `_forced_submit` sends.
    assert step_opts[:tool_choice] == "auto"
    assert forced_opts[:tool_choice] == %{type: "tool", name: "submit"}
    assert Keyword.has_key?(forced_opts, :reasoning_effort)
    assert forced_opts[:reasoning_effort] == nil

    assert Keyword.drop(forced_opts, [:tool_choice, :reasoning_effort]) ==
             Keyword.drop(step_opts, [:tool_choice, :reasoning_effort])

    assert Enum.map(forced_opts[:tools], & &1.function.name) == ["look", "submit"]

    # The history records the thought as its own step, then the submit.
    assert %Imp.History{messages: [thought_step, submit_step]} = prediction.metadata.history
    assert thought_step.next_thought == @thought
    assert thought_step.tool_calls.tool_calls == []
    assert [%{name: "submit"}] = submit_step.tool_calls.tool_calls
  end

  test "a host's last_request_note is not added when the model ended its turn" do
    program =
      Imp.react("intent -> answer", [look()],
        lm: lm([@thought, submit(%{answer: "A cat."})]),
        last_request_note: "Answer now."
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
    assert Imp.get(prediction, :answer) == "A cat."
    [{step_messages, _}, {forced_messages, _}] = requests()
    assert length(forced_messages) == length(step_messages) + 1
    refute Enum.any?(forced_messages, &(to_string(&1.content) =~ "Answer now."))
  end

  test "an interrupted turn's forced submit carries the note as a user message" do
    look_call = %{tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}

    program =
      Imp.react("intent -> answer", [look()],
        lm: lm([look_call, submit(%{answer: "A cat."})]),
        max_iters: 1,
        last_request_note: "Answer now."
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
    assert prediction.metadata.termination_reason == :forced_submit
    assert prediction.metadata.termination_cause == :max_iters
    [_step, {forced_messages, _}] = requests()
    assert %{role: :user, content: content} = List.last(forced_messages)
    assert to_string(content) =~ "Answer now."
  end

  test "an ignored forced submit leaves the turn incomplete, with no extractor request" do
    program = Imp.react("intent -> answer", [look()], lm: lm([@thought, "Still just text."]))

    assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
    refute Imp.Prediction.complete?(prediction)
    assert prediction.fields == %{}
    assert prediction.metadata.termination_reason == :incomplete
    assert prediction.metadata.termination_cause == :empty_tool_calls
    assert prediction.metadata.termination_error.forced_submit == :no_submit_call

    # Two requests: the step and the forced submit. No extractor.
    assert length(requests()) == 2

    # Both replies are in the history the caller holds.
    assert %Imp.History{messages: [first, second]} = prediction.metadata.history
    assert first.next_thought == @thought
    assert second.next_thought == "Still just text."
  end

  test "on_ignored_submit: :extract asks the extractor after an ignored forced submit" do
    program =
      Imp.react("intent -> answer", [look()],
        lm:
          lm([
            @thought,
            "Still just text.",
            "[[ ## reasoning ## ]]\nIt said so.\n\n[[ ## answer ## ]]\nA cat.\n\n[[ ## completed ## ]]"
          ]),
        on_ignored_submit: :extract
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
    assert Imp.get(prediction, :answer) == "A cat."
    assert prediction.metadata.termination_reason == :extracted
    assert prediction.metadata.termination_cause == :empty_tool_calls

    [_step, _forced, {_extraction_messages, extraction_opts}] = requests()
    assert extraction_opts[:tools] in [nil, []]
    assert extraction_opts[:tool_choice] == nil
  end

  test "an empty string is a valid answer" do
    program = Imp.react("intent -> answer", [look()], lm: lm([submit(%{answer: ""})]))

    assert {:ok, prediction} = Imp.call(program, %{intent: "say nothing"})
    assert Imp.Prediction.complete?(prediction)
    assert prediction.metadata.termination_reason == :submit
    assert Imp.get(prediction, :answer) == ""
    assert length(requests()) == 1
  end

  test "finish_on ends the turn as it did" do
    reply = Imp.tool(:reply, "Reply", fn %{"text" => text} -> "sent: #{text}" end)

    program =
      Imp.react("intent -> answer", [reply],
        lm: lm([%{tool_calls: [%{id: "r1", name: "reply", arguments: %{text: "hi"}}]}]),
        finish_on: %{
          reply: fn %{"text" => text}, _result, _inputs -> {:finish, %{answer: text}} end
        }
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "greet"})
    assert Imp.get(prediction, :answer) == "hi"
    assert prediction.metadata.termination_reason == :finished_by_tool
    assert prediction.metadata.finished_by_tool == "reply"
    assert length(requests()) == 1
  end

  describe "finish: :text" do
    test "a step that calls no tool is the answer, in one request, with no submit" do
      program = Imp.react("intent -> answer", [look()], finish: :text, lm: lm(["A cat."]))
      refute Map.has_key?(program.tools, :submit)

      assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
      assert Imp.get(prediction, :answer) == "A cat."
      assert prediction.metadata.termination_reason == :answered
      [{_messages, opts}] = requests()
      assert Enum.map(opts[:tools], & &1.function.name) == ["look"]
    end

    test "needs one output, a string with no constraints" do
      enum =
        Imp.signature(%{
          inputs: [:intent],
          outputs: [%{name: :answer, constraints: %{enum: ["yes", "no"]}}]
        })

      for signature <- ["intent -> answer, confidence: float", "intent -> n: int", enum] do
        assert_raise ArgumentError, ~r/finish: :text needs exactly one output/, fn ->
          Imp.react(signature, [look()], finish: :text)
        end
      end
    end
  end

  test "dump and load keep both choices, and a file without them loads the defaults" do
    runner = fn _arguments -> %{"seen" => true} end
    registry = Imp.Saving.Registry.new(look_runner: runner)
    tool = Imp.tool(:look, "Look at a thing", runner)

    dumped =
      Imp.react("intent -> answer", [tool], finish: :text, on_ignored_submit: :extract)
      |> Imp.dump(registry: registry)
      |> Jason.encode!()
      |> Jason.decode!()

    assert dumped["finish"] == "text"
    assert dumped["on_ignored_submit"] == "extract"
    loaded = Imp.load!(dumped, registry: registry)
    assert loaded.finish == :text
    assert loaded.on_ignored_submit == :extract
    refute Map.has_key?(loaded.tools, :submit)

    older = Imp.load!(Map.drop(dumped, ["finish", "on_ignored_submit"]), registry: registry)
    assert older.finish == :submit
    assert older.on_ignored_submit == :incomplete
    assert Map.has_key?(older.tools, :submit)
    assert older.react.adapter_opts[:guidance].submit_tool == :submit
  end
end

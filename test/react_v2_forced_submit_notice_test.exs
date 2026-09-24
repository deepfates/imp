defmodule ReActV2ForcedSubmitNoticeTest do
  use ExUnit.Case, async: true

  # The forced submit belongs to a signature with `submit`: more than one
  # output, or one that is not text.
  @signature "intent -> answer, confidence: float"

  # The forced submit re-asks the model with `tool_choice: submit` and says
  # nothing about why. A host that wants the model told why it is being made to
  # finish sets `:forced_submit_notice`; the notice is a user message in the
  # forced request and stays in the returned history, because the record of the
  # run has to contain what the model was told.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => true} end)

  defp recording_lm(owner) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages, opts})

        if forced?(opts) do
          %{tool_calls: [%{id: "s", name: "submit", arguments: %{answer: "ok", confidence: 1.0}}]}
        else
          %{
            next_thought: "look first",
            tool_calls: [%{id: "c", name: "look", arguments: %{}}]
          }
        end
      end
    )
  end

  defp forced?(opts), do: opts[:tool_choice] not in [nil, "auto"]

  defp requests(n), do: for(i <- 1..n, do: receive(do: ({:request, ^i, m, o} -> {m, o})))

  defp user_contents(messages),
    do: messages |> Enum.filter(&(&1[:role] == :user)) |> Enum.map(& &1[:content])

  test "the notice is the last user message of the forced request and reaches the history" do
    owner = self()
    notice = "You have used every turn. Submit the answer you have now."

    program =
      Imp.react_v2(@signature, [look()],
        lm: recording_lm(owner),
        max_iters: 1,
        forced_submit_notice: fn reason ->
          send(owner, {:notice_asked, reason})
          notice
        end
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "ok"
    assert_receive {:notice_asked, :max_iters}

    [{_first, _}, {forced, forced_opts}] = requests(2)
    assert forced_opts[:tool_choice] == %{type: "tool", name: "submit"}

    assert List.last(user_contents(forced)) =~ notice

    history = Imp.get(prediction, :history)
    assert Enum.any?(Imp.History.messages(history), &(Map.get(&1, :intent) == notice))
  end

  test "the notice is a plain string too, and an empty trailing request is still omitted" do
    owner = self()

    program =
      Imp.react_v2(@signature, [look()],
        lm: recording_lm(owner),
        max_iters: 1,
        forced_submit_notice: "Submit now."
      )

    assert {:ok, _prediction} = Imp.call(program, %{intent: "hello"})
    [_first, {forced, _}] = requests(2)

    assert List.last(user_contents(forced)) =~ "Submit now."
    # omit_empty_request: the forced request carries no new pending inputs, so
    # there is no blank user message after the notice turn.
    refute Enum.any?(forced, &(&1[:role] == :user and String.trim(&1[:content] || "") == ""))
  end

  test "no notice leaves the forced request exactly as it was" do
    owner = self()

    program =
      Imp.react_v2(@signature, [look()], lm: recording_lm(owner), max_iters: 1)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    [{first, _}, {forced, _}] = requests(2)

    # Only the first step's exchange separates the two requests: user inputs,
    # assistant tool call, tool result. Nothing was added on the model's behalf.
    assert length(forced) == length(first) + 2
    assert Enum.count(Imp.History.messages(Imp.get(prediction, :history))) == 2
  end

  test "a notice function returning nil is a no-op" do
    owner = self()

    program =
      Imp.react_v2(@signature, [look()],
        lm: recording_lm(owner),
        max_iters: 1,
        forced_submit_notice: fn _reason -> nil end
      )

    assert {:ok, _} = Imp.call(program, %{intent: "hello"})
    [{first, _}, {forced, _}] = requests(2)
    assert length(forced) == length(first) + 2
  end

  test "the option rejects anything that is not a string or a 1-arity function" do
    assert_raise ArgumentError, ~r/forced_submit_notice/, fn ->
      Imp.react_v2(@signature, [look()], forced_submit_notice: fn -> "no" end)
    end

    assert_raise ArgumentError, ~r/forced_submit_notice/, fn ->
      Imp.react_v2(@signature, [look()], forced_submit_notice: 7)
    end
  end
end

defmodule HistoryVerbatimTest do
  use ExUnit.Case, async: true

  # A tool loop's history is what the model reads on its next step, and what a
  # host stores to continue the conversation later. It holds the inputs and tool
  # results exactly as they were; redaction belongs to traces, telemetry and
  # logs. Text that only looks like a credential (a post quoting a curl command,
  # a thread about auth headers) used to reach the model as "[REDACTED]".

  @quoted "Try: curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln' https://example.test\nWhat do you think?"

  setup do
    # The test's own premise: this text is one the redactor replaces whole.
    assert Imp.Redaction.redact(@quoted) == "[REDACTED]"
    :ok
  end

  defp read_thread, do: Imp.tool(:read_thread, "Read the thread", fn _ -> @quoted end)

  defp recording_lm(owner, steps, reply) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages})
        if n < steps, do: reply.(n), else: "ok"
      end
    )
  end

  defp request(n), do: receive(do: ({:request, ^n, messages} -> messages))

  defp contents(messages), do: Enum.map(messages, &to_string(&1[:content]))

  test "ReActV2: later steps and the returned history keep inputs and tool results as read" do
    lm =
      recording_lm(self(), 2, fn n ->
        %{answer: "", tool_calls: [%{id: "c#{n}", name: "read_thread", arguments: %{}}]}
      end)

    program = Imp.react("thread -> answer", [read_thread()], lm: lm)
    assert {:ok, prediction} = Imp.call(program, %{thread: @quoted})

    _first = request(1)
    second = contents(request(2))

    assert Enum.any?(second, &(&1 =~ @quoted and &1 =~ "[[ ## thread ## ]]"))
    assert @quoted in second
    refute Enum.any?(second, &(&1 =~ "[REDACTED]"))

    history = prediction.metadata.history |> Imp.History.dump() |> Jason.encode!()
    refute history =~ "[REDACTED]"
    assert history =~ Jason.encode!(@quoted)
  end

  test "ReAct: the next step reads the tool result as the tool returned it" do
    lm =
      recording_lm(self(), 3, fn
        1 -> %{next_thought: "read it", tool_calls: [%{name: "read_thread", arguments: %{}}]}
        _ -> %{next_thought: "done", tool_calls: [%{name: "submit", arguments: %{answer: "ok"}}]}
      end)

    program = Imp.Predict.ReAct.new("thread -> answer", [read_thread()], lm: lm)
    assert {:ok, _prediction} = Imp.call(program, %{thread: "the thread"})

    _first = request(1)
    second = request(2) |> contents() |> Enum.join("\n")

    # The history field renders the result as JSON text.
    assert second =~ String.replace(@quoted, "\n", "\\n")
    refute second =~ "[REDACTED]"
  end

  test "Avatar: the next action reads the observation, and the actions keep it" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          cond do
            prompt =~ "Do not request another tool." ->
              %{answer: "ok"}

            prompt =~ "tool_output" ->
              send(owner, {:observed, prompt})
              %{action: %{tool_name: "Finish", tool_input_query: %{}}}

            true ->
              %{action: %{tool_name: "read_thread", tool_input_query: %{}}}
          end
        end
      )

    avatar = Imp.avatar("thread -> answer", [read_thread()], lm: lm, max_iters: 3)
    assert {:ok, prediction} = Imp.call(avatar, %{thread: "the thread"})

    assert_received {:observed, prompt}
    refute prompt =~ "[REDACTED]"
    assert [%{tool_output: @quoted}] = Imp.get(prediction, :actions)
  end
end

defmodule ReActV2CallConfigTest do
  use ExUnit.Case, async: true

  # A call can give its own request options, as it can its own `max_iters` and
  # `last_request_note`, and a text answer says why the provider stopped it:
  # together a host can make one request on a conversation it holds, with an
  # output budget of its own, and tell a whole answer from one the budget cut.

  @signature "question -> answer"

  defp lm(owner, reply) do
    Imp.LM.Static.new(
      handler: fn _messages, opts ->
        send(owner, {:request, opts})
        reply
      end
    )
  end

  # Where a provider-backed client reports the finish reason: the result's
  # provider metadata, as `Imp.Clients.ReqLLM` hands it back.
  defp stopped(text, reason),
    do: %{__imp_lm_output__: text, __imp_lm_metadata__: %{req_llm: %{finish_reason: reason}}}

  test "a call's own config is sent over the program's for that call only" do
    program =
      Imp.react(@signature, [],
        lm: lm(self(), "fine"),
        config: [max_tokens: 600, temperature: 0.2]
      )

    assert {:ok, _} = Imp.call(program, %{question: "hi", config: [max_tokens: 32]})
    assert_received {:request, opts}
    assert opts[:max_tokens] == 32
    assert opts[:temperature] == 0.2

    assert {:ok, _} = Imp.call(program, %{question: "hi"})
    assert_received {:request, opts}
    assert opts[:max_tokens] == 600

    # The loop chooses the tools and tool_choice on each step.
    assert {:error, {:invalid_react_v2_config, [tool_choice: "none"]}} =
             Imp.call(program, %{question: "hi", config: [tool_choice: "none"]})

    refute_received {:request, _}
  end

  test "a text answer carries the finish reason of the reply it came from" do
    program = Imp.react(@signature, [], lm: lm(self(), stopped("We spoke of kites and", :length)))

    assert {:ok, answered} = Imp.call(program, %{question: "hi"})
    assert answered.metadata.termination_reason == :answered
    assert answered.metadata.finish_reason == :length

    # The last request on a history the caller holds: one request, no tool runs.
    assert {:ok, last} =
             Imp.call(program, %{
               question: "hi",
               history: answered.metadata.history,
               max_iters: 0,
               last_request_note: "Summarise this conversation."
             })

    assert last.metadata.termination_reason == :last_text
    assert last.metadata.finish_reason == :length
    assert Imp.get(last, :answer) == "We spoke of kites and"

    whole = Imp.react(@signature, [], lm: lm(self(), stopped("We spoke of kites.", :stop)))
    assert {:ok, prediction} = Imp.call(whole, %{question: "hi"})
    assert prediction.metadata.finish_reason == :stop
  end
end

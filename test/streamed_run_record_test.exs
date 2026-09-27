defmodule Imp.StreamedRunRecordTest do
  use ExUnit.Case, async: true

  # Streaming changes how the answer arrives, not what the run records: a
  # program streamed from its provider leaves the same model events, with its
  # purpose and the usage the provider reported, as the same program called
  # plainly.

  defmodule BothWaysStub do
    @usage %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
    @answer "[[ ## reasoning ## ]]\nBecause.\n\n[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"

    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:sent, :generate, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp_plain",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(@answer),
         usage: @usage
       }}
    end

    def stream_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:sent, :stream, opts})

      {:ok,
       %ReqLLM.StreamResponse{
         stream: [
           ReqLLM.StreamChunk.text(String.slice(@answer, 0, 20)),
           ReqLLM.StreamChunk.text(String.slice(@answer, 20..-1//1)),
           ReqLLM.StreamChunk.meta(%{usage: @usage, finish_reason: "stop"})
         ],
         metadata_handle: self(),
         cancel: fn -> :ok end,
         model: model,
         context: ReqLLM.Context.new(messages)
       }}
    end
  end

  defmodule Collecting do
    @behaviour Imp.Module
    defstruct [:program, :provider_stream]

    @impl true
    def call(%__MODULE__{program: program, provider_stream: provider_stream}, inputs),
      do: Imp.collect(program, inputs, provider_stream: provider_stream)
  end

  defp run_events(provider_stream) do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: BothWaysStub, cache: false)

    program = Imp.predict("question -> reasoning, answer", lm: lm, config: [purpose: :voice])

    {:ok, run} =
      Imp.Run.start(%Collecting{program: program, provider_stream: provider_stream}, %{
        question: "Capital of France?"
      })

    assert {:ok, prediction} = Task.await(run.task)
    assert Imp.get(prediction, :answer) == "Paris"
    events = Imp.Run.events(run)
    Imp.Run.stop(run)
    events
  end

  test "a streamed call records the same model events as a plain one" do
    plain = run_events(false)
    assert_received {:sent, :generate, plain_opts}
    streamed = run_events(true)
    assert_received {:sent, :stream, streamed_opts}

    assert Enum.map(streamed, & &1.kind) == Enum.map(plain, & &1.kind)
    assert :model_request in Enum.map(streamed, & &1.kind)

    for events <- [plain, streamed] do
      assert [request] = Enum.filter(events, &(&1.kind == :model_request))
      assert [response] = Enum.filter(events, &(&1.kind == :model_response))
      assert request.metadata.purpose == :voice
      assert request.metadata.model_call_id == response.metadata.model_call_id
    end

    usage = fn events ->
      Enum.find(events, &(&1.kind == :model_response)).metadata.usage
    end

    assert %{input_tokens: 3, output_tokens: 2, total_tokens: 5} = usage.(streamed)
    assert usage.(streamed) == usage.(plain)

    # The purpose is the record's; neither path sends it.
    refute Keyword.has_key?(plain_opts, :purpose)
    refute Keyword.has_key?(streamed_opts, :purpose)
  end

  # One scripted completion per request, the same whether it is asked for
  # whole or streamed: `generate/3` returns the output, and `stream/3` yields
  # it the way ReqLLM does, text as it arrives and each native tool call as
  # its own chunk.
  defmodule ScriptedLM do
    alias Imp.Streaming.Messages.StreamResponse

    defstruct [:turns]

    def new(turns) do
      {:ok, agent} = Agent.start_link(fn -> turns end)
      %__MODULE__{turns: agent}
    end

    def generate(lm, _messages, _opts) do
      case next(lm) do
        {:raise, error} -> raise error
        {text, []} -> {:ok, text}
        {text, calls} -> {:ok, %{next_thought: text, tool_calls: calls}}
      end
    end

    def stream(lm, _messages, _opts) do
      case next(lm) do
        {:raise, error} ->
          raise error

        {text, calls} ->
          [%StreamResponse{chunk: text}] ++
            Enum.map(calls, &%StreamResponse{chunk: %{tool_calls: [&1]}}) ++
            [%StreamResponse{chunk: nil, done: true}]
      end
    end

    defp next(%__MODULE__{turns: agent}),
      do: Agent.get_and_update(agent, fn [turn | rest] -> {turn, rest} end)
  end

  defp run(program, provider_stream) do
    {:ok, run} =
      Imp.Run.start(%Collecting{program: program, provider_stream: provider_stream}, %{
        question: "Capital of France?"
      })

    result = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)
    {result, events}
  end

  # A client that fails before it returns a stream (ReqLLM validates its
  # options first) fails the way a client that fails in `generate/3` does.
  test "a stream/3 that raises is recorded and fails as a raising generate/3 does" do
    runs =
      for provider_stream <- [false, true] do
        lm = ScriptedLM.new([{:raise, ArgumentError.exception("bad opts")}])
        run(Imp.predict("question -> answer", lm: lm), provider_stream)
      end

    [{plain, plain_events}, {streamed, streamed_events}] = runs

    assert {:error, {:lm_failed, ScriptedLM, %ArgumentError{message: "bad opts"}}} = streamed
    assert streamed == plain
    assert Enum.map(streamed_events, & &1.kind) == Enum.map(plain_events, & &1.kind)
    assert [%{error: _error}] = Enum.filter(streamed_events, &(&1.kind == :model_response))
  end

  defp look(name),
    do: Imp.tool(name, "look up #{name}", fn _arguments -> "#{name} says Paris" end)

  defp calls(names),
    do: Enum.map(names, &%{id: "call_#{&1}", name: to_string(&1), arguments: %{}})

  defp tool_calls(events),
    do: events |> Enum.filter(&(&1.kind == :tool_call)) |> Enum.map(& &1.metadata)

  # A streamed turn that says something and calls tools runs every call, in
  # order, and keeps what it said, as the same turn unstreamed does.
  for names <- [[:atlas], [:atlas, :gazetteer]] do
    test "a streamed turn with text and #{length(names)} tool call(s) matches the unstreamed turn" do
      names = unquote(names)

      runs =
        for provider_stream <- [false, true] do
          lm = ScriptedLM.new([{"Let me look.", calls(names)}, {"Paris", []}])

          program =
            Imp.react("question -> answer", Enum.map(names, &look/1), lm: lm, max_iters: 3)

          run(program, provider_stream)
        end

      [{{:ok, plain}, plain_events}, {{:ok, streamed}, streamed_events}] = runs

      assert Imp.get(streamed, :answer) == "Paris"
      assert streamed.fields == plain.fields
      assert Enum.map(streamed_events, & &1.kind) == Enum.map(plain_events, & &1.kind)
      assert length(tool_calls(streamed_events)) == length(names)
      assert tool_calls(streamed_events) == tool_calls(plain_events)

      trajectory = fn prediction ->
        prediction.metadata |> Map.get(:trajectory, prediction.metadata) |> inspect()
      end

      assert trajectory.(streamed) =~ "Let me look."
      assert trajectory.(streamed) == trajectory.(plain)
    end
  end
end

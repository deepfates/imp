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
end

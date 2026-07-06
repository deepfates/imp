defmodule ReqLLMClientTest do
  use ExUnit.Case

  defmodule TextStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_generate, model, messages, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp_1",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(~s({"answer":"pong","score":7})),
         object: nil
       }}
    end

    def stream_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_stream, model, messages, opts})

      {:ok,
       %ReqLLM.StreamResponse{
         stream: [
           ReqLLM.StreamChunk.text("po"),
           ReqLLM.StreamChunk.text("ng"),
           ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
         ],
         metadata_handle: self(),
         cancel: fn -> :ok end,
         model: model,
         context: ReqLLM.Context.new(messages)
       }}
    end
  end

  defmodule ObjectStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_generate, model, messages, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp_2",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(""),
         object: %{"answer" => "pong", "score" => 7}
       }}
    end
  end

  defmodule ToolStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_generate, model, messages, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp_3",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message:
           ReqLLM.Context.assistant("",
             tool_calls: [ReqLLM.ToolCall.new("call_1", "lookup", ~s({"query":"beam"}))]
           ),
         object: nil,
         finish_reason: :tool_calls
       }}
    end
  end

  test "ReqLLM client drives DSEx prediction and translates JSON/schema options" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: ObjectStub)

    program =
      DSEx.predict("question -> answer, score: int",
        lm: lm,
        adapter: DSEx.Adapter.JSON,
        config: [temperature: 0, timeout: 1_000, native_json_schema: true]
      )

    assert {:ok, prediction} =
             DSEx.Predict.Predict.call(program, %{question: "reply with pong and score 7"})

    assert DSEx.Prediction.get(prediction, :answer) == "pong"
    assert DSEx.Prediction.get(prediction, :score) == 7

    assert_received {:req_llm_generate, "openai:gpt-test", messages, opts}

    assert [
             %ReqLLM.Message{role: :system},
             %ReqLLM.Message{role: :system},
             %ReqLLM.Message{role: :user}
           ] = messages

    assert Keyword.fetch!(opts, :receive_timeout) == 1_000
    assert Keyword.fetch!(opts, :temperature) == 0.0
    assert get_in(opts, [:provider_options, :response_format, :type]) == "json_schema"
  end

  test "ReqLLM text responses still work with DSEx adapters" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)
    program = DSEx.predict("question -> answer, score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, prediction} = DSEx.call(program, %{question: "pong?"})
    assert DSEx.Prediction.get(prediction, :answer) == "pong"
    assert DSEx.Prediction.get(prediction, :score) == 7
  end

  test "ReqLLM tool calls return DSEx ReAct-compatible tool call payloads" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: ToolStub)

    tool =
      DSEx.Tool.new(:lookup, "Lookup a fact.", fn %{query: "beam"} -> "ok" end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    program = DSEx.react_v2("question -> answer", [tool], lm: lm, max_iters: 1)

    assert {:error, {:react_v2_max_iters, history}} =
             DSEx.Predict.ReActV2.call(program, %{question: "lookup beam"})

    assert [%{tool: :lookup, arguments: %{query: "beam"}, result: "ok"}] = history

    assert_received {:req_llm_generate, "openai:gpt-test", _messages, opts}

    assert [%ReqLLM.Tool{name: "lookup"}, %ReqLLM.Tool{name: "submit"}] =
             Keyword.fetch!(opts, :tools)
  end

  test "ReqLLM stream chunks are exposed through DSEx streaming vocabulary" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)
    program = DSEx.predict("question -> answer", lm: lm)

    chunks =
      program
      |> DSEx.Streaming.stream(%{question: "pong"}, provider_stream: true)
      |> Enum.to_list()

    assert Enum.map(chunks, & &1.chunk) |> Enum.reject(&is_nil/1) == ["po", "ng"]
    assert Enum.any?(chunks, & &1.done)

    assert_received {:req_llm_stream, "openai:gpt-test",
                     [%ReqLLM.Message{role: :system}, %ReqLLM.Message{role: :user}], _opts}
  end

  test "save/load preserves ReqLLM-backed programs without serializing credentials" do
    program =
      DSEx.predict("question -> answer",
        lm: DSEx.req_llm("openai:gpt-test", opts: [temperature: 0])
      )

    loaded = program |> DSEx.Saving.dump() |> DSEx.Saving.load()

    assert %DSEx.Clients.ReqLLM{model: "openai:gpt-test", opts: [temperature: 0]} = loaded.lm
  end
end

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

  defmodule ThinkingStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_generate, model, messages, opts})

      details = [
        %ReqLLM.Message.ReasoningDetails{
          text: "native plan",
          signature: "sig_1",
          provider: :anthropic,
          format: "anthropic-thinking-v1",
          index: 0
        }
      ]

      {:ok,
       %ReqLLM.Response{
         id: "resp_thinking",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: %ReqLLM.Message{
           role: :assistant,
           content: [
             ReqLLM.Message.ContentPart.thinking("native plan"),
             ReqLLM.Message.ContentPart.text(~s({"answer":"Paris"}))
           ],
           reasoning_details: details
         },
         object: %{"answer" => "Paris"}
       }}
    end

    def stream_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_stream, model, messages, opts})

      {:ok,
       %ReqLLM.StreamResponse{
         stream: [
           ReqLLM.StreamChunk.thinking("native plan", %{provider: :anthropic}),
           ReqLLM.StreamChunk.text("Paris"),
           ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
         ],
         metadata_handle: self(),
         cancel: fn -> :ok end,
         model: model,
         context: ReqLLM.Context.new(messages)
       }}
    end
  end

  defmodule ManualReasoningStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_generate, model, messages, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp_manual_reasoning",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(""),
         object: %{"reasoning" => "manual field", "answer" => "pong", "score" => 7}
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

  defmodule ToolStreamStub do
    def stream_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_stream, model, messages, opts})

      {:ok,
       %ReqLLM.StreamResponse{
         stream: [
           %ReqLLM.StreamChunk{
             type: :tool_call,
             name: "lookup",
             arguments: %{"query" => "beam"},
             metadata: %{id: "call_stream"}
           },
           ReqLLM.StreamChunk.meta(%{finish_reason: "tool_calls"})
         ],
         metadata_handle: self(),
         cancel: fn -> :ok end,
         model: model,
         context: ReqLLM.Context.new(messages)
       }}
    end

    def generate_text(_model, _messages, _opts), do: {:error, :not_used}
  end

  defmodule FailingStub do
    def generate_text(_model, _messages, _opts), do: raise("transport exploded")
    def stream_text(_model, _messages, _opts), do: throw(:stream_exploded)
  end

  defmodule InvalidStub do
    def generate_text(_model, _messages, _opts), do: :not_a_req_llm_response
  end

  test "ReqLLM constructor validates DSEx-owned options while preserving provider passthrough" do
    lm =
      DSEx.Clients.ReqLLM.new("openai:gpt-test",
        opts: [temperature: 0],
        top_p: 0.9,
        req_module: TextStub
      )

    assert %DSEx.Clients.ReqLLM{
             model: "openai:gpt-test",
             opts: [temperature: 0, top_p: 0.9],
             req_module: TextStub
           } = lm

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.ReqLLM\.new\/2 expects keyword options/,
                 fn ->
                   DSEx.Clients.ReqLLM.new("openai:gpt-test", %{temperature: 0})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.ReqLLM\.new\/2: invalid value for :req_module option: expected a ReqLLM-compatible module atom/,
                 fn ->
                   DSEx.Clients.ReqLLM.new("openai:gpt-test", req_module: "not-a-module")
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.ReqLLM\.new\/2: invalid value for :opts option/,
                 fn ->
                   DSEx.Clients.ReqLLM.new("openai:gpt-test", opts: %{temperature: 0})
                 end
  end

  test "ReqLLM call surfaces reject malformed option containers before provider work starts" do
    lm = DSEx.Clients.ReqLLM.new("openai:gpt-test", req_module: TextStub)

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.ReqLLM\.generate\/3 expects keyword options/,
                 fn ->
                   DSEx.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}], %{
                     cache: false
                   })
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.ReqLLM\.generate_async\/3 expects keyword options/,
                 fn ->
                   DSEx.Clients.ReqLLM.generate_async(lm, [%{role: :user, content: "hello"}], %{
                     cache: false
                   })
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.ReqLLM\.stream\/3 expects keyword options/,
                 fn ->
                   DSEx.Clients.ReqLLM.stream(lm, [%{role: :user, content: "hello"}], %{
                     provider_stream: true
                   })
                 end

    assert {:error, :req_llm_model_required} =
             DSEx.Clients.ReqLLM.generate([%{role: :user, content: "hello"}], [])
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
    refute Keyword.has_key?(opts, :native_json_schema)
    assert get_in(opts, [:provider_options, :response_format, :type]) == "json_schema"
  end

  test "ReqLLM text responses still work with DSEx adapters" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)
    program = DSEx.predict("question -> answer, score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, prediction} = DSEx.call(program, %{question: "pong?"})
    assert DSEx.Prediction.get(prediction, :answer) == "pong"
    assert DSEx.Prediction.get(prediction, :score) == 7
  end

  test "ReqLLM client translates local file path attachments into file content parts" do
    path = Path.join(System.tmp_dir!(), "dsex-req-llm-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Attachment\n")

    on_exit(fn -> File.rm(path) end)

    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)

    assert {:ok, _prediction} =
             DSEx.Clients.ReqLLM.generate(
               lm,
               [%{role: :user, content: [%DSEx.Adapters.Types.File{path: path}]}],
               []
             )

    assert_received {:req_llm_generate, "openai:gpt-test", [%ReqLLM.Message{} = message], _opts}

    assert [
             %ReqLLM.Message.ContentPart{
               type: :file,
               data: "# Attachment\n",
               filename: filename,
               media_type: "text/markdown"
             }
           ] = message.content

    assert filename == Path.basename(path)
  end

  test "ReqLLM client pre-normalizes OpenAI reasoning model options" do
    lm =
      DSEx.req_llm("openai:gpt-5.4-mini",
        test_pid: self(),
        req_module: TextStub,
        temperature: 0,
        max_tokens: 80,
        top_p: 0.5
      )

    program = DSEx.predict("question -> answer, score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, _prediction} = DSEx.call(program, %{question: "pong?"})
    assert_received {:req_llm_generate, "openai:gpt-5.4-mini", _messages, opts}

    assert Keyword.fetch!(opts, :max_completion_tokens) == 80
    refute Keyword.has_key?(opts, :max_tokens)
    refute Keyword.has_key?(opts, :temperature)
    refute Keyword.has_key?(opts, :top_p)
  end

  test "ReqLLM client preserves provider-native reasoning in prediction metadata" do
    lm = DSEx.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: ThinkingStub)

    program = DSEx.predict("question -> answer", lm: lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
    assert DSEx.get(prediction, :answer) == "Paris"
    assert prediction.metadata.native_reasoning == "native plan"

    assert [
             %ReqLLM.Message.ReasoningDetails{
               text: "native plan",
               signature: "sig_1",
               provider: :anthropic
             }
           ] = prediction.metadata.reasoning_details

    assert prediction.metadata.trace.raw == %{"answer" => "Paris"}
    assert prediction.metadata.trace.lm_metadata.native_reasoning == "native plan"
  end

  test "manual reasoning fields still work without provider-native thinking" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: ManualReasoningStub)

    program =
      DSEx.chain_of_thought("question -> answer, score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, prediction} = DSEx.call(program, %{question: "pong?"})
    refute Map.has_key?(prediction.metadata, :native_reasoning)
    assert DSEx.get(prediction, :reasoning) == "manual field"
    assert DSEx.get(prediction, :answer) == "pong"
  end

  test "ReqLLM outbound reasoning values become thinking content parts" do
    lm = DSEx.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: TextStub)

    assert {:ok, _response} =
             DSEx.Clients.ReqLLM.generate(
               lm,
               [
                 %{
                   role: :user,
                   content: [
                     %DSEx.Adapters.Types.Reasoning{text: "prior native reasoning"},
                     "question"
                   ]
                 }
               ],
               []
             )

    assert_received {:req_llm_generate, "anthropic:claude-sonnet-4-6",
                     [%ReqLLM.Message{} = message], _opts}

    assert [
             %ReqLLM.Message.ContentPart{type: :thinking, text: "prior native reasoning"},
             %ReqLLM.Message.ContentPart{type: :text, text: "question"}
           ] = message.content
  end

  test "ReqLLM client translates native JSON schema options for Anthropic" do
    lm = DSEx.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: ObjectStub)

    program =
      DSEx.predict("question -> answer, score: int",
        lm: lm,
        adapter: DSEx.Adapter.JSON,
        config: [native_json_schema: true]
      )

    assert {:ok, _prediction} = DSEx.call(program, %{question: "pong?"})
    assert_received {:req_llm_generate, "anthropic:claude-sonnet-4-6", _messages, opts}

    provider_options = Keyword.fetch!(opts, :provider_options)
    refute Keyword.has_key?(provider_options, :response_format)
    assert Keyword.fetch!(provider_options, :anthropic_beta) == ["structured-outputs-2025-11-13"]
    assert get_in(provider_options, [:output_format, :type]) == "json_schema"
    assert get_in(provider_options, [:output_format, :schema, "type"]) == "object"
  end

  test "ReqLLM client drops OpenAI-only JSON object hints for Anthropic" do
    lm =
      DSEx.req_llm("anthropic:claude-sonnet-4-6",
        test_pid: self(),
        req_module: TextStub,
        response_format: %{type: "json_object"}
      )

    program = DSEx.predict("question -> answer, score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, _prediction} = DSEx.call(program, %{question: "pong?"})
    assert_received {:req_llm_generate, "anthropic:claude-sonnet-4-6", _messages, opts}

    refute Keyword.has_key?(opts, :response_format)
    refute Keyword.has_key?(Keyword.get(opts, :provider_options, []), :response_format)
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

    program = DSEx.react("question -> answer", [tool], lm: lm, max_iters: 1)

    assert {:error, {:react_max_iters, history}} =
             DSEx.Predict.ReAct.call(program, %{question: "lookup beam"})

    assert [%{tool: :lookup, arguments: %{query: "beam"}, result: "ok"}] = history

    assert_received {:req_llm_generate, "openai:gpt-test", _messages, opts}

    assert [%ReqLLM.Tool{name: "lookup"}, %ReqLLM.Tool{name: "submit"}] =
             Keyword.fetch!(opts, :tools)
  end

  test "ReqLLM serializes DSEx and OpenAI-style assistant tool calls" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)

    calls =
      DSEx.Adapters.Types.ToolCalls.new([
        DSEx.Adapters.Types.ToolCall.new(:lookup, %{query: "beam"}, id: "call_lookup"),
        %{
          id: "call_translate",
          function: %{name: "translate", arguments: ~s({"text":"world"})}
        }
      ])

    assert {:ok, _response} =
             DSEx.Clients.ReqLLM.generate(
               lm,
               [
                 %{role: :assistant, content: "", tool_calls: calls},
                 %{role: :tool, content: "ok", tool_calls: [%{id: "call_lookup"}]}
               ],
               []
             )

    assert_received {:req_llm_generate, "openai:gpt-test",
                     [
                       %ReqLLM.Message{role: :assistant} = assistant,
                       %ReqLLM.Message{role: :tool} = tool
                     ], _opts}

    assert [
             %ReqLLM.ToolCall{
               id: "call_lookup",
               function: %{name: "lookup", arguments: ~s({"query":"beam"})}
             },
             %ReqLLM.ToolCall{
               id: "call_translate",
               function: %{name: "translate", arguments: ~s({"text":"world"})}
             }
           ] = assistant.tool_calls

    assert tool.tool_call_id == "call_lookup"
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

    assert DSEx.Streaming.collect(program, %{question: "pong"}, provider_stream: true) == "pong"

    assert_received {:req_llm_stream, "openai:gpt-test",
                     [%ReqLLM.Message{role: :system}, %ReqLLM.Message{role: :user}], _opts}

    assert_received {:req_llm_stream, "openai:gpt-test",
                     [%ReqLLM.Message{role: :system}, %ReqLLM.Message{role: :user}], _opts}
  end

  test "ReqLLM thinking stream chunks are exposed as reasoning chunks" do
    lm = DSEx.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: ThinkingStub)
    program = DSEx.predict("question -> answer", lm: lm)

    chunks =
      program
      |> DSEx.Streaming.stream(%{question: "Capital of France?"}, provider_stream: true)
      |> Enum.to_list()

    assert [
             %DSEx.Streaming.Messages.StreamResponse{
               chunk: %{reasoning: "native plan"},
               metadata: %{provider: :anthropic, type: :reasoning}
             },
             %DSEx.Streaming.Messages.StreamResponse{chunk: "Paris"},
             %DSEx.Streaming.Messages.StreamResponse{done: true}
           ] = chunks
  end

  test "ReqLLM tool-call stream chunks are exposed as normalized DSEx chunks" do
    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: ToolStreamStub)
    program = DSEx.predict("question -> tool_calls", lm: lm)

    chunks =
      program
      |> DSEx.Streaming.stream(%{question: "lookup beam"}, provider_stream: true)
      |> Enum.to_list()

    assert [
             %DSEx.Streaming.Messages.StreamResponse{
               chunk: %{
                 tool_calls: [
                   %{id: "call_stream", name: "lookup", arguments: %{"query" => "beam"}}
                 ]
               }
             },
             %DSEx.Streaming.Messages.StreamResponse{done: true}
           ] = chunks
  end

  test "ReqLLM client reports provider module failures without crashing callers" do
    lm = DSEx.req_llm("openai:gpt-test", req_module: FailingStub)

    assert {:error, {:req_llm_generate_failed, "transport exploded"}} =
             DSEx.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}], [])

    assert [
             %DSEx.Streaming.Messages.StreamResponse{
               chunk: {:error, {:req_llm_stream_failed, "{:throw, :stream_exploded}"}},
               done: true
             }
           ] = DSEx.Clients.ReqLLM.stream(lm, [%{role: :user, content: "hello"}], [])
  end

  test "ReqLLM client reports invalid provider module return shapes" do
    lm = DSEx.req_llm("openai:gpt-test", req_module: InvalidStub)

    assert {:error, {:invalid_req_llm_response, ":not_a_req_llm_response"}} =
             DSEx.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}], [])
  end

  test "save/load preserves ReqLLM-backed programs without serializing credentials" do
    program =
      DSEx.predict("question -> answer",
        lm: DSEx.req_llm("openai:gpt-test", api_key: "not-persisted", opts: [temperature: 0])
      )

    dumped = DSEx.Saving.dump(program)

    refute dumped["lm"][:opts] |> List.flatten() |> Enum.member?("not-persisted")

    loaded = DSEx.Saving.load(dumped)

    assert %DSEx.Clients.ReqLLM{model: "openai:gpt-test", opts: [temperature: 0]} = loaded.lm
  end
end

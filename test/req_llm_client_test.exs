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

  defmodule AdversarialStreamStub do
    def stream_text(model, messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      failure = Keyword.get(opts, :stream_failure, :raise)
      send(test_pid, {:provider_open, failure})

      stream =
        Stream.resource(
          fn -> 0 end,
          fn
            0 ->
              send(test_pid, {:provider_pull, 1})
              {[ReqLLM.StreamChunk.text("partial")], 1}

            1 ->
              send(test_pid, {:provider_pull, 2})

              case failure do
                :raise -> raise "provider enumeration exploded"
                :throw -> throw(:provider_enumeration_threw)
                :exit -> exit(:provider_enumeration_exited)
              end
          end,
          fn _state -> send(test_pid, :provider_cleanup) end
        )

      {:ok,
       %ReqLLM.StreamResponse{
         stream: stream,
         metadata_handle: self(),
         cancel: fn -> send(test_pid, :provider_cancelled) end,
         model: model,
         context: ReqLLM.Context.new(messages)
       }}
    end
  end

  defmodule OpenFailureStub do
    def stream_text(_model, _messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      failure = Keyword.fetch!(opts, :open_failure)
      send(test_pid, {:provider_open, failure})

      case failure do
        :error -> {:error, :provider_open_failed}
        :raise -> raise "provider open exploded"
        :throw -> throw(:provider_open_threw)
        :exit -> exit(:provider_open_exited)
      end
    end
  end

  defmodule InvalidStub do
    def generate_text(_model, _messages, _opts), do: :not_a_req_llm_response
  end

  defmodule InlineModelStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:inline_model_generate, model, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp_inline",
         model: model[:provider_model_id] || model[:id],
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(~s({"answer":"pong"})),
         object: %{"answer" => "pong"},
         provider_meta: %{"api_type" => "chat_completions"}
       }}
    end
  end

  test "ReqLLM constructor validates Imp-owned options while preserving provider passthrough" do
    lm =
      Imp.Clients.ReqLLM.new("openai:gpt-test",
        opts: [temperature: 0],
        top_p: 0.9,
        req_module: TextStub
      )

    assert %Imp.Clients.ReqLLM{
             model: "openai:gpt-test",
             opts: [temperature: 0, top_p: 0.9],
             req_module: TextStub
           } = lm

    assert_raise ArgumentError,
                 ~r/Imp.Clients.ReqLLM\.new\/2 expects keyword options/,
                 fn ->
                   Imp.Clients.ReqLLM.new("openai:gpt-test", %{temperature: 0})
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.ReqLLM\.new\/2: invalid value for :req_module option: expected a ReqLLM-compatible module atom/,
                 fn ->
                   Imp.Clients.ReqLLM.new("openai:gpt-test", req_module: "not-a-module")
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.ReqLLM\.new\/2: invalid value for :opts option/,
                 fn ->
                   Imp.Clients.ReqLLM.new("openai:gpt-test", opts: %{temperature: 0})
                 end
  end

  test "ReqLLM call surfaces reject malformed option containers before provider work starts" do
    lm = Imp.Clients.ReqLLM.new("openai:gpt-test", req_module: TextStub)

    assert_raise ArgumentError,
                 ~r/Imp.Clients.ReqLLM\.generate\/3 expects keyword options/,
                 fn ->
                   Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}], %{
                     cache: false
                   })
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.ReqLLM\.generate_async\/3 expects keyword options/,
                 fn ->
                   Imp.Clients.ReqLLM.generate_async(lm, [%{role: :user, content: "hello"}], %{
                     cache: false
                   })
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.ReqLLM\.stream\/3 expects keyword options/,
                 fn ->
                   Imp.Clients.ReqLLM.stream(lm, [%{role: :user, content: "hello"}], %{
                     provider_stream: true
                   })
                 end

    assert {:error, :req_llm_model_required} =
             Imp.Clients.ReqLLM.generate([%{role: :user, content: "hello"}], [])
  end

  test "ReqLLM client drives Imp prediction and translates JSON/schema options" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: ObjectStub)

    program =
      Imp.predict("question -> answer, score: int",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [temperature: 0, timeout: 1_000, native_json_schema: true]
      )

    assert {:ok, prediction} =
             Imp.Predict.Predict.call(program, %{question: "reply with pong and score 7"})

    assert Imp.Prediction.get(prediction, :answer) == "pong"
    assert Imp.Prediction.get(prediction, :score) == 7

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

  test "ReqLLM text responses still work with Imp adapters" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)
    program = Imp.predict("question -> answer, score: int", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, prediction} = Imp.call(program, %{question: "pong?"})
    assert Imp.Prediction.get(prediction, :answer) == "pong"
    assert Imp.Prediction.get(prediction, :score) == 7
  end

  test "ReqLLM consumes rollout IDs without forwarding them to the provider" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)

    program =
      Imp.predict("question -> answer, score: int",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [cache: false, rollout_id: 17]
      )

    assert {:ok, _prediction} = Imp.call(program, %{question: "pong?"})
    assert_received {:req_llm_generate, "openai:gpt-test", _messages, opts}
    refute Keyword.has_key?(opts, :rollout_id)

    messages = [%{role: :user, content: "same prompt"}]

    refute Imp.Clients.ReqLLM.cache_key(lm, messages, rollout_id: 17) ==
             Imp.Clients.ReqLLM.cache_key(lm, messages, rollout_id: 18)
  end

  test "ReqLLM client translates local file path attachments into file content parts" do
    path = Path.join(System.tmp_dir!(), "imp-req-llm-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Attachment\n")

    on_exit(fn -> File.rm(path) end)

    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)

    assert {:ok, _prediction} =
             Imp.Clients.ReqLLM.generate(
               lm,
               [%{role: :user, content: [%Imp.Adapters.Types.File{path: path}]}],
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
      Imp.req_llm("openai:gpt-5.4-mini",
        test_pid: self(),
        req_module: TextStub,
        temperature: 0,
        max_tokens: 80,
        top_p: 0.5
      )

    program = Imp.predict("question -> answer, score: int", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, _prediction} = Imp.call(program, %{question: "pong?"})
    assert_received {:req_llm_generate, "openai:gpt-5.4-mini", _messages, opts}

    assert Keyword.fetch!(opts, :max_completion_tokens) == 80
    refute Keyword.has_key?(opts, :max_tokens)
    refute Keyword.has_key?(opts, :temperature)
    refute Keyword.has_key?(opts, :top_p)
  end

  test "ReqLLM client supports inline model descriptors without losing provider profiles" do
    chat_model = %{
      provider: :openai,
      id: "gpt-4o-mini",
      provider_model_id: "gpt-4o-mini",
      extra: %{wire: %{protocol: "openai_chat"}}
    }

    chat_lm =
      Imp.req_llm(chat_model,
        test_pid: self(),
        req_module: InlineModelStub,
        temperature: 0,
        max_tokens: 80
      )

    assert {:ok, _output} =
             Imp.Clients.ReqLLM.generate(chat_lm, [%{role: :user, content: "pong?"}], [])

    assert_received {:inline_model_generate, ^chat_model, chat_opts}
    assert Keyword.fetch!(chat_opts, :max_tokens) == 80
    assert Keyword.fetch!(chat_opts, :temperature) == 0

    reasoning_model = %{provider: :openai, id: "gpt-5.4-mini"}

    reasoning_lm =
      Imp.req_llm(reasoning_model,
        test_pid: self(),
        req_module: InlineModelStub,
        temperature: 0,
        max_tokens: 80
      )

    assert {:ok, _output} =
             Imp.Clients.ReqLLM.generate(reasoning_lm, [%{role: :user, content: "pong?"}], [])

    assert_received {:inline_model_generate, ^reasoning_model, reasoning_opts}
    assert Keyword.fetch!(reasoning_opts, :max_completion_tokens) == 80
    refute Keyword.has_key?(reasoning_opts, :max_tokens)
    refute Keyword.has_key?(reasoning_opts, :temperature)
  end

  test "ReqLLM client preserves provider-native reasoning in prediction metadata" do
    lm = Imp.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: ThinkingStub)

    program = Imp.predict("question -> answer", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris"
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
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: ManualReasoningStub)

    program =
      Imp.chain_of_thought("question -> answer, score: int", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, prediction} = Imp.call(program, %{question: "pong?"})
    refute Map.has_key?(prediction.metadata, :native_reasoning)
    assert Imp.get(prediction, :reasoning) == "manual field"
    assert Imp.get(prediction, :answer) == "pong"
  end

  test "ReqLLM outbound reasoning values become thinking content parts" do
    lm = Imp.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: TextStub)

    assert {:ok, _response} =
             Imp.Clients.ReqLLM.generate(
               lm,
               [
                 %{
                   role: :user,
                   content: [
                     %Imp.Adapters.Types.Reasoning{text: "prior native reasoning"},
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
    lm = Imp.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: ObjectStub)

    program =
      Imp.predict("question -> answer, score: int",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [native_json_schema: true]
      )

    assert {:ok, _prediction} = Imp.call(program, %{question: "pong?"})
    assert_received {:req_llm_generate, "anthropic:claude-sonnet-4-6", _messages, opts}

    provider_options = Keyword.fetch!(opts, :provider_options)
    refute Keyword.has_key?(provider_options, :response_format)
    assert Keyword.fetch!(provider_options, :anthropic_beta) == ["structured-outputs-2025-11-13"]
    assert get_in(provider_options, [:output_format, :type]) == "json_schema"
    assert get_in(provider_options, [:output_format, :schema, "type"]) == "object"
  end

  test "ReqLLM client drops OpenAI-only JSON object hints for Anthropic" do
    lm =
      Imp.req_llm("anthropic:claude-sonnet-4-6",
        test_pid: self(),
        req_module: TextStub,
        response_format: %{type: "json_object"}
      )

    program = Imp.predict("question -> answer, score: int", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, _prediction} = Imp.call(program, %{question: "pong?"})
    assert_received {:req_llm_generate, "anthropic:claude-sonnet-4-6", _messages, opts}

    refute Keyword.has_key?(opts, :response_format)
    refute Keyword.has_key?(Keyword.get(opts, :provider_options, []), :response_format)
  end

  test "ReqLLM tool calls return Imp ReAct-compatible tool call payloads" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: ToolStub)

    tool =
      Imp.Tool.new(:lookup, "Lookup a fact.", fn %{query: "beam"} -> "ok" end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    program = Imp.react("question -> answer", [tool], lm: lm, max_iters: 1)

    assert {:error, {:react_max_iters, history}} =
             Imp.Predict.ReAct.call(program, %{question: "lookup beam"})

    assert [%{tool: :lookup, arguments: %{query: "beam"}, result: "ok"}] = history

    assert_received {:req_llm_generate, "openai:gpt-test", _messages, opts}

    assert [%ReqLLM.Tool{name: "lookup"}, %ReqLLM.Tool{name: "submit"}] =
             Keyword.fetch!(opts, :tools)
  end

  test "ReqLLM serializes Imp and OpenAI-style assistant tool calls" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)

    calls =
      Imp.Adapters.Types.ToolCalls.new([
        Imp.Adapters.Types.ToolCall.new(:lookup, %{query: "beam"}, id: "call_lookup"),
        %{
          id: "call_translate",
          function: %{name: "translate", arguments: ~s({"text":"world"})}
        }
      ])

    assert {:ok, _response} =
             Imp.Clients.ReqLLM.generate(
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

  test "ReqLLM stream chunks are exposed through Imp streaming vocabulary" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)
    program = Imp.predict("question -> answer", lm: lm)

    chunks =
      program
      |> Imp.Streaming.stream(%{question: "pong"}, provider_stream: true)
      |> Enum.to_list()

    assert Enum.map(chunks, & &1.chunk) |> Enum.reject(&is_nil/1) == ["po", "ng"]
    assert Enum.any?(chunks, & &1.done)

    assert Imp.Streaming.collect(program, %{question: "pong"}, provider_stream: true) == "pong"

    assert_received {:req_llm_stream, "openai:gpt-test",
                     [%ReqLLM.Message{role: :system}, %ReqLLM.Message{role: :user}], _opts}

    assert_received {:req_llm_stream, "openai:gpt-test",
                     [%ReqLLM.Message{role: :system}, %ReqLLM.Message{role: :user}], _opts}
  end

  test "ReqLLM thinking stream chunks are exposed as reasoning chunks" do
    lm = Imp.req_llm("anthropic:claude-sonnet-4-6", test_pid: self(), req_module: ThinkingStub)
    program = Imp.predict("question -> answer", lm: lm)

    chunks =
      program
      |> Imp.Streaming.stream(%{question: "Capital of France?"}, provider_stream: true)
      |> Enum.to_list()

    assert [
             %Imp.Streaming.Messages.StreamResponse{
               chunk: %{reasoning: "native plan"},
               metadata: %{provider: :anthropic, type: :reasoning}
             },
             %Imp.Streaming.Messages.StreamResponse{chunk: "Paris"},
             %Imp.Streaming.Messages.StreamResponse{done: true}
           ] = chunks
  end

  test "ReqLLM tool-call stream chunks are exposed as normalized Imp chunks" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: ToolStreamStub)
    program = Imp.predict("question -> tool_calls", lm: lm)

    chunks =
      program
      |> Imp.Streaming.stream(%{question: "lookup beam"}, provider_stream: true)
      |> Enum.to_list()

    assert [
             %Imp.Streaming.Messages.StreamResponse{
               chunk: %{
                 tool_calls: [
                   %{id: "call_stream", name: "lookup", arguments: %{"query" => "beam"}}
                 ]
               }
             },
             %Imp.Streaming.Messages.StreamResponse{done: true}
           ] = chunks
  end

  test "ReqLLM client reports provider module failures without crashing callers" do
    lm = Imp.req_llm("openai:gpt-test", req_module: FailingStub)

    assert {:error, {:req_llm_generate_failed, "transport exploded"}} =
             Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}], [])

    assert [
             %Imp.Streaming.Messages.StreamResponse{
               chunk: {:error, {:req_llm_stream_failed, "{:throw, :stream_exploded}"}},
               done: true
             }
           ] =
             lm
             |> Imp.Clients.ReqLLM.stream([%{role: :user, content: "hello"}], [])
             |> Enum.to_list()
  end

  test "ReqLLM stream construction and dropping have no provider or telemetry side effects" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :lm, :stream, :start],
        [:imp, :lm, :stream, :stop]
      ])

    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: AdversarialStreamStub)
    _stream = Imp.Clients.ReqLLM.stream(lm, [%{role: :user, content: "hello"}], [])

    refute_received {:provider_open, _failure}
    refute_received {:provider_pull, _count}
    refute_received {^ref, [:imp, :lm, :stream, :start], _, _}
    refute_received {^ref, [:imp, :lm, :stream, :stop], _, _}
  end

  test "ReqLLM first pull opens once and early halt cleans and cancels once" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :lm, :stream, :start],
        [:imp, :lm, :stream, :stop]
      ])

    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: AdversarialStreamStub)
    stream = Imp.Clients.ReqLLM.stream(lm, [%{role: :user, content: "hello"}], [])

    refute_received {:provider_open, _failure}
    refute_received {:provider_pull, _count}

    assert [%Imp.Streaming.Messages.StreamResponse{chunk: "partial", done: false}] =
             Enum.take(stream, 1)

    assert_received {:provider_open, :raise}
    assert_received {:provider_pull, 1}
    refute_received {:provider_pull, 2}
    assert_received :provider_cleanup
    assert_received :provider_cancelled
    assert_received {^ref, [:imp, :lm, :stream, :start], _, _}
    assert_received {^ref, [:imp, :lm, :stream, :stop], %{count: 1}, _}
    refute_received {:provider_open, _failure}
    refute_received :provider_cleanup
    refute_received :provider_cancelled
    refute_received {^ref, [:imp, :lm, :stream, :start], _, _}
    refute_received {^ref, [:imp, :lm, :stream, :stop], _, _}
  end

  test "ReqLLM open failures emit one terminal error with balanced telemetry" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :lm, :stream, :start],
        [:imp, :lm, :stream, :stop]
      ])

    expected = [
      error: :provider_open_failed,
      raise: {:req_llm_stream_failed, "provider open exploded"},
      throw: {:req_llm_stream_failed, "{:throw, :provider_open_threw}"},
      exit: {:req_llm_stream_failed, "{:exit, :provider_open_exited}"}
    ]

    Enum.each(expected, fn {failure, reason} ->
      lm =
        Imp.req_llm("openai:gpt-test",
          test_pid: self(),
          open_failure: failure,
          req_module: OpenFailureStub
        )

      assert [
               %Imp.Streaming.Messages.StreamResponse{
                 chunk: {:error, ^reason},
                 done: true
               }
             ] =
               lm
               |> Imp.Clients.ReqLLM.stream([%{role: :user, content: "hello"}], [])
               |> Enum.to_list()

      assert_received {:provider_open, ^failure}
      assert_received {^ref, [:imp, :lm, :stream, :start], _, _}
      assert_received {^ref, [:imp, :lm, :stream, :stop], %{count: 1}, _}
      refute_received :provider_cleanup
      refute_received :provider_cancelled
    end)

    refute_received {:provider_open, _failure}
    refute_received {^ref, [:imp, :lm, :stream, :start], _, _}
    refute_received {^ref, [:imp, :lm, :stream, :stop], _, _}
  end

  test "ReqLLM enumeration raise, throw, and exit emit one terminal error and clean once" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :lm, :stream, :start],
        [:imp, :lm, :stream, :stop]
      ])

    expected = [
      raise: "provider enumeration exploded",
      throw: "{:throw, :provider_enumeration_threw}",
      exit: "{:exit, :provider_enumeration_exited}"
    ]

    Enum.each(expected, fn {failure, message} ->
      lm =
        Imp.req_llm("openai:gpt-test",
          test_pid: self(),
          stream_failure: failure,
          req_module: AdversarialStreamStub
        )

      assert [
               %Imp.Streaming.Messages.StreamResponse{chunk: "partial", done: false},
               %Imp.Streaming.Messages.StreamResponse{
                 chunk: {:error, {:req_llm_stream_failed, ^message}},
                 done: true
               }
             ] =
               lm
               |> Imp.Clients.ReqLLM.stream([%{role: :user, content: "hello"}], [])
               |> Enum.to_list()

      assert_received {:provider_open, ^failure}
      assert_received {:provider_pull, 1}
      assert_received {:provider_pull, 2}
      assert_received :provider_cleanup
      assert_received :provider_cancelled
      assert_received {^ref, [:imp, :lm, :stream, :start], _, _}
      assert_received {^ref, [:imp, :lm, :stream, :stop], %{count: 1}, _}
      refute_received :provider_cleanup
      refute_received :provider_cancelled
    end)

    refute_received {^ref, [:imp, :lm, :stream, :start], _, _}
    refute_received {^ref, [:imp, :lm, :stream, :stop], _, _}
  end

  test "stream collection returns a terminal provider error instead of partial output" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: AdversarialStreamStub)
    program = Imp.predict("question -> answer", lm: lm)

    assert {:error, {:req_llm_stream_failed, "provider enumeration exploded"}} =
             Imp.Streaming.collect(program, %{question: "hello"}, provider_stream: true)

    assert_received :provider_cleanup
    assert_received :provider_cancelled
    refute_received :provider_cleanup
    refute_received :provider_cancelled
  end

  test "ReqLLM client reports invalid provider module return shapes" do
    lm = Imp.req_llm("openai:gpt-test", req_module: InvalidStub)

    assert {:error, {:invalid_req_llm_response, ":not_a_req_llm_response"}} =
             Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}], [])
  end

  test "save/load preserves ReqLLM-backed programs without serializing credentials" do
    program =
      Imp.predict("question -> answer",
        lm: Imp.req_llm("openai:gpt-test", api_key: "not-persisted", opts: [temperature: 0])
      )

    dumped = Imp.Saving.dump(program)

    refute dumped["lm"][:opts] |> List.flatten() |> Enum.member?("not-persisted")

    loaded = Imp.Saving.load(dumped)

    assert %Imp.Clients.ReqLLM{model: "openai:gpt-test", opts: [temperature: 0]} = loaded.lm
  end
end

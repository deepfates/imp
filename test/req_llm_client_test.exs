defmodule ReqLLMClientTest do
  use ExUnit.Case

  @credential_canaries [
    auth: "CANARY_AUTH",
    bearer: "CANARY_BEARER",
    session: "CANARY_SESSION",
    provider_auth: "CANARY_PROVIDER_AUTH",
    providerAuth: "CANARY_PROVIDER_CAMEL_AUTH",
    provider_bearer: "CANARY_PROVIDER_BEARER",
    providerSession: "CANARY_PROVIDER_CAMEL_SESSION",
    api_key: "CANARY_API_KEY",
    authorization: "CANARY_AUTHORIZATION",
    proxy_authorization: "CANARY_PROXY_AUTHORIZATION",
    token: "CANARY_TOKEN",
    api_token: "CANARY_API_TOKEN",
    auth_token: "CANARY_AUTH_TOKEN",
    bearer_token: "CANARY_BEARER_TOKEN",
    access_token: "CANARY_ACCESS_TOKEN",
    refresh_token: "CANARY_REFRESH_TOKEN",
    id_token: "CANARY_ID_TOKEN",
    session_token: "CANARY_SESSION_TOKEN",
    access_key: "CANARY_ACCESS_KEY",
    access_key_id: "CANARY_ACCESS_KEY_ID",
    secret_access_key: "CANARY_SECRET_ACCESS_KEY",
    secret_key: "CANARY_SECRET_KEY",
    client_secret: "CANARY_CLIENT_SECRET",
    private_key: "CANARY_PRIVATE_KEY",
    private_token: "CANARY_PRIVATE_TOKEN",
    service_account_key: "CANARY_SERVICE_ACCOUNT_KEY",
    password: "CANARY_PASSWORD",
    secret: "CANARY_SECRET",
    credential: "CANARY_CREDENTIAL",
    credentials: "CANARY_CREDENTIALS",
    aws_access_key_id: "CANARY_AWS_ACCESS_KEY_ID",
    "x-api-key": "CANARY_X_API_KEY"
  ]

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

  defmodule NestedObjectStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_generate, model, messages, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp_nested",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(""),
         object: %{"items" => [%{"answer" => "yes", "confidence" => 0.9}]}
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

  test "ReqLLM receives recursive native JSON schema constraints" do
    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{
            name: :items,
            type: :array,
            constraints: %{
              items: %{
                type: :object,
                properties: %{
                  answer: %{type: :string, enum: ["yes", "no"]},
                  confidence: %{type: :number, min: 0, max: 1}
                }
              }
            }
          }
        ]
      })

    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: NestedObjectStub)

    program =
      Imp.predict(signature,
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [native_json_schema: true]
      )

    assert {:ok, prediction} = Imp.Predict.Predict.call(program, %{question: "classify"})
    assert [%{"answer" => "yes", "confidence" => 0.9}] = Imp.get(prediction, :items)

    assert_received {:req_llm_generate, "openai:gpt-test", _messages, opts}
    schema = get_in(opts, [:provider_options, :response_format, :json_schema, :schema])
    item_schema = get_in(schema, ["properties", "items", "items"])

    assert item_schema["required"] == ["answer", "confidence"]
    assert get_in(item_schema, ["properties", "answer", "enum"]) == ["yes", "no"]
    assert get_in(item_schema, ["properties", "confidence", "minimum"]) == 0
    assert get_in(item_schema, ["properties", "confidence", "maximum"]) == 1
  end

  test "ReqLLM caps receive and connect transport timeouts to the GEPA deadline" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: ObjectStub)
    deadline = Imp.Optimizer.GEPA.Coordinator.deadline(1_000)

    assert {:ok, _output} =
             Imp.Optimizer.GEPA.Coordinator.with_deadline({:deadline, deadline}, fn ->
               Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}],
                 timeout: 5_000,
                 connect_options: [timeout: 5_000]
               )
             end)

    assert_received {:req_llm_generate, "openai:gpt-test", _messages, opts}
    assert Keyword.fetch!(opts, :receive_timeout) <= 1_000
    assert Keyword.fetch!(opts, :connect_options)[:timeout] <= 1_000
  end

  test "ReqLLM text responses still work with Imp adapters" do
    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: TextStub)
    program = Imp.predict("question -> answer, score: int", lm: lm, adapter: Imp.Adapter.JSON)

    assert {:ok, prediction} = Imp.call(program, %{question: "pong?"})
    assert Imp.Prediction.get(prediction, :answer) == "pong"
    assert Imp.Prediction.get(prediction, :score) == 7
  end

  test "ReqLLM consumes rollout IDs without forwarding them to the provider" do
    Imp.Cache.clear()
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

    assert {:ok, first} = Imp.Clients.ReqLLM.generate(lm, messages, rollout_id: 17)
    assert {:ok, ^first} = Imp.Clients.ReqLLM.generate(lm, messages, rollout_id: 17)
    assert_received {:req_llm_generate, "openai:gpt-test", _messages, cached_opts}
    refute Keyword.has_key?(cached_opts, :rollout_id)
    refute_received {:req_llm_generate, "openai:gpt-test", _messages, _opts}

    assert {:ok, _second_rollout} =
             Imp.Clients.ReqLLM.generate(lm, messages, rollout_id: 18)

    assert_received {:req_llm_generate, "openai:gpt-test", _messages, second_opts}
    refute Keyword.has_key?(second_opts, :rollout_id)
  end

  test "ReqLLM caches by default, allows opt-out, and excludes credentials from cache identity" do
    Imp.Cache.clear()
    model = "openai:gpt-cache-#{System.unique_integer([:positive])}"
    messages = [%{role: :user, content: "same prompt"}]
    lm = Imp.req_llm(model, test_pid: self(), req_module: TextStub)

    assert {:ok, first} = Imp.Clients.ReqLLM.generate(lm, messages, [])
    assert {:ok, ^first} = Imp.Clients.ReqLLM.generate(lm, messages, [])
    assert_received {:req_llm_generate, ^model, _messages, _opts}
    refute_received {:req_llm_generate, ^model, _messages, _opts}

    assert {:ok, _uncached} = Imp.Clients.ReqLLM.generate(lm, messages, cache: false)
    assert_received {:req_llm_generate, ^model, _messages, uncached_opts}
    refute Keyword.has_key?(uncached_opts, :cache)

    first_key =
      Imp.Clients.ReqLLM.cache_key(lm, messages,
        api_key: "sk-first-credential",
        authorization: "Bearer first-credential-value",
        headers: [{"x-api-key", "first"}],
        provider_options: %{client_secret: "first"}
      )

    second_key =
      Imp.Clients.ReqLLM.cache_key(lm, messages,
        api_key: "sk-second-credential",
        authorization: "Bearer second-credential-value",
        headers: [{"x-api-key", "second"}],
        provider_options: %{client_secret: "second"}
      )

    assert first_key == second_key

    typed_key = %{"__imp_type__" => "atom", "value" => "api_key", "extra" => "bypass"}

    assert Imp.Clients.ReqLLM.cache_key(lm, messages,
             provider_options: %{typed_key => "CANARY_TYPED_FIRST"}
           ) ==
             Imp.Clients.ReqLLM.cache_key(lm, messages,
               provider_options: %{typed_key => "CANARY_TYPED_SECOND"}
             )

    mixed_envelope = fn canary ->
      encoded_key = %{"__imp_type__" => "atom", "value" => "api_key"}

      Map.new([
        {:__imp_type__, "noop"},
        {"__imp_type__", "map"},
        {:entries, [[encoded_key, canary]]},
        {"entries", []}
      ])
    end

    assert Imp.Clients.ReqLLM.cache_key(lm, messages,
             provider_options: mixed_envelope.("CANARY_COLLISION_FIRST")
           ) ==
             Imp.Clients.ReqLLM.cache_key(lm, messages,
               provider_options: mixed_envelope.("CANARY_COLLISION_SECOND")
             )
  end

  test "ReqLLM cache behavior isolates endpoints and semantic secret-shaped values" do
    model = "openai:gpt-cache-routing-#{System.unique_integer([:positive])}"
    messages = [%{role: :user, content: "same prompt"}]

    Imp.Cache.clear()

    endpoint_a =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        base_url: "https://endpoint-a.example/v1"
      )

    endpoint_b =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        base_url: "https://endpoint-b.example/v1"
      )

    assert {:ok, _response} = Imp.Clients.ReqLLM.generate(endpoint_a, messages, [])
    assert {:ok, _response} = Imp.Clients.ReqLLM.generate(endpoint_b, messages, [])
    assert_received {:req_llm_generate, ^model, _messages, first_endpoint_opts}
    assert_received {:req_llm_generate, ^model, _messages, second_endpoint_opts}
    assert first_endpoint_opts[:base_url] != second_endpoint_opts[:base_url]

    Imp.Cache.clear()

    semantic_a =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        provider_options: %{request_id: String.duplicate("a", 40)}
      )

    semantic_b =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        provider_options: %{request_id: String.duplicate("b", 40)}
      )

    assert {:ok, _response} = Imp.Clients.ReqLLM.generate(semantic_a, messages, [])
    assert {:ok, _response} = Imp.Clients.ReqLLM.generate(semantic_b, messages, [])
    assert_received {:req_llm_generate, ^model, _messages, _opts}
    assert_received {:req_llm_generate, ^model, _messages, _opts}

    refute Imp.Clients.ReqLLM.cache_key(semantic_a, messages, max_tokens: 32) ==
             Imp.Clients.ReqLLM.cache_key(semantic_a, messages, max_tokens: 64)
  end

  test "ReqLLM cache behavior ignores rotated credentials but preserves other headers" do
    model = "openai:gpt-cache-credentials-#{System.unique_integer([:positive])}"
    messages = [%{role: :user, content: "same prompt"}]

    Imp.Cache.clear()

    credential_a =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        api_key: "sk-first-credential",
        headers: [{"authorization", "Bearer first-credential-value"}],
        provider_options: %{aws_access_key_id: "AKIAFIRSTCREDENTIAL"}
      )

    credential_b =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        api_key: "sk-second-credential",
        headers: [{"authorization", "Bearer second-credential-value"}],
        provider_options: %{aws_access_key_id: "AKIASECONDCREDENTIAL"}
      )

    assert {:ok, first} = Imp.Clients.ReqLLM.generate(credential_a, messages, [])
    assert {:ok, ^first} = Imp.Clients.ReqLLM.generate(credential_b, messages, [])
    assert_received {:req_llm_generate, ^model, _messages, _opts}
    refute_received {:req_llm_generate, ^model, _messages, _opts}

    Imp.Cache.clear()

    header_a =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        headers: [{"x-tenant", "tenant-a"}]
      )

    header_b =
      Imp.req_llm(model,
        test_pid: self(),
        req_module: TextStub,
        headers: [{"x-tenant", "tenant-b"}]
      )

    assert {:ok, _response} = Imp.Clients.ReqLLM.generate(header_a, messages, [])
    assert {:ok, _response} = Imp.Clients.ReqLLM.generate(header_b, messages, [])
    assert_received {:req_llm_generate, ^model, _messages, _opts}
    assert_received {:req_llm_generate, ^model, _messages, _opts}
  end

  test "ReqLLM cache identity isolates injected request modules" do
    model = "openai:gpt-cache-module-#{System.unique_integer([:positive])}"
    messages = [%{role: :user, content: "same prompt"}]

    text_lm = Imp.req_llm(model, req_module: TextStub)
    object_lm = Imp.req_llm(model, req_module: ObjectStub)

    refute Imp.Clients.ReqLLM.cache_key(text_lm, messages, []) ==
             Imp.Clients.ReqLLM.cache_key(object_lm, messages, [])
  end

  test "ReqLLM cache identity distinguishes secret-shaped local model paths" do
    run_id = String.duplicate("a", 64)
    messages = [%{role: :user, content: "same prompt"}]

    baseline =
      Imp.req_llm(%{
        provider: :openai,
        id: "/private/tmp/imp-mlx/#{run_id}/baseline",
        model: "/private/tmp/imp-mlx/#{run_id}/baseline"
      })

    fused =
      Imp.req_llm(%{
        provider: :openai,
        id: "/private/tmp/imp-mlx/#{run_id}/fused",
        model: "/private/tmp/imp-mlx/#{run_id}/fused"
      })

    assert Imp.Redaction.redact(baseline.model) == baseline.model
    assert Imp.Redaction.redact(fused.model) == fused.model
    refute Imp.Redaction.redact(baseline.model) == Imp.Redaction.redact(fused.model)

    refute Imp.Clients.ReqLLM.cache_key(baseline, messages, []) ==
             Imp.Clients.ReqLLM.cache_key(fused, messages, [])
  end

  test "ReqLLM cache identity excludes inline model credentials" do
    messages = [%{role: :user, content: "same prompt"}]

    first =
      Imp.req_llm(%{
        provider: :openai,
        id: "gpt-inline",
        api_key: "sk-first-inline-credential",
        access_key_id: "AKIAFIRSTINLINE"
      })

    second =
      Imp.req_llm(%{
        provider: :openai,
        id: "gpt-inline",
        api_key: "sk-second-inline-credential",
        access_key_id: "AKIASECONDINLINE"
      })

    assert Imp.Clients.ReqLLM.cache_key(first, messages, []) ==
             Imp.Clients.ReqLLM.cache_key(second, messages, [])
  end

  test "ReqLLM cache hits survive every representative credential rotation shape" do
    messages = [%{role: :user, content: "same prompt"}]

    for {credential_key, first_canary} <- @credential_canaries,
        shape <- [:top_level, :provider_options, :inline_model] do
      Imp.Cache.clear()
      model_id = "credential-rotation-#{credential_key}-#{shape}"
      second_canary = first_canary <> "_ROTATED"
      {first_lm, provider_event} = rotation_lm(shape, model_id, credential_key, first_canary)
      {second_lm, ^provider_event} = rotation_lm(shape, model_id, credential_key, second_canary)

      assert {:ok, first_response} = Imp.Clients.ReqLLM.generate(first_lm, messages, [])
      assert {:ok, ^first_response} = Imp.Clients.ReqLLM.generate(second_lm, messages, [])
      assert_provider_call(provider_event)
      refute_provider_call(provider_event)
    end
  end

  test "ReqLLM telemetry redacts credentials embedded in model descriptors" do
    ref = Imp.Test.TelemetryHelpers.attach([[:imp, :lm, :start]])

    lm =
      Imp.req_llm(
        %{
          provider: :openai,
          id: "gpt-inline",
          api_key: "sk-inline-secret-1234567890",
          access_key_id: "AKIAINLINEPLAINTEXT",
          nested: %{authorization: "Bearer abcdefghijklmnop"}
        },
        test_pid: self(),
        req_module: TextStub
      )

    assert {:error, _reason} =
             Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hello"}], cache: false)

    assert_received {^ref, [:imp, :lm, :start], _, %{lm: %{model: redacted_model}}}
    assert redacted_model.api_key == "[REDACTED]"
    assert redacted_model.access_key_id == "[REDACTED]"
    assert redacted_model.nested.authorization == "[REDACTED]"
    assert redacted_model.id == "gpt-inline"
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

  test "ReqLLM dumps, saved artifacts, and loads disclose no credential canary" do
    canary_map = Map.new(@credential_canaries)
    model_id = String.duplicate("d", 40)
    model_path = "/private/tmp/imp-models/#{String.duplicate("e", 64)}/fused"

    credential_headers =
      Enum.map(@credential_canaries, fn {key, canary} -> {to_string(key), canary} end)

    model =
      Map.merge(
        %{
          provider: :openai,
          id: model_id,
          model: model_path,
          provider_options: Map.merge(canary_map, %{region: "us-west-2"})
        },
        canary_map
      )

    runtime_opts =
      [
        max_tokens: 96,
        request_id: model_id,
        provider_options: Map.merge(canary_map, %{region: "us-west-2", request_id: model_id}),
        headers: credential_headers ++ [{"x-tenant", "tenant-a"}]
      ] ++ @credential_canaries

    lm = Imp.req_llm(model, opts: runtime_opts)
    client_dump = Imp.Clients.ReqLLM.dump(lm)

    refute_credential_canaries(client_dump)
    assert client_dump.model.id == model_id
    assert client_dump.model.model == model_path

    program =
      Imp.predict("question -> answer",
        lm: lm,
        config: [
          max_tokens: 96,
          request_id: model_id,
          provider_options: Map.merge(canary_map, %{request_id: model_id}),
          headers: credential_headers ++ [{"x-tenant", "tenant-a"}]
        ],
        metadata: %{
          nested: [canary_map],
          headers: credential_headers,
          inline_model: Map.merge(%{id: model_id, model: model_path}, canary_map)
        }
      )

    dumped = Imp.Saving.dump(program)
    refute_credential_canaries(dumped)
    assert dumped["lm"][:model].id == model_id
    assert dumped["lm"][:model].model == model_path

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-credential-redaction-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    assert :ok = Imp.Saving.save!(program, path)
    refute_credential_canaries(File.read!(path))

    loaded = Imp.Saving.load!(path)
    refute_credential_canaries(loaded)
    assert loaded.lm.model["id"] == model_id
    assert loaded.lm.model["model"] == model_path
    assert loaded.lm.opts[:max_tokens] == 96
    assert loaded.lm.opts[:request_id] == model_id
    assert loaded.lm.opts[:provider_options]["request_id"] == model_id
    assert loaded.lm.opts[:headers] == [{"x-tenant", "tenant-a"}]

    poisoned_lm = %{
      provider: :req_llm,
      model: Map.merge(%{provider: :openai, id: model_id, model: model_path}, canary_map),
      opts:
        Enum.map(@credential_canaries, fn {key, canary} -> [to_string(key), canary] end) ++
          [
            ["max_tokens", 96],
            ["request_id", model_id],
            ["provider_options", Map.merge(canary_map, %{request_id: model_id})],
            ["headers", credential_headers ++ [{"x-tenant", "tenant-a"}]]
          ]
    }

    loaded_poisoned = dumped |> put_in(["lm"], poisoned_lm) |> Imp.Saving.load()

    refute_credential_canaries(loaded_poisoned)
    assert loaded_poisoned.lm.model.id == model_id
    assert loaded_poisoned.lm.model.model == model_path
    assert loaded_poisoned.lm.opts[:max_tokens] == 96
    assert loaded_poisoned.lm.opts[:request_id] == model_id
    assert loaded_poisoned.lm.opts[:provider_options] == %{request_id: model_id}
    assert loaded_poisoned.lm.opts[:headers] == [{"x-tenant", "tenant-a"}]
  end

  defp rotation_lm(:top_level, model_id, credential_key, canary) do
    opts = [test_pid: self(), req_module: TextStub] ++ [{credential_key, canary}]
    {Imp.req_llm("openai:#{model_id}", opts), :req_llm_generate}
  end

  defp rotation_lm(:provider_options, model_id, credential_key, canary) do
    lm =
      Imp.req_llm("openai:#{model_id}",
        test_pid: self(),
        req_module: TextStub,
        provider_options: %{credential_key => canary}
      )

    {lm, :req_llm_generate}
  end

  defp rotation_lm(:inline_model, model_id, credential_key, canary) do
    lm =
      Imp.req_llm(
        %{credential_key => canary, provider: :openai, id: model_id},
        test_pid: self(),
        req_module: InlineModelStub
      )

    {lm, :inline_model_generate}
  end

  defp assert_provider_call(:req_llm_generate),
    do: assert_receive({:req_llm_generate, _, _, _}, 1_000)

  defp assert_provider_call(:inline_model_generate),
    do: assert_receive({:inline_model_generate, _, _}, 1_000)

  defp refute_provider_call(:req_llm_generate),
    do: refute_receive({:req_llm_generate, _, _, _}, 0)

  defp refute_provider_call(:inline_model_generate),
    do: refute_receive({:inline_model_generate, _, _}, 0)

  defp refute_credential_canaries(value) do
    rendered = if is_binary(value), do: value, else: inspect(value, limit: :infinity)

    Enum.each(@credential_canaries, fn {_key, canary} ->
      refute rendered =~ canary, "credential canary leaked: #{canary}"
    end)
  end
end

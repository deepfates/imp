defmodule ProductionHardeningTest do
  use ExUnit.Case

  defmodule FlakyReqLLM do
    def generate_text(model, messages, _opts) do
      count = Process.get(:flaky_count, 0)
      Process.put(:flaky_count, count + 1)

      if count == 0 do
        {:error, :temporary_unavailable}
      else
        {:ok,
         %ReqLLM.Response{
           id: "resp_flaky",
           model: to_string(model),
           context: ReqLLM.Context.new(messages),
           message: ReqLLM.Context.assistant("Answer: recovered")
         }}
      end
    end
  end

  defmodule StableReqLLM do
    def generate_text(model, messages, _opts) do
      count = Process.get(:stable_count, 0)
      Process.put(:stable_count, count + 1)

      {:ok,
       %ReqLLM.Response{
         id: "resp_stable",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("Answer: recovered")
       }}
    end
  end

  defmodule TransientReqLLM do
    def generate_text(model, messages, _opts) do
      count = Process.get(:transient_error_count, 0)
      Process.put(:transient_error_count, count + 1)

      if count == 0 do
        {:error, :temporary_unavailable}
      else
        {:ok,
         %ReqLLM.Response{
           id: "resp_transient",
           model: to_string(model),
           context: ReqLLM.Context.new(messages),
           message: ReqLLM.Context.assistant("Answer: recovered")
         }}
      end
    end
  end

  defmodule PostOnlyTransport do
    def post(_url, _headers, _body, _opts), do: {:ok, %{status: 200, body: "ok", headers: []}}
  end

  defmodule RaisingHTTPTransport do
    def post(_url, _headers, _body, _opts), do: raise("post exploded")
  end

  defmodule RaisingStreamTransport do
    def stream(_url, _headers, _body, _opts), do: raise("stream exploded")
  end

  defmodule StructLM do
    defstruct [:prefix]

    def generate(%__MODULE__{prefix: prefix}, _messages, opts) do
      {:ok, "#{prefix}:#{Keyword.fetch!(opts, :suffix)}"}
    end
  end

  defmodule RaisingFormatAdapter do
    @behaviour DSEx.Adapter

    def format(_signature, _inputs, _opts), do: raise("format exploded")
    def parse(_signature, _raw, _opts), do: {:ok, DSEx.prediction(answer: "unused")}
  end

  defmodule RaisingLMOptsAdapter do
    @behaviour DSEx.Adapter

    def format(_signature, _inputs, _opts), do: [%{role: :user, content: "q"}]

    def parse(_signature, raw, _opts),
      do: DSEx.Adapter.Chat.parse(DSEx.signature("q -> answer"), raw, [])

    def lm_opts(_signature, _opts), do: raise("lm opts exploded")
  end

  defmodule InvalidLMOptsAdapter do
    @behaviour DSEx.Adapter

    def format(_signature, _inputs, _opts), do: [%{role: :user, content: "q"}]

    def parse(_signature, raw, _opts),
      do: DSEx.Adapter.Chat.parse(DSEx.signature("q -> answer"), raw, [])

    def lm_opts(_signature, _opts), do: %{response_format: %{type: "json_object"}}
  end

  test "ReqLLM-backed LM reports provider failures without caching them" do
    Process.delete(:flaky_count)

    lm = DSEx.req_llm("openai:gpt-test", req_module: FlakyReqLLM)
    program = DSEx.predict("question -> answer", lm: lm)

    assert {:error, :temporary_unavailable} =
             DSEx.Predict.Predict.call(program, %{question: "recover?"})

    assert {:ok, prediction} = DSEx.Predict.Predict.call(program, %{question: "recover?"})
    assert DSEx.Prediction.get(prediction, :answer) == "recovered"
    assert Process.get(:flaky_count) == 2
  end

  test "ReqLLM-backed LM supports content-addressed cache async calls and telemetry hooks" do
    DSEx.Cache.clear()
    Process.delete(:stable_count)

    ref =
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :lm, :start],
        [:dsex, :lm, :stop],
        [:dsex, :cache, :miss],
        [:dsex, :cache, :hit]
      ])

    lm = DSEx.req_llm("openai:gpt-test", req_module: StableReqLLM)

    messages = [%{role: :user, content: "cache me"}]

    assert {:ok, "Answer: recovered"} = DSEx.LM.generate(lm, messages, cache: true)
    assert {:ok, "Answer: recovered"} = DSEx.LM.generate(lm, messages, cache: true)
    assert Process.get(:stable_count) == 1

    task =
      DSEx.Clients.ReqLLM.generate_async(lm, [%{role: :user, content: "async"}], cache: false)

    assert {:ok, "Answer: recovered"} = Task.await(task)

    assert_received {^ref, [:dsex, :lm, :start], _, %{lm: %{model: "openai:gpt-test"}}}
    assert_received {^ref, [:dsex, :lm, :stop], %{duration: duration}, %{result: :ok}}
    assert_received {^ref, [:dsex, :cache, :miss], %{count: 1}, %{key: _}}
    assert_received {^ref, [:dsex, :cache, :hit], %{count: 1}, %{key: _}}
    assert is_integer(duration)
  after
    Process.delete(:stable_count)
  end

  test "ReqLLM cache does not store transient errors" do
    DSEx.Cache.clear()
    Process.delete(:transient_error_count)

    ref =
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :cache, :miss],
        [:dsex, :cache, :hit]
      ])

    lm = DSEx.req_llm("openai:gpt-test", req_module: TransientReqLLM)

    messages = [%{role: :user, content: "cache transient"}]

    assert {:error, :temporary_unavailable} = DSEx.LM.generate(lm, messages, cache: true)
    assert {:ok, "Answer: recovered"} = DSEx.LM.generate(lm, messages, cache: true)
    assert {:ok, "Answer: recovered"} = DSEx.LM.generate(lm, messages, cache: true)
    assert Process.get(:transient_error_count) == 2

    assert_received {^ref, [:dsex, :cache, :miss], _, _}
    assert_received {^ref, [:dsex, :cache, :hit], _, _}
  after
    Process.delete(:transient_error_count)
  end

  test "telemetry span emits redacted exception event for throws" do
    ref = DSEx.Test.TelemetryHelpers.attach([[:dsex, :span, :throw, :exception]])

    assert catch_throw(
             DSEx.Telemetry.span(
               [:dsex, :span, :throw],
               %{api_key: "sk-test-span-secret-1234567890", operation: :throw_probe},
               fn -> throw(:span_thrown) end
             )
           ) == :span_thrown

    assert_received {
      ^ref,
      [:dsex, :span, :throw, :exception],
      %{duration: duration},
      %{api_key: "[REDACTED]", operation: :throw_probe, error: "{:throw, :span_thrown}"}
    }

    assert is_integer(duration)
  end

  @tag capture_log: true
  test "default httpc transport verifies TLS peer certificates" do
    assert Keyword.fetch!(DSEx.HTTP.Hackneyless.default_ssl_opts(), :verify) == :verify_peer
    assert Keyword.fetch!(DSEx.HTTP.Hackneyless.http_opts([]), :timeout) == 15_000
    assert Keyword.fetch!(DSEx.HTTP.Hackneyless.http_opts(timeout: 123), :timeout) == 123

    assert Keyword.fetch!(DSEx.HTTP.Hackneyless.http_opts(timeout: 123), :connect_timeout) ==
             123

    assert Keyword.fetch!(
             DSEx.HTTP.Hackneyless.http_opts(http_opts: [timeout: 456]),
             :timeout
           ) == 456

    dir = Path.join(System.tmp_dir!(), "dsex-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    {_out, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key,
          "-out",
          cert,
          "-subj",
          "/CN=localhost",
          "-days",
          "1"
        ],
        stderr_to_stdout: true
      )

    {:ok, listen_socket} =
      :ssl.listen(0,
        certfile: String.to_charlist(cert),
        keyfile: String.to_charlist(key),
        active: false,
        packet: :raw,
        reuseaddr: true
      )

    {:ok, {_addr, port}} = :ssl.sockname(listen_socket)

    task =
      Task.async(fn ->
        case :ssl.transport_accept(listen_socket, 5_000) do
          {:ok, socket} ->
            case :ssl.handshake(socket) do
              {:ok, socket} ->
                :ssl.recv(socket, 0, 1_000)
                :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                :ssl.close(socket)

              {:error, _reason} ->
                :ok
            end

          {:error, _reason} ->
            :ok
        end
      end)

    assert {:error, _reason} =
             DSEx.HTTP.Hackneyless.post(
               "https://localhost:#{port}/",
               [],
               "{}",
               http_opts: [timeout: 2_000]
             )

    Task.await(task, 6_000)
    :ssl.close(listen_socket)
    File.rm_rf!(dir)
  end

  test "HTTP transport boundary rejects malformed options and unknown transports explicitly" do
    assert_raise ArgumentError, ~r/DSEx.HTTP.post\/5 expects keyword options/, fn ->
      DSEx.HTTP.post(PostOnlyTransport, "https://example.test", [], "{}", %{timeout: 1})
    end

    assert_raise ArgumentError, ~r/DSEx.HTTP.stream\/5 expects keyword options/, fn ->
      DSEx.HTTP.stream(PostOnlyTransport, "https://example.test", [], "{}", [:timeout])
    end

    assert {:error, {:not_http_transport, :not_a_transport}} =
             DSEx.HTTP.post(:not_a_transport, "https://example.test", [], "{}", [])

    assert {:error, {:http_transport_failed, RaisingHTTPTransport, "post exploded"}} =
             DSEx.HTTP.post(RaisingHTTPTransport, "https://example.test", [], "{}", [])

    assert {:error, {:http_transport_failed, :anonymous_http_transport, "post exploded"}} =
             DSEx.HTTP.post(
               fn _url, _headers, _body, _opts -> raise "post exploded" end,
               "https://example.test",
               [],
               "{}",
               []
             )

    assert [{:error, _reason}] =
             DSEx.HTTP.stream(
               DSEx.HTTP.Hackneyless,
               "http://127.0.0.1:1/",
               [],
               "{}",
               timeout: 1
             )
             |> Enum.to_list()

    assert [{:error, {:not_http_transport, :not_a_transport}}] =
             DSEx.HTTP.stream(:not_a_transport, "https://example.test", [], "{}", [])
             |> Enum.to_list()

    assert [{:error, {:http_transport_failed, RaisingStreamTransport, "stream exploded"}}] =
             DSEx.HTTP.stream(RaisingStreamTransport, "https://example.test", [], "{}", [])
             |> Enum.to_list()

    assert [{:error, {:http_transport_failed, :anonymous_http_transport, "post exploded"}}] =
             DSEx.HTTP.stream(
               fn _url, _headers, _body, _opts -> raise "post exploded" end,
               "https://example.test",
               [],
               "{}",
               []
             )
             |> Enum.to_list()

    assert ["ok"] =
             DSEx.HTTP.stream(PostOnlyTransport, "https://example.test", [], "{}", [])
             |> Enum.to_list()

    assert_raise ArgumentError,
                 ~r/DSEx.HTTP.Hackneyless.http_opts\/1 expects keyword options/,
                 fn -> DSEx.HTTP.Hackneyless.http_opts(%{timeout: 1}) end

    assert_raise ArgumentError,
                 ~r/DSEx.HTTP.Hackneyless.http_opts\/1 :http_opts expects a keyword list/,
                 fn -> DSEx.HTTP.Hackneyless.http_opts(http_opts: %{timeout: 1}) end
  end

  test "LM facade rejects malformed options and unknown providers explicitly" do
    assert_raise ArgumentError, ~r/DSEx.LM.generate\/3 expects keyword options/, fn ->
      DSEx.LM.generate(DSEx.LM.Static, [%{role: :user, content: "hello"}], %{handler: nil})
    end

    assert_raise ArgumentError,
                 ~r/DSEx.LM.generate\/3 client :opts expects keyword options/,
                 fn ->
                   DSEx.LM.generate(
                     %{module: DSEx.LM.Static, opts: %{handler: fn _messages, _opts -> "ok" end}},
                     [%{role: :user, content: "hello"}],
                     []
                   )
                 end

    assert {:error, {:not_an_lm, :not_an_lm}} =
             DSEx.LM.generate(:not_an_lm, [%{role: :user, content: "hello"}], [])

    assert {:error, {:not_an_lm, %{provider: :missing}}} =
             DSEx.LM.generate(%{provider: :missing}, [%{role: :user, content: "hello"}], [])

    assert {:ok, "static"} =
             DSEx.LM.generate(fn _messages, _opts -> {:ok, "static"} end, [], [])

    assert {:error, {:invalid_lm_result, :not_a_valid_lm_result}} =
             DSEx.LM.generate(fn _messages, _opts -> :not_a_valid_lm_result end, [], [])

    assert {:error, {:invalid_lm_result, :not_a_valid_lm_result}} =
             DSEx.LM.generate(
               fn _messages, _opts -> {:ok, :not_a_valid_lm_result} end,
               [],
               []
             )

    assert {:error, {:lm_failed, :anonymous_lm, "lm exploded"}} =
             DSEx.LM.generate(fn _messages, _opts -> raise "lm exploded" end, [], [])

    assert {:ok, "prefix:value"} =
             DSEx.LM.generate(%StructLM{prefix: "prefix"}, [], suffix: "value")
  end

  test "Predict reports adapter callback boundary failures explicitly" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}

    format_program = DSEx.predict("question -> answer", lm: lm, adapter: RaisingFormatAdapter)

    assert {:error, {:adapter_format_failed, RaisingFormatAdapter, "format exploded"}} =
             DSEx.Predict.Predict.call(format_program, %{question: "q"})

    lm_opts_program = DSEx.predict("question -> answer", lm: lm, adapter: RaisingLMOptsAdapter)

    assert {:error, {:adapter_lm_opts_failed, RaisingLMOptsAdapter, "lm opts exploded"}} =
             DSEx.Predict.Predict.call(lm_opts_program, %{question: "q"})

    invalid_opts_program =
      DSEx.predict("question -> answer", lm: lm, adapter: InvalidLMOptsAdapter)

    assert {:error, {:invalid_adapter_lm_opts, InvalidLMOptsAdapter, %{response_format: _}}} =
             DSEx.Predict.Predict.call(invalid_opts_program, %{question: "q"})

    unloaded_program =
      DSEx.predict("question -> answer", lm: lm, adapter: :"Elixir.MissingAdapter")

    assert {:error, {:adapter_not_loaded, :"Elixir.MissingAdapter", :nofile}} =
             DSEx.Predict.Predict.call(unloaded_program, %{question: "q"})
  end

  test "Static LM validates direct-call options and handler shape" do
    assert_raise ArgumentError, ~r/DSEx.LM.Static.generate\/2 expects keyword options/, fn ->
      DSEx.LM.Static.generate([], %{handler: fn _messages, _opts -> "ok" end})
    end

    assert {:error, {:lm_failed, DSEx.LM.Static, message}} =
             DSEx.LM.generate(DSEx.LM.Static, [], handler: :not_a_function)

    assert message =~ "DSEx.LM.Static.generate/2 expects :handler"
  end

  test "invalid test harness provider mode fails closed" do
    previous_mode = System.get_env("DSEX_TEST_MODE")

    try do
      System.put_env("DSEX_TEST_MODE", "garbage")
      assert_raise ArgumentError, ~r/unsupported DSEX_TEST_MODE/, fn -> DSEx.Test.Mode.mode() end
    after
      restore_env("DSEX_TEST_MODE", previous_mode)
    end
  end

  test "network-facing constructors reject unknown or malformed options" do
    callback = fn _url, _headers, _body, _opts ->
      {:ok, %{status: 200, body: "{}", headers: []}}
    end

    assert {:ok, ^callback} = DSEx.HTTP.validate_transport(callback)
    assert {:ok, String} = DSEx.HTTP.validate_transport(String)
    assert {:error, message} = DSEx.HTTP.validate_transport(fn _url -> :ok end)
    assert message =~ "expected an HTTP transport module or arity-4 callback"

    assert_raise ArgumentError, ~r/DSEx.Clients.ReqLLM\.new\/2 expects :req_module atom/, fn ->
      DSEx.req_llm("openai:gpt-test", req_module: "not-a-module")
    end

    assert_raise ArgumentError,
                 ~r/DSEx.Retrievers.HTTP\.new\/2: invalid value for :transport option: expected an HTTP transport module or arity-4 callback/,
                 fn ->
                   DSEx.Retrievers.HTTP.new("https://retriever.example/search",
                     transport: fn _url -> :ok end
                   )
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.MCP.HTTPClient\.new\/2: invalid value for :transport option: expected an HTTP transport module or arity-4 callback/,
                 fn ->
                   DSEx.MCP.HTTPClient.new("https://mcp.example", transport: %{bad: :transport})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.OpenAITrainer\.new\/1: invalid value for :transport option: expected an HTTP transport module or arity-4 callback/,
                 fn ->
                   DSEx.Clients.OpenAITrainer.new(transport: fn _url, _headers -> :ok end)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.MCP.StdioClient\.new\/2: invalid value for :timeout/,
                 fn ->
                   DSEx.MCP.StdioClient.new("/bin/cat", timeout: 0)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Retrievers.HTTP\.new\/2: invalid value for :body_builder/,
                 fn ->
                   DSEx.Retrievers.HTTP.new("https://retriever.example/search",
                     body_builder: :not_a_fun
                   )
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Clients.OpenAITrainer\.new\/1: unknown options \[:upload\]/,
                 fn ->
                   DSEx.Clients.OpenAITrainer.new(upload: true)
                 end
  end

  test "saving rejects unsupported program types explicitly" do
    assert_raise ArgumentError, ~r/unsupported saved DSEx program type/, fn ->
      DSEx.Saving.load(%{"type" => "unknown"})
    end

    react = DSEx.react("question -> answer", [])

    assert_raise ArgumentError,
                 ~r/unsupported DSEx program for saving: DSEx.Predict.ReAct/,
                 fn -> DSEx.Saving.dump(react) end
  end

  test "saving rejects malformed program artifacts with explicit errors" do
    assert_raise ArgumentError, ~r/saved DSEx program must be a map/, fn ->
      DSEx.Saving.load(["not", "a", "map"])
    end

    assert_raise ArgumentError, ~r/missing required key "type"/, fn ->
      DSEx.Saving.load(%{})
    end

    base = %{
      "type" => "predict",
      "signature" => DSEx.Signature.dump(DSEx.Signature.new("question -> answer")),
      "demos" => [],
      "config" => [],
      "metadata" => %{},
      "adapter" => "Elixir.DSEx.Adapter.Chat",
      "lm" => nil
    }

    assert_raise ArgumentError, ~r/missing required keys: \["signature"\]/, fn ->
      base |> Map.delete("signature") |> DSEx.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved DSEx demos must be a list/, fn ->
      base |> Map.put("demos", %{"bad" => true}) |> DSEx.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved DSEx demo must be a map or keyword list/, fn ->
      base |> Map.put("demos", ["bad"]) |> DSEx.Saving.load()
    end

    assert_raise ArgumentError, ~r/invalid saved DSEx config entry/, fn ->
      base |> Map.put("config", [:temperature]) |> DSEx.Saving.load()
    end

    assert_raise ArgumentError, ~r/invalid saved DSEx LM client/, fn ->
      base |> Map.put("lm", %{"model" => "missing-provider"}) |> DSEx.Saving.load()
    end

    assert_raise ArgumentError, ~r/invalid saved DSEx adapter reference/, fn ->
      base |> Map.put("adapter", %{"module" => "Elixir.DSEx.Adapter.Chat"}) |> DSEx.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved req_llm client is missing required key "model"/, fn ->
      base |> Map.put("lm", %{"provider" => "req_llm"}) |> DSEx.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved DSEx config must be a map or list/, fn ->
      base
      |> Map.put("lm", %{"provider" => "req_llm", "model" => "openai:gpt-test", "opts" => 1})
      |> DSEx.Saving.load()
    end
  end

  test "loading saved non-ReqLLM provider clients fails closed" do
    previous = System.get_env("OPENAI_API_KEY")
    Process.put(:previous_openai_api_key, previous)
    System.put_env("OPENAI_API_KEY", "sk-should-not-bind")

    state = %{
      "type" => "predict",
      "signature" => DSEx.Signature.dump(DSEx.Signature.new("question -> answer")),
      "demos" => [],
      "config" => [],
      "metadata" => %{},
      "adapter" => "Elixir.DSEx.Adapter.Chat",
      "lm" => %{
        "provider" => "openai",
        "model" => "gpt-test",
        "base_url" => "https://evil.example",
        "path" => "/chat/completions",
        "opts" => []
      }
    }

    assert_raise ArgumentError, ~r/saved provider clients must use req_llm/, fn ->
      DSEx.Saving.load(state)
    end
  after
    previous = Process.get(:previous_openai_api_key)

    if previous do
      System.put_env("OPENAI_API_KEY", previous)
    else
      System.delete_env("OPENAI_API_KEY")
    end

    Process.delete(:previous_openai_api_key)
  end

  test "saved adapter loading is allowlisted" do
    state = %{
      "type" => "predict",
      "signature" => DSEx.Signature.dump(DSEx.Signature.new("question -> answer")),
      "demos" => [],
      "config" => [],
      "metadata" => %{},
      "adapter" => "Elixir.String",
      "lm" => nil
    }

    assert_raise ArgumentError, ~r/unsupported saved DSEx adapter/, fn ->
      DSEx.Saving.load(state)
    end
  end

  test "prediction and program traces redact secret-shaped values" do
    secret = "sk-secretvalue123"

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{answer: "saw #{secret}"}
        end
      ]
    }

    program = DSEx.predict("question -> answer", lm: lm)
    assert {:ok, prediction} = DSEx.Predict.Predict.call(program, %{question: secret})
    trace_text = inspect(prediction.metadata.trace)
    refute trace_text =~ secret
    assert trace_text =~ "[REDACTED]"
  end

  test "ReAct CodeAct and RLM traces redact tool and observation secrets" do
    secret = "Bearer abcdefghijklmnop"

    react_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{
            tool_calls: [
              %{name: :leak, arguments: %{token: secret}},
              %{name: :submit, arguments: %{answer: "ok"}}
            ]
          }
        end
      ]
    }

    leak = DSEx.Tool.new(:leak, "leak", fn _args -> secret end)
    react = DSEx.Predict.ReAct.new("question -> answer", [leak], lm: react_lm)
    assert {:ok, react_prediction} = DSEx.Predict.ReAct.call(react, %{question: "q"})
    refute inspect(DSEx.Prediction.get(react_prediction, :history)) =~ secret

    code_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_redaction_actions)
          Process.put(:code_redaction_actions, rest)
          action
        end
      ]
    }

    code_tool = DSEx.Tool.new(:leak, "leak", fn _args -> secret end)

    Process.put(:code_redaction_actions, [%{tool: "leak", arguments: %{}}, %{program: ~s("done")}])

    code_act =
      DSEx.Predict.CodeAct.new("question -> answer", [code_tool], lm: code_lm, max_iters: 2)

    assert {:ok, code_prediction} = DSEx.Predict.CodeAct.call(code_act, %{question: "q"})
    refute inspect(code_prediction.metadata.code_act_trace) =~ secret

    rlm_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_redaction_actions)
          Process.put(:rlm_redaction_actions, rest)
          action
        end
      ]
    }

    Process.put(:rlm_redaction_actions, [
      %{action: "assign", name: "token", value: secret},
      %{action: "submit", result: %{answer: "ok"}}
    ])

    rlm = DSEx.Predict.RLM.new("question -> answer", lm: rlm_lm, max_iterations: 2)
    assert {:ok, rlm_prediction} = DSEx.Predict.RLM.call(rlm, %{question: "q"})
    refute inspect(rlm_prediction.metadata.rlm_trace) =~ secret
  after
    Process.delete(:code_redaction_actions)
    Process.delete(:rlm_redaction_actions)
  end

  test "tool telemetry redacts secret-shaped metadata" do
    ref = DSEx.Test.TelemetryHelpers.attach([[:dsex, :tool, :start]])

    tool = DSEx.Tool.new(:secret_tool, "echo", fn input -> input end)

    assert %{"api_key" => "sk-live-secret"} =
             DSEx.Tool.call(tool, %{"api_key" => "sk-live-secret"})

    assert_received {^ref, [:dsex, :tool, :start], _, metadata}
    assert metadata.arguments["api_key"] == "[REDACTED]"
  end

  test "redaction covers common compound secret keys" do
    redacted =
      DSEx.Redaction.redact(%{
        :access_token => "short-token",
        :client_secret => "short-secret",
        "x-api-key" => "short-key",
        :private_key => "private",
        :nested => %{refresh_token: "refresh"}
      })

    assert redacted.access_token == "[REDACTED]"
    assert redacted.client_secret == "[REDACTED]"
    assert redacted["x-api-key"] == "[REDACTED]"
    assert redacted.private_key == "[REDACTED]"
    assert redacted.nested.refresh_token == "[REDACTED]"
  end

  test "examples and predictions do not intern arbitrary external keys" do
    external_key = "external_key_#{System.unique_integer([:positive])}"

    example = DSEx.Example.new(%{external_key => "kept"})
    prediction = DSEx.Prediction.new(%{external_key => "kept"})

    assert DSEx.Example.to_map(example) == %{external_key => "kept"}
    assert DSEx.Example.get(example, external_key) == "kept"
    assert DSEx.Prediction.to_map(prediction) == %{external_key => "kept"}
    assert DSEx.Prediction.get(prediction, external_key) == "kept"

    assert_raise ArgumentError, fn -> String.to_existing_atom(external_key) end
  end

  test "signature parsing does not intern arbitrary external field names" do
    external_input = "external_input_#{System.unique_integer([:positive])}"
    external_output = "external_output_#{System.unique_integer([:positive])}"

    signature = DSEx.Signature.new("#{external_input} -> #{external_output}")

    assert DSEx.Signature.input_names(signature) == [external_input]
    assert DSEx.Signature.output_names(signature) == [external_output]

    assert {:ok, prediction} =
             DSEx.Adapter.Chat.parse(signature, %{external_output => "ok"}, [])

    assert DSEx.Prediction.get(prediction, external_output) == "ok"
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_input) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_output) end
  end

  test "optimize-anything report loading keeps unknown external metadata keys as strings" do
    external_key = "report_key_#{System.unique_integer([:positive])}"

    report =
      %{
        "type" => "optimize_anything_report",
        "best" => nil,
        "baseline" => nil,
        "candidates" => [],
        "errors" => [],
        "metadata" => %{external_key => "kept", "seed" => 1, "artifact_kind" => "prompt"}
      }
      |> DSEx.Optimize.Anything.Report.from_map()

    assert report.metadata[external_key] == "kept"
    assert report.metadata.seed == 1
    assert report.metadata.artifact_kind == :prompt
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_key) end
  end

  test "parallel maps preserve per-input success shape under concurrency" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    results =
      DSEx.Predict.Parallel.map(program, [
        %{question: "a"},
        %{question: "b"},
        %{question: "c"}
      ])

    assert Enum.all?(results, &match?({:ok, %DSEx.Prediction{}}, &1))
  end

  test "parallel map reports invalid options clearly" do
    program = DSEx.predict("question -> answer", lm: %{module: DSEx.LM.Static, opts: []})

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Parallel\.map\/3: expected keyword options/,
                 fn ->
                   DSEx.Predict.Parallel.map(program, [%{question: "a"}], :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Parallel\.map\/3 expects inputs to be an enumerable batch/,
                 fn ->
                   DSEx.Predict.Parallel.map(program, :not_a_batch)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Parallel\.map\/3: invalid value for :max_concurrency option: expected positive integer/,
                 fn ->
                   DSEx.Predict.Parallel.map(program, [%{question: "a"}], max_concurrency: 0)
                 end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

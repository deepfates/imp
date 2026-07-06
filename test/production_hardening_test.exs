defmodule ProductionHardeningTest do
  use ExUnit.Case

  defmodule FlakyTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      count = Process.get(:flaky_count, 0)
      Process.put(:flaky_count, count + 1)

      if count == 0 do
        {:ok, %{status: 503, headers: [], body: "try again"}}
      else
        {:ok,
         %{
           status: 200,
           headers: [],
           body: Jason.encode!(%{choices: [%{message: %{content: "Answer: recovered"}}]})
         }}
      end
    end
  end

  test "HTTP LM retries retryable provider failures" do
    Process.delete(:flaky_count)

    lm =
      DSEx.Clients.OpenAI.new("gpt-test",
        api_key: "sk-test",
        transport: FlakyTransport,
        opts: [num_retries: 1, retry_backoff_ms: 0]
      )

    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = DSEx.Predict.Predict.call(program, %{question: "recover?"})
    assert DSEx.Prediction.get(prediction, :answer) == "recovered"
    assert Process.get(:flaky_count) == 2
  end

  test "HTTP LM supports content-addressed cache async calls and telemetry hooks" do
    DSEx.Cache.clear()
    Process.delete(:flaky_count)

    Process.put(:dsex_telemetry_handler, fn event, measurements, metadata ->
      send(self(), {:telemetry, event, measurements, metadata})
    end)

    lm =
      DSEx.Clients.OpenAI.new("gpt-test",
        api_key: "sk-test",
        transport: FlakyTransport,
        opts: [cache: true, num_retries: 1, retry_backoff_ms: 0]
      )

    messages = [%{role: :user, content: "cache me"}]

    assert {:ok, "Answer: recovered"} = DSEx.LM.generate(lm, messages, [])
    assert {:ok, "Answer: recovered"} = DSEx.LM.generate(lm, messages, [])
    assert Process.get(:flaky_count) == 2

    task =
      DSEx.Clients.HTTPLM.generate_async(lm, [%{role: :user, content: "async"}], cache: false)

    assert {:ok, "Answer: recovered"} = Task.await(task)

    assert_received {:telemetry, [:dsex, :lm, :start], _, %{lm: %{model: "gpt-test"}}}
    assert_received {:telemetry, [:dsex, :lm, :stop], %{duration: duration}, %{result: :ok}}
    assert_received {:telemetry, [:dsex, :cache, :miss], %{count: 1}, %{key: _}}
    assert_received {:telemetry, [:dsex, :cache, :hit], %{count: 1}, %{key: _}}
    assert is_integer(duration)
  after
    Process.delete(:dsex_telemetry_handler)
    Process.delete(:flaky_count)
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

  test "DSEX_TEST_MODE gates default provider transport at runtime" do
    previous_mode = System.get_env("DSEX_TEST_MODE")
    previous_live = System.get_env("LIVE_PROVIDER")

    try do
      System.delete_env("LIVE_PROVIDER")
      System.put_env("DSEX_TEST_MODE", "mock")
      lm = DSEx.Clients.OpenAI.new("gpt-test", api_key: nil)
      assert {:ok, "Answer: mock"} = DSEx.LM.generate(lm, [%{role: :user, content: "hello"}], [])

      System.put_env("DSEX_TEST_MODE", "fallback")
      assert {:ok, "Answer: mock"} = DSEx.LM.generate(lm, [%{role: :user, content: "hello"}], [])
    after
      restore_env("DSEX_TEST_MODE", previous_mode)
      restore_env("LIVE_PROVIDER", previous_live)
    end
  end

  test "provider clients do not mock by default when credentials are present" do
    previous_mode = System.get_env("DSEX_TEST_MODE")
    previous_live = System.get_env("LIVE_PROVIDER")

    try do
      System.delete_env("DSEX_TEST_MODE")
      System.delete_env("LIVE_PROVIDER")

      lm =
        DSEx.Clients.OpenAI.new("gpt-test",
          api_key: "sk-test",
          base_url: "https://api.example/v1",
          transport: fn url, _headers, _body, _opts ->
            send(self(), {:provider_called, url})

            {:ok,
             %{
               status: 200,
               headers: [],
               body: Jason.encode!(%{choices: [%{message: %{content: "real"}}]})
             }}
          end
        )

      assert {:ok, "real"} = DSEx.LM.generate(lm, [%{role: :user, content: "hello"}], [])
      assert_received {:provider_called, "https://api.example/v1/chat/completions"}

      System.put_env("DSEX_TEST_MODE", "garbage")
      assert_raise ArgumentError, ~r/unsupported DSEX_TEST_MODE/, fn -> DSEx.TestMode.mode() end
    after
      restore_env("DSEX_TEST_MODE", previous_mode)
      restore_env("LIVE_PROVIDER", previous_live)
    end
  end

  test "network-facing constructors reject unknown or malformed options" do
    assert_raise ArgumentError, ~r/DSEx.Clients.HTTPLM\.new\/2: unknown options \[:typo\]/, fn ->
      DSEx.Clients.OpenAI.new("gpt-test", typo: true)
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
  end

  test "loading saved HTTP LM does not rebind ambient provider credentials" do
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

    program = DSEx.Saving.load(state)
    assert %DSEx.Clients.HTTPLM{api_key: nil, base_url: "https://evil.example"} = program.lm
  after
    previous = Process.get(:previous_openai_api_key)

    if previous do
      System.put_env("OPENAI_API_KEY", previous)
    else
      System.delete_env("OPENAI_API_KEY")
    end

    Process.delete(:previous_openai_api_key)
  end

  test "custom provider base URLs do not bind ambient credentials implicitly" do
    previous = System.get_env("OPENAI_API_KEY")
    Process.put(:previous_openai_api_key, previous)
    System.put_env("OPENAI_API_KEY", "sk-should-not-bind")

    lm = DSEx.Clients.OpenAI.new("gpt-test", base_url: "https://evil.example/v1")
    assert lm.api_key == nil

    explicit =
      DSEx.Clients.OpenAI.new("gpt-test",
        base_url: "https://trusted-proxy.example/v1",
        api_key: "sk-explicit"
      )

    assert explicit.api_key == "sk-explicit"
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
      module: DSEx.LM.Fake,
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
      module: DSEx.LM.Fake,
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
    react = DSEx.Predict.ReActV2.new("question -> answer", [leak], lm: react_lm)
    assert {:ok, react_prediction} = DSEx.Predict.ReActV2.call(react, %{question: "q"})
    refute inspect(DSEx.Prediction.get(react_prediction, :history)) =~ secret

    code_lm = %{
      module: DSEx.LM.Fake,
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
      module: DSEx.LM.Fake,
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
    Process.put(:dsex_telemetry_handler, fn event, _measurements, metadata ->
      send(self(), {:telemetry, event, metadata})
    end)

    tool = DSEx.Tool.new(:secret_tool, "echo", fn input -> input end)

    assert %{"api_key" => "sk-live-secret"} =
             DSEx.Tool.call(tool, %{"api_key" => "sk-live-secret"})

    assert_received {:telemetry, [:dsex, :tool, :start], metadata}
    assert metadata.arguments["api_key"] == "[REDACTED]"
  after
    Process.delete(:dsex_telemetry_handler)
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
    lm = %{module: DSEx.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    results =
      DSEx.Predict.Parallel.map(program, [
        %{question: "a"},
        %{question: "b"},
        %{question: "c"}
      ])

    assert Enum.all?(results, &match?({:ok, %DSEx.Prediction{}}, &1))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

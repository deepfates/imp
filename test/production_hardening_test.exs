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
    @behaviour Imp.Adapter

    def format(_signature, _inputs, _opts), do: raise("format exploded")
    def parse(_signature, _raw, _opts), do: {:ok, Imp.prediction(answer: "unused")}
  end

  defmodule RaisingLMOptsAdapter do
    @behaviour Imp.Adapter

    def format(_signature, _inputs, _opts), do: [%{role: :user, content: "q"}]

    def parse(_signature, raw, _opts),
      do: Imp.Adapter.Chat.parse(Imp.signature("q -> answer"), raw, [])

    def lm_opts(_signature, _opts), do: raise("lm opts exploded")
  end

  defmodule InvalidLMOptsAdapter do
    @behaviour Imp.Adapter

    def format(_signature, _inputs, _opts), do: [%{role: :user, content: "q"}]

    def parse(_signature, raw, _opts),
      do: Imp.Adapter.Chat.parse(Imp.signature("q -> answer"), raw, [])

    def lm_opts(_signature, _opts), do: %{response_format: %{type: "json_object"}}
  end

  test "ReqLLM-backed LM reports provider failures without caching them" do
    Process.delete(:flaky_count)

    lm = Imp.req_llm("openai:gpt-test", req_module: FlakyReqLLM)
    program = Imp.predict("question -> answer", lm: lm)

    assert {:error, :temporary_unavailable} =
             Imp.Predict.Predict.call(program, %{question: "recover?"})

    assert {:ok, prediction} = Imp.Predict.Predict.call(program, %{question: "recover?"})
    assert Imp.Prediction.get(prediction, :answer) == "recovered"
    assert Process.get(:flaky_count) == 2
  end

  test "ReqLLM-backed LM supports content-addressed cache async calls and telemetry hooks" do
    Imp.Cache.clear()
    Process.delete(:stable_count)

    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :lm, :start],
        [:imp, :lm, :stop],
        [:imp, :cache, :miss],
        [:imp, :cache, :hit]
      ])

    lm = Imp.req_llm("openai:gpt-test", req_module: StableReqLLM)

    messages = [%{role: :user, content: "cache me"}]

    assert_req_llm_output(Imp.LM.generate(lm, messages, cache: true), "Answer: recovered")
    assert_req_llm_output(Imp.LM.generate(lm, messages, cache: true), "Answer: recovered")
    assert Process.get(:stable_count) == 1

    task =
      Imp.Clients.ReqLLM.generate_async(lm, [%{role: :user, content: "async"}], cache: false)

    assert_req_llm_output(Task.await(task), "Answer: recovered")

    assert_received {^ref, [:imp, :lm, :start], _, %{lm: %{model: "openai:gpt-test"}}}
    assert_received {^ref, [:imp, :lm, :stop], %{duration: duration}, %{result: :ok}}
    assert_received {^ref, [:imp, :cache, :miss], %{count: 1}, %{key: _}}
    assert_received {^ref, [:imp, :cache, :hit], %{count: 1}, %{key: _}}
    assert is_integer(duration)
  after
    Process.delete(:stable_count)
  end

  test "ReqLLM cache does not store transient errors" do
    Imp.Cache.clear()
    Process.delete(:transient_error_count)

    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :cache, :miss],
        [:imp, :cache, :hit]
      ])

    lm = Imp.req_llm("openai:gpt-test", req_module: TransientReqLLM)

    messages = [%{role: :user, content: "cache transient"}]

    assert {:error, :temporary_unavailable} = Imp.LM.generate(lm, messages, cache: true)
    assert_req_llm_output(Imp.LM.generate(lm, messages, cache: true), "Answer: recovered")
    assert_req_llm_output(Imp.LM.generate(lm, messages, cache: true), "Answer: recovered")
    assert Process.get(:transient_error_count) == 2

    assert_received {^ref, [:imp, :cache, :miss], _, _}
    assert_received {^ref, [:imp, :cache, :hit], _, _}
  after
    Process.delete(:transient_error_count)
  end

  defp assert_req_llm_output(
         {:ok,
          %{
            __imp_lm_output__: output,
            __imp_lm_metadata__: %{req_llm: %{provider: "openai", model: "openai:gpt-test"}}
          }},
         expected
       ) do
    assert output == expected
  end

  test "telemetry span emits redacted exception event for throws" do
    ref = Imp.Test.TelemetryHelpers.attach([[:imp, :span, :throw, :exception]])

    assert catch_throw(
             Imp.Telemetry.span(
               [:imp, :span, :throw],
               %{api_key: "sk-test-span-secret-1234567890", operation: :throw_probe},
               fn -> throw(:span_thrown) end
             )
           ) == :span_thrown

    assert_received {
      ^ref,
      [:imp, :span, :throw, :exception],
      %{duration: duration},
      %{api_key: "[REDACTED]", operation: :throw_probe, error: "{:throw, :span_thrown}"}
    }

    assert is_integer(duration)
  end

  @tag capture_log: true
  test "default httpc transport verifies TLS peer certificates" do
    assert Keyword.fetch!(Imp.HTTP.Hackneyless.default_ssl_opts(), :verify) == :verify_peer
    assert Keyword.fetch!(Imp.HTTP.Hackneyless.http_opts([]), :timeout) == 15_000
    assert Keyword.fetch!(Imp.HTTP.Hackneyless.http_opts(timeout: 123), :timeout) == 123

    assert Keyword.fetch!(Imp.HTTP.Hackneyless.http_opts(timeout: 123), :connect_timeout) ==
             123

    assert Keyword.fetch!(
             Imp.HTTP.Hackneyless.http_opts(http_opts: [timeout: 456]),
             :timeout
           ) == 456

    dir = Path.join(System.tmp_dir!(), "imp-tls-#{System.unique_integer([:positive])}")
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
             Imp.HTTP.Hackneyless.post(
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
    assert_raise ArgumentError, ~r/Imp.HTTP.post\/5 expects keyword options/, fn ->
      Imp.HTTP.post(PostOnlyTransport, "https://example.test", [], "{}", %{timeout: 1})
    end

    assert_raise ArgumentError, ~r/Imp.HTTP.stream\/5 expects keyword options/, fn ->
      Imp.HTTP.stream(PostOnlyTransport, "https://example.test", [], "{}", [:timeout])
    end

    assert {:error, {:not_http_transport, :not_a_transport}} =
             Imp.HTTP.post(:not_a_transport, "https://example.test", [], "{}", [])

    assert {:error, {:http_transport_failed, RaisingHTTPTransport, "post exploded"}} =
             Imp.HTTP.post(RaisingHTTPTransport, "https://example.test", [], "{}", [])

    assert {:error, {:http_transport_failed, :anonymous_http_transport, "post exploded"}} =
             Imp.HTTP.post(
               fn _url, _headers, _body, _opts -> raise "post exploded" end,
               "https://example.test",
               [],
               "{}",
               []
             )

    assert [{:error, _reason}] =
             Imp.HTTP.stream(
               Imp.HTTP.Hackneyless,
               "http://127.0.0.1:1/",
               [],
               "{}",
               timeout: 1
             )
             |> Enum.to_list()

    assert [{:error, {:not_http_transport, :not_a_transport}}] =
             Imp.HTTP.stream(:not_a_transport, "https://example.test", [], "{}", [])
             |> Enum.to_list()

    assert [{:error, {:http_transport_failed, RaisingStreamTransport, "stream exploded"}}] =
             Imp.HTTP.stream(RaisingStreamTransport, "https://example.test", [], "{}", [])
             |> Enum.to_list()

    assert [{:error, {:http_transport_failed, :anonymous_http_transport, "post exploded"}}] =
             Imp.HTTP.stream(
               fn _url, _headers, _body, _opts -> raise "post exploded" end,
               "https://example.test",
               [],
               "{}",
               []
             )
             |> Enum.to_list()

    assert ["ok"] =
             Imp.HTTP.stream(PostOnlyTransport, "https://example.test", [], "{}", [])
             |> Enum.to_list()

    assert_raise ArgumentError,
                 ~r/Imp.HTTP.Hackneyless.http_opts\/1 expects keyword options/,
                 fn -> Imp.HTTP.Hackneyless.http_opts(%{timeout: 1}) end

    assert_raise ArgumentError,
                 ~r/Imp.HTTP.Hackneyless.http_opts\/1 :http_opts expects a keyword list/,
                 fn -> Imp.HTTP.Hackneyless.http_opts(http_opts: %{timeout: 1}) end
  end

  test "default HTTP transport honors an explicit multipart content type" do
    boundary = "imp-test-boundary"
    content_type = "multipart/form-data; boundary=#{boundary}"
    body = "--#{boundary}\r\ncontent\r\n--#{boundary}--\r\n"

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        assert request.headers["content-type"] == content_type
        assert request.body == body
        {200, %{ok: true}}
      end)

    assert {:ok, %{status: 200}} =
             Imp.HTTP.Hackneyless.post(
               base_url <> "/upload",
               [{"Content-Type", content_type}],
               body,
               []
             )
  end

  test "LM facade rejects malformed options and unknown providers explicitly" do
    assert_raise ArgumentError, ~r/Imp.LM.generate\/3 expects keyword options/, fn ->
      Imp.LM.generate(Imp.LM.Static, [%{role: :user, content: "hello"}], %{handler: nil})
    end

    assert_raise ArgumentError,
                 ~r/Imp.LM.generate\/3 client :opts expects keyword options/,
                 fn ->
                   Imp.LM.generate(
                     %{module: Imp.LM.Static, opts: %{handler: fn _messages, _opts -> "ok" end}},
                     [%{role: :user, content: "hello"}],
                     []
                   )
                 end

    assert {:error, {:not_an_lm, :not_an_lm}} =
             Imp.LM.generate(:not_an_lm, [%{role: :user, content: "hello"}], [])

    assert {:error, {:not_an_lm, %{provider: :missing}}} =
             Imp.LM.generate(%{provider: :missing}, [%{role: :user, content: "hello"}], [])

    assert {:ok, "static"} =
             Imp.LM.generate(fn _messages, _opts -> {:ok, "static"} end, [], [])

    assert {:error, {:invalid_lm_result, :not_a_valid_lm_result}} =
             Imp.LM.generate(fn _messages, _opts -> :not_a_valid_lm_result end, [], [])

    assert {:error, {:invalid_lm_result, :not_a_valid_lm_result}} =
             Imp.LM.generate(
               fn _messages, _opts -> {:ok, :not_a_valid_lm_result} end,
               [],
               []
             )

    assert {:error, {:lm_failed, :anonymous_lm, "lm exploded"}} =
             Imp.LM.generate(fn _messages, _opts -> raise "lm exploded" end, [], [])

    assert {:ok, "prefix:value"} =
             Imp.LM.generate(%StructLM{prefix: "prefix"}, [], suffix: "value")
  end

  test "Predict reports adapter callback boundary failures explicitly" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}

    format_program = Imp.predict("question -> answer", lm: lm, adapter: RaisingFormatAdapter)

    assert {:error, {:adapter_format_failed, RaisingFormatAdapter, "format exploded"}} =
             Imp.Predict.Predict.call(format_program, %{question: "q"})

    lm_opts_program = Imp.predict("question -> answer", lm: lm, adapter: RaisingLMOptsAdapter)

    assert {:error, {:adapter_lm_opts_failed, RaisingLMOptsAdapter, "lm opts exploded"}} =
             Imp.Predict.Predict.call(lm_opts_program, %{question: "q"})

    invalid_opts_program =
      Imp.predict("question -> answer", lm: lm, adapter: InvalidLMOptsAdapter)

    assert {:error, {:invalid_adapter_lm_opts, InvalidLMOptsAdapter, %{response_format: _}}} =
             Imp.Predict.Predict.call(invalid_opts_program, %{question: "q"})

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2: invalid value for :adapter option: expected an adapter module exporting format\/3 and parse\/3/,
                 fn ->
                   Imp.predict("question -> answer", lm: lm, adapter: :"Elixir.MissingAdapter")
                 end
  end

  test "Static LM validates direct-call options and handler shape" do
    assert_raise ArgumentError, ~r/Imp.LM.Static.generate\/2 expects keyword options/, fn ->
      Imp.LM.Static.generate([], %{handler: fn _messages, _opts -> "ok" end})
    end

    assert {:error, {:lm_failed, Imp.LM.Static, message}} =
             Imp.LM.generate(Imp.LM.Static, [], handler: :not_a_function)

    assert message =~ "Imp.LM.Static.generate/2 expects :handler"
  end

  test "invalid test harness provider mode fails closed" do
    previous_mode = System.get_env("IMP_TEST_MODE")

    try do
      System.put_env("IMP_TEST_MODE", "garbage")
      assert_raise ArgumentError, ~r/unsupported IMP_TEST_MODE/, fn -> Imp.Test.Mode.mode() end
    after
      restore_env("IMP_TEST_MODE", previous_mode)
    end
  end

  test "network-facing constructors reject unknown or malformed options" do
    callback = fn _url, _headers, _body, _opts ->
      {:ok, %{status: 200, body: "{}", headers: []}}
    end

    assert {:ok, ^callback} = Imp.HTTP.validate_transport(callback)
    assert {:ok, String} = Imp.HTTP.validate_transport(String)
    assert {:error, message} = Imp.HTTP.validate_transport(fn _url -> :ok end)
    assert message =~ "expected an HTTP transport module or arity-4 callback"
    assert {:ok, nil} = Imp.LM.validate_lm(nil)
    assert {:ok, Imp.LM.Static} = Imp.LM.validate_lm(Imp.LM.Static)
    assert {:ok, Imp.Adapter.Chat} = Imp.Adapter.validate_adapter(Imp.Adapter.Chat)
    assert {:error, message} = Imp.LM.validate_lm(%{provider: :missing})
    assert message =~ "expected nil, an LM module"
    assert {:error, message} = Imp.Adapter.validate_adapter(String)
    assert message =~ "expected an adapter module exporting format/3 and parse/3"

    assert {:ok, ReqLLM} = Imp.Clients.ReqLLM.validate_req_module(ReqLLM)
    assert {:error, message} = Imp.Clients.ReqLLM.validate_req_module("not-a-module")
    assert message =~ "expected a ReqLLM-compatible module atom"

    assert_raise ArgumentError,
                 ~r/Imp.Clients.ReqLLM\.new\/2: invalid value for :req_module option: expected a ReqLLM-compatible module atom/,
                 fn ->
                   Imp.req_llm("openai:gpt-test", req_module: "not-a-module")
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2: invalid value for :lm option: expected nil, an LM module/,
                 fn ->
                   Imp.predict("question -> answer", lm: %{provider: :missing})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2: invalid value for :adapter option: expected an adapter module exporting format\/3 and parse\/3/,
                 fn ->
                   Imp.predict("question -> answer", adapter: String)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Retrievers.HTTP\.new\/2: invalid value for :transport option: expected an HTTP transport module or arity-4 callback/,
                 fn ->
                   Imp.Retrievers.HTTP.new("https://retriever.example/search",
                     transport: fn _url -> :ok end
                   )
                 end

    assert_raise ArgumentError,
                 ~r/Imp.MCP.HTTPClient\.new\/2: invalid value for :transport option: expected an HTTP transport module or arity-4 callback/,
                 fn ->
                   Imp.MCP.HTTPClient.new("https://mcp.example", transport: %{bad: :transport})
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.OpenAITrainer\.new\/1: invalid value for :transport option: expected an HTTP transport module or arity-4 callback/,
                 fn ->
                   Imp.Clients.OpenAITrainer.new(transport: fn _url, _headers -> :ok end)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.MCP.StdioClient\.new\/2: invalid value for :timeout/,
                 fn ->
                   Imp.MCP.StdioClient.new("/bin/cat", timeout: 0)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Retrievers.HTTP\.new\/2: invalid value for :body_builder/,
                 fn ->
                   Imp.Retrievers.HTTP.new("https://retriever.example/search",
                     body_builder: :not_a_fun
                   )
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Clients.OpenAITrainer\.new\/1: unknown options \[:upload\]/,
                 fn ->
                   Imp.Clients.OpenAITrainer.new(upload: true)
                 end
  end

  test "saving rejects unsupported program types explicitly" do
    assert_raise ArgumentError, ~r/unsupported saved Imp program type/, fn ->
      Imp.Saving.load(%{"type" => "unknown"})
    end

    error =
      assert_raise ArgumentError, fn ->
        Imp.Saving.dump(%URI{scheme: "https", host: "example.com"})
      end

    assert error.message =~ "unsupported Imp program for saving: URI"
    assert error.message =~ "data-only program graphs"
    assert error.message =~ "callback-bearing programs require named registries"
  end

  test "saving rejects malformed program artifacts with explicit errors" do
    assert_raise ArgumentError, ~r/saved Imp program must be a map/, fn ->
      Imp.Saving.load(["not", "a", "map"])
    end

    assert_raise ArgumentError, ~r/missing required key "type"/, fn ->
      Imp.Saving.load(%{})
    end

    base = %{
      "type" => "predict",
      "signature" => Imp.Signature.dump(Imp.Signature.new("question -> answer")),
      "demos" => [],
      "config" => [],
      "metadata" => %{},
      "adapter" => "Elixir.Imp.Adapter.Chat",
      "lm" => nil
    }

    assert_raise ArgumentError, ~r/missing required keys: \["signature"\]/, fn ->
      base |> Map.delete("signature") |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved Imp demos must be a list/, fn ->
      base |> Map.put("demos", %{"bad" => true}) |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved Imp demo must be a map or keyword list/, fn ->
      base |> Map.put("demos", ["bad"]) |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/invalid saved Imp config entry/, fn ->
      base |> Map.put("config", [:temperature]) |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/invalid saved Imp LM client/, fn ->
      base |> Map.put("lm", %{"model" => "missing-provider"}) |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/invalid saved Imp adapter reference/, fn ->
      base |> Map.put("adapter", %{"module" => "Elixir.Imp.Adapter.Chat"}) |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved req_llm client is missing required key "model"/, fn ->
      base |> Map.put("lm", %{"provider" => "req_llm"}) |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved Imp program_of_thought is missing required keys/, fn ->
      Imp.Saving.load(%{
        "type" => "program_of_thought",
        "signature" => Imp.Signature.dump(Imp.Signature.new("x -> answer")),
        "output_field" => %{"__imp_type__" => "atom", "value" => "answer"}
      })
    end

    pot_state =
      "x -> answer"
      |> Imp.program_of_thought()
      |> Imp.Saving.dump()

    rag_state =
      "x, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "x"}]))
      |> Imp.Saving.dump()

    assert_raise ArgumentError, ~r/nested predict must be a saved Predict program/, fn ->
      pot_state |> Map.put("predict", rag_state) |> Imp.Saving.load()
    end

    mismatched_instruction =
      update_in(pot_state, ["predict", "signature", "instructions"], fn _instruction ->
        "Different planner instruction."
      end)

    assert_raise ArgumentError, ~r/planner instructions must match task instructions/, fn ->
      Imp.Saving.load(mismatched_instruction)
    end

    bad_planner_outputs =
      update_in(pot_state, ["predict", "signature"], fn _signature ->
        Imp.Signature.dump(Imp.Signature.new("x -> answer"))
      end)

    assert_raise ArgumentError, ~r/planner outputs must be \[:program, :tool, :arguments\]/, fn ->
      Imp.Saving.load(bad_planner_outputs)
    end

    assert_raise ArgumentError, ~r/output_field must name one of the task outputs/, fn ->
      pot_state
      |> Map.put("output_field", %{"__imp_type__" => "atom", "value" => "missing"})
      |> Imp.Saving.load()
    end

    assert_raise ArgumentError, ~r/saved Imp config must be a map or list/, fn ->
      base
      |> Map.put("lm", %{"provider" => "req_llm", "model" => "openai:gpt-test", "opts" => 1})
      |> Imp.Saving.load()
    end
  end

  test "loading saved non-ReqLLM provider clients fails closed" do
    previous = System.get_env("OPENAI_API_KEY")
    Process.put(:previous_openai_api_key, previous)
    System.put_env("OPENAI_API_KEY", "sk-should-not-bind")

    state = %{
      "type" => "predict",
      "signature" => Imp.Signature.dump(Imp.Signature.new("question -> answer")),
      "demos" => [],
      "config" => [],
      "metadata" => %{},
      "adapter" => "Elixir.Imp.Adapter.Chat",
      "lm" => %{
        "provider" => "openai",
        "model" => "gpt-test",
        "base_url" => "https://evil.example",
        "path" => "/chat/completions",
        "opts" => []
      }
    }

    assert_raise ArgumentError, ~r/saved provider clients must use req_llm/, fn ->
      Imp.Saving.load(state)
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
      "signature" => Imp.Signature.dump(Imp.Signature.new("question -> answer")),
      "demos" => [],
      "config" => [],
      "metadata" => %{},
      "adapter" => "Elixir.String",
      "lm" => nil
    }

    assert_raise ArgumentError, ~r/unsupported saved Imp adapter/, fn ->
      Imp.Saving.load(state)
    end
  end

  test "prediction and program traces redact secret-shaped values" do
    secret = "sk-secretvalue123"

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{answer: "saw #{secret}"}
        end
      ]
    }

    program = Imp.predict("question -> answer", lm: lm)
    assert {:ok, prediction} = Imp.Predict.Predict.call(program, %{question: secret})
    trace_text = inspect(prediction.metadata.trace)
    refute trace_text =~ secret
    assert trace_text =~ "[REDACTED]"
  end

  test "ReAct CodeAct and RLM traces redact tool and observation secrets" do
    secret = "Bearer abcdefghijklmnop"

    react_lm = %{
      module: Imp.LM.Static,
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

    leak = Imp.Tool.new(:leak, "leak", fn _args -> secret end)
    react = Imp.Predict.ReAct.new("question -> answer", [leak], lm: react_lm)
    assert {:ok, react_prediction} = Imp.Predict.ReAct.call(react, %{question: "q"})
    refute inspect(Imp.Prediction.get(react_prediction, :history)) =~ secret

    code_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_redaction_actions)
          Process.put(:code_redaction_actions, rest)
          action
        end
      ]
    }

    code_tool = Imp.Tool.new(:leak, "leak", fn _args -> secret end)

    Process.put(:code_redaction_actions, [%{tool: "leak", arguments: %{}}, %{program: ~s("done")}])

    code_act =
      Imp.Predict.CodeAct.new("question -> answer", [code_tool], lm: code_lm, max_iters: 2)

    assert {:ok, code_prediction} = Imp.Predict.CodeAct.call(code_act, %{question: "q"})
    refute inspect(code_prediction.metadata.code_act_trace) =~ secret

    rlm_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_redaction_actions)
          Process.put(:rlm_redaction_actions, rest)
          action
        end
      ]
    }

    Process.put(:rlm_redaction_actions, [
      %{code: "token = #{inspect(secret)}"},
      %{code: ~S|submit(%{answer: "ok"})|}
    ])

    rlm = Imp.Predict.RLM.new("question -> answer", lm: rlm_lm, max_iterations: 2)
    assert {:ok, rlm_prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    refute inspect(rlm_prediction.metadata.rlm_trace) =~ secret
  after
    Process.delete(:code_redaction_actions)
    Process.delete(:rlm_redaction_actions)
  end

  test "tool telemetry redacts secret-shaped metadata" do
    ref = Imp.Test.TelemetryHelpers.attach([[:imp, :tool, :start]])

    tool = Imp.Tool.new(:secret_tool, "echo", fn input -> input end)

    assert %{"api_key" => "sk-live-secret"} =
             Imp.Tool.call(tool, %{"api_key" => "sk-live-secret"})

    assert_received {^ref, [:imp, :tool, :start], _, metadata}
    assert metadata.arguments["api_key"] == "[REDACTED]"
  end

  test "redaction covers common compound secret keys" do
    redacted =
      Imp.Redaction.redact(%{
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

  test "redaction key policy accepts only atom or string key names" do
    assert {:ok, [:api_key, "authorization"]} =
             Imp.Redaction.validate_keys([:api_key, "authorization"])

    assert {:error, message} = Imp.Redaction.validate_keys([:api_key, {:tuple, :key}])
    assert message =~ "expected a list of atom or string key names"

    assert {:error, message} = Imp.Redaction.validate_keys(:api_key)
    assert message =~ "expected a list of atom or string key names"
  end

  test "examples and predictions do not intern arbitrary external keys" do
    external_key = "external_key_#{System.unique_integer([:positive])}"

    example = Imp.Example.new(%{external_key => "kept"})
    prediction = Imp.Prediction.new(%{external_key => "kept"})

    assert Imp.Example.to_map(example) == %{external_key => "kept"}
    assert Imp.Example.get(example, external_key) == "kept"
    assert Imp.Prediction.to_map(prediction) == %{external_key => "kept"}
    assert Imp.Prediction.get(prediction, external_key) == "kept"

    assert_raise ArgumentError, fn -> String.to_existing_atom(external_key) end
  end

  test "signature parsing does not intern arbitrary external field names" do
    external_input = "external_input_#{System.unique_integer([:positive])}"
    external_output = "external_output_#{System.unique_integer([:positive])}"

    signature = Imp.Signature.new("#{external_input} -> #{external_output}")

    assert Imp.Signature.input_names(signature) == [external_input]
    assert Imp.Signature.output_names(signature) == [external_output]

    assert {:ok, prediction} =
             Imp.Adapter.Chat.parse(signature, %{external_output => "ok"}, [])

    assert Imp.Prediction.get(prediction, external_output) == "ok"
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_input) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_output) end
  end

  test "parallel maps preserve per-input success shape under concurrency" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}
    program = Imp.predict("question -> answer", lm: lm)

    results =
      Imp.Predict.Parallel.map(program, [
        %{question: "a"},
        %{question: "b"},
        %{question: "c"}
      ])

    assert Enum.all?(results, &match?({:ok, %Imp.Prediction{}}, &1))
  end

  test "parallel map reports invalid options clearly" do
    program = Imp.predict("question -> answer", lm: %{module: Imp.LM.Static, opts: []})

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Parallel\.map\/3: expected keyword options/,
                 fn ->
                   Imp.Predict.Parallel.map(program, [%{question: "a"}], :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Parallel\.map\/3 expects inputs to be an enumerable batch/,
                 fn ->
                   Imp.Predict.Parallel.map(program, :not_a_batch)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Parallel\.map\/3: invalid value for :max_concurrency option: expected positive integer/,
                 fn ->
                   Imp.Predict.Parallel.map(program, [%{question: "a"}], max_concurrency: 0)
                 end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

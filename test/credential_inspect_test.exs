defmodule CredentialInspectTest do
  use ExUnit.Case, async: true

  # A struct that can hold a credential prints without it: in IEx, in a log
  # line, in a crash report. Each case below builds one with a secret and
  # inspects it, and the program and trace cases check the places an LM struct
  # travels to. The secret does not look like one, so what hides it is the
  # place it sits (a key's name, a header, a URL's query), not its shape.

  @secret "FAKE-SECRET-123"

  defmodule Stub do
    def generate_text(model, messages, _opts) do
      {:ok,
       %ReqLLM.Response{
         id: "resp",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("[[ ## answer ## ]]\npong\n\n[[ ## completed ## ]]"),
         object: nil
       }}
    end
  end

  defp printed(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp lm, do: Imp.req_llm("openai:gpt-4o-mini", api_key: @secret, req_module: Stub)

  test "no credential-bearing struct prints its secret" do
    bearer = [{"authorization", "Bearer " <> @secret}]
    # Header names that say nothing about credentials: every header value is
    # hidden, whatever its name.
    headers =
      for name <- ~w(X-Subscription-Token Ocp-Apim-Subscription-Key Cookie X-Vault-Token),
          do: {name, @secret}

    structs = [
      lm(),
      Imp.req_llm("openai:gpt-4o-mini", req_http_options: [headers: bearer]),
      Imp.req_llm("openai:gpt-4o-mini", provider_options: [api_key: @secret]),
      Imp.predict("question -> answer", lm: lm()),
      Imp.Retrievers.HTTP.new("https://retriever.test", headers: bearer),
      Imp.Retrievers.Databricks.new("https://db.test/index", token: @secret),
      Imp.Retrievers.Weaviate.new("https://weaviate.test", "Doc", headers: bearer),
      Imp.rag(
        Imp.predict("context, question -> answer"),
        Imp.Retrievers.Databricks.new("https://db.test/index", token: @secret)
      ),
      struct(Imp.Tracking.MLflow, headers: bearer),
      struct(Imp.Tracking.WandB, authorization: "Basic " <> @secret),
      Imp.Optimize.Anything.Config.Tracking.new(wandb_api_key: @secret),
      struct(Imp.Clients.HTTPTrainer, api_key: @secret, headers: bearer),
      struct(Imp.Clients.TrainingJob, api_key: @secret),
      Imp.req_llm("openai:gpt-4o-mini", req_http_options: [headers: headers]),
      Imp.req_llm("openai:gpt-4o-mini", headers: headers),
      Imp.req_llm("openai:gpt-4o-mini", base_url: "https://llm.test/v1?key=" <> @secret),
      Imp.req_llm("openai:gpt-4o-mini", base_url: "https://llm.test/v1#" <> @secret),
      Imp.req_llm("openai:gpt-4o-mini",
        base_url: URI.parse("https://u:" <> @secret <> "@llm.test/v1?key=" <> @secret)
      ),
      Imp.Retrievers.HTTP.new("https://retriever.test", headers: headers),
      Imp.Retrievers.HTTP.new("https://retriever.test/search?token=" <> @secret),
      struct(Imp.Tracking.MLflow, headers: headers)
    ]

    leaking = for struct <- structs, printed(struct) =~ @secret, do: struct.__struct__
    assert leaking == []
  end

  test "refusing to save a retriever does not print it" do
    program =
      Imp.rag(
        Imp.predict("context, question -> answer"),
        Imp.Retrievers.Databricks.new("https://db.test/index", token: @secret)
      )

    path = Path.join(System.tmp_dir!(), "credential-#{System.unique_integer([:positive])}.json")
    error = assert_raise ArgumentError, fn -> Imp.save!(program, path) end
    refute error.message =~ @secret
    assert error.message =~ "Imp.Retrievers.HTTP"
  end

  test "neither a saved program nor a trace of its call carries the LM's credential" do
    program = Imp.predict("question -> answer", lm: lm())
    path = Path.join(System.tmp_dir!(), "credential-#{System.unique_integer([:positive])}.json")

    try do
      Imp.save!(program, path)
      refute File.read!(path) =~ @secret
    after
      File.rm(path)
    end

    trace = Imp.trace(fn -> Imp.call(program, %{question: "ping"}) end)
    assert {:ok, _prediction} = trace.result
    assert trace.events != []
    refute printed(trace) =~ @secret
  end

  test "a header's name still shows, so a reader can see what was sent" do
    printed = printed(Imp.req_llm("m", req_http_options: [headers: [{"X-Vault-Token", @secret}]]))
    assert printed =~ "X-Vault-Token"
    refute printed =~ @secret
  end

  test "a saved program holds no header value and no URL query" do
    for opts <- [
          [req_http_options: [headers: [{"X-Subscription-Token", @secret}]]],
          [headers: [{"Cookie", "session=" <> @secret}]]
        ] do
      program = Imp.predict("question -> answer", lm: Imp.req_llm("openai:gpt-4o-mini", opts))
      path = Path.join(System.tmp_dir!(), "credential-#{System.unique_integer([:positive])}.json")

      try do
        Imp.save!(program, path)
        refute File.read!(path) =~ @secret
      after
        File.rm(path)
      end
    end

    for base_url <- [
          "https://llm.test/v1?key=" <> @secret,
          "https://llm.test/v1#" <> @secret,
          URI.parse("https://llm.test/v1?key=" <> @secret)
        ] do
      lm = Imp.req_llm("openai:gpt-4o-mini", base_url: base_url)
      path = Path.join(System.tmp_dir!(), "credential-#{System.unique_integer([:positive])}.json")
      error = assert_raise ArgumentError, fn -> Imp.save!(Imp.predict("q -> a", lm: lm), path) end
      assert error.message =~ "base_url"
      refute error.message =~ @secret
      refute File.exists?(path)
    end
  end

  test "an option error names the key and does not print the value" do
    messages = [%{role: "user", content: "x"}]

    for fun <- [
          fn -> Imp.req_llm("m", %{api_key: @secret}) end,
          fn ->
            Imp.Retrievers.HTTP.new("https://r.test", headers: %{"authorization" => @secret})
          end,
          fn ->
            Imp.Retrievers.Databricks.new("https://r.test", token: String.to_charlist(@secret))
          end,
          fn -> Imp.Optimize.Anything.run(:not_a_seed, nil, wandb_api_key: @secret) end,
          fn -> Imp.LM.generate(lm(), messages, %{api_key: @secret}) end,
          fn -> Imp.Clients.ReqLLM.generate(lm(), messages, %{api_key: @secret}) end,
          fn -> Imp.Clients.ReqLLM.generate(lm(), messages, [{"authorization", @secret}]) end,
          fn ->
            Imp.predict("q -> a", lm: lm())
            |> Imp.Streaming.stream(%{q: "x"}, %{api_key: @secret})
            |> Enum.to_list()
          end
        ] do
      error = assert_raise ArgumentError, fun
      refute error.message =~ @secret
    end
  end

  # ExMCP keeps an HTTP connection's headers in its client process state, which
  # a crash report prints.
  test "an MCP client's crash report does not print its transport headers" do
    headers = [{"Authorization", "Bearer " <> @secret}, {"X-Subscription-Token", @secret}]
    transport = struct(ExMCP.Transport.HTTP, base_url: "http://mcp.test", headers: headers)
    client = struct(ExMCP.Client, transport_state: transport, transport_opts: [headers: headers])

    refute printed(transport) =~ @secret
    refute printed(client) =~ @secret
    assert printed(transport) =~ "X-Subscription-Token"

    Process.flag(:trap_exit, true)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} = Agent.start_link(fn -> client end)
        :sys.terminate(pid, :crash)
        # The exit always arrives, but a loaded CI runner can take longer than
        # the default 100 ms to deliver it.
        assert_receive {:EXIT, ^pid, :crash}, 2_000
        Process.sleep(100)
      end)

    assert log =~ "ExMCP.Client"
    refute log =~ @secret
  end
end

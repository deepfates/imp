defmodule RetrieverHTTPRecoveryTest do
  use ExUnit.Case

  defmodule PolicyTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, opts) do
      Agent.get_and_update(opts[:script], fn
        [response | rest] -> {response, rest}
      end)
    end
  end

  defmodule BlockingTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, opts) do
      send(opts[:test_owner], {:attempt_started, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule TimeoutThenSuccessTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(_url, _headers, _body, opts) do
      Agent.get_and_update(opts[:script], fn
        [:timeout | rest] ->
          {{:error, :timeout}, rest}

        [:success | rest] ->
          {{:ok, %{status: 200, headers: [], body: ~s({"documents":[]})}}, rest}
      end)
    end
  end

  test "retries scripted local transient statuses with one stable request identity" do
    {:ok, requests} = Agent.start_link(fn -> [] end)
    {:ok, faults} = Agent.start_link(fn -> [503, 429, 200] end)

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        Agent.update(requests, &[request | &1])
        status = Agent.get_and_update(faults, fn [next | rest] -> {next, rest} end)

        {status,
         if(status == 200, do: %{documents: [%{text: "recovered"}]}, else: %{error: "transient"})}
      end)

    retriever =
      Imp.Retrievers.HTTP.new(base_url <> "/retrieve",
        max_attempts: 3,
        retry_backoff_ms: 0
      )

    assert {:ok, [%{text: "recovered"}]} = Imp.Retrieve.retrieve(retriever, "secret query")

    requests = requests |> Agent.get(&Enum.reverse/1)
    assert length(requests) == 3

    assert [request_id] =
             requests
             |> Enum.map(& &1.headers["idempotency-key"])
             |> Enum.uniq()

    assert String.starts_with?(request_id, "imp-retrieval-")
  end

  test "Retry-After and injected backoff are deterministic and policy bounded" do
    {:ok, script} =
      Agent.start_link(fn ->
        [
          {:ok, %{status: 429, headers: [{"Retry-After", "60"}], body: ~s({"error":"busy"})}},
          {:ok, %{status: 200, headers: [], body: ~s({"documents":[]})}}
        ]
      end)

    owner = self()

    retriever =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: PolicyTransport,
        max_attempts: 2,
        retry_backoff_ms: fn attempt ->
          send(owner, {:backoff_attempt, attempt})
          7
        end,
        max_retry_delay_ms: 25,
        sleep_fun: fn delay -> send(owner, {:retry_sleep, delay}) end
      )

    assert {:ok, []} = Imp.Retrieve.retrieve(retriever, "query", script: script)
    assert_received {:backoff_attempt, 1}
    assert_received {:retry_sleep, 25}
  end

  test "retries selected transient transport failures" do
    {:ok, script} = Agent.start_link(fn -> [:timeout, :success] end)

    retriever =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: TimeoutThenSuccessTransport,
        max_attempts: 2,
        retry_backoff_ms: 0
      )

    assert {:ok, []} = Imp.Retrieve.retrieve(retriever, "query", script: script)
    assert [] = Agent.get(script, & &1)
  end

  test "does not retry semantic statuses or malformed successful bodies" do
    {:ok, semantic_script} =
      Agent.start_link(fn ->
        [
          {:ok, %{status: 400, headers: [], body: ~s({"error":"bad query"})}},
          {:ok, %{status: 200, headers: [], body: ~s({"documents":[]})}}
        ]
      end)

    retriever =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: PolicyTransport,
        retry_backoff_ms: 0
      )

    assert {:error, {:retriever_http_failed, {:status, 400}, 1}} =
             Imp.Retrieve.retrieve(retriever, "query", script: semantic_script)

    assert [_unused_success] = Agent.get(semantic_script, & &1)

    {:ok, malformed_script} =
      Agent.start_link(fn ->
        [
          {:ok, %{status: 200, headers: [], body: "not-json"}},
          {:ok, %{status: 200, headers: [], body: ~s({"documents":[])}}
        ]
      end)

    assert {:error, {:invalid_retriever_response, _reason}} =
             Imp.Retrieve.retrieve(retriever, "query", script: malformed_script)

    assert [_unused_success] = Agent.get(malformed_script, & &1)
  end

  test "attempt timeout kills blocked transport work without retries when configured" do
    retriever =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: BlockingTransport,
        max_attempts: 1,
        attempt_timeout: 10,
        total_timeout: 50
      )

    assert {:error, {:retriever_http_failed, :attempt_timeout, 1}} =
             Imp.Retrieve.retrieve(retriever, "query", test_owner: self())

    assert_received {:attempt_started, attempt_pid}
    refute Process.alive?(attempt_pid)
  end

  test "total timeout caps Retry-After sleep and stops before another attempt" do
    {:ok, script} =
      Agent.start_link(fn ->
        [
          {:ok, %{status: 503, headers: [{"retry-after", "60"}], body: "busy"}},
          {:ok, %{status: 200, headers: [], body: ~s({"documents":[]})}}
        ]
      end)

    retriever =
      Imp.Retrievers.HTTP.new("https://retriever.example/search",
        transport: PolicyTransport,
        max_attempts: 2,
        attempt_timeout: 100,
        total_timeout: 20,
        max_retry_delay_ms: 1_000
      )

    assert {:error, {:retriever_http_failed, :total_timeout, 1}} =
             Imp.Retrieve.retrieve(retriever, "query", script: script)

    assert [_unused_success] = Agent.get(script, & &1)
  end

  test "emits payload-free attempt telemetry with outcome and duration" do
    ref = Imp.Test.TelemetryHelpers.attach([[:imp, :retriever, :http, :attempt]])

    {:ok, script} =
      Agent.start_link(fn ->
        [{:ok, %{status: 503, headers: [], body: "api-key-secret"}}]
      end)

    retriever =
      Imp.Retrievers.HTTP.new("https://user:password@example.test/private",
        transport: PolicyTransport,
        headers: [{"authorization", "Bearer abcdefghijklmnop"}],
        max_attempts: 1
      )

    assert {:error, {:retriever_http_failed, {:status, 503}, 1}} =
             Imp.Retrieve.retrieve(retriever, "sk-test-secret-1234567890", script: script)

    assert_received {^ref, [:imp, :retriever, :http, :attempt], %{duration: duration}, metadata}
    assert is_integer(duration)

    assert Map.take(metadata, [:attempt, :max_attempts, :outcome, :status]) == %{
             attempt: 1,
             max_attempts: 1,
             outcome: :retryable_status,
             status: 503
           }

    assert is_binary(metadata.call_id)

    inspected = inspect(metadata)
    refute inspected =~ "password"
    refute inspected =~ "Bearer"
    refute inspected =~ "sk-test"
  end

  test "validates retry and timeout policy at construction" do
    assert_raise ArgumentError, ~r/max_attempts.*positive integer/, fn ->
      Imp.Retrievers.HTTP.new("https://example.test", max_attempts: 0)
    end

    assert_raise ArgumentError, ~r/retry_statuses.*containing only 429/, fn ->
      Imp.Retrievers.HTTP.new("https://example.test", retry_statuses: [400, 503])
    end

    assert_raise ArgumentError, ~r/attempt_timeout.*positive integer/, fn ->
      Imp.Retrievers.HTTP.new("https://example.test", attempt_timeout: :infinity)
    end

    assert_raise ArgumentError, ~r/total_timeout.*positive integer/, fn ->
      Imp.Retrievers.HTTP.new("https://example.test", total_timeout: 0)
    end
  end
end

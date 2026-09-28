defmodule Imp.TimedOutConnectionTest do
  use ExUnit.Case, async: true

  # This test is why Imp's lock holds mint 1.10.1 rather than 1.11.0.
  #
  # mint 1.11.0 leaves an HTTP/1 connection open after a receive timeout, with
  # the request still in flight, and Finch 0.23.0 returns any open connection to
  # its pool. The next request that pool gives that connection is written behind
  # the one that was never answered, so it times out too, and so does every
  # retry that lands there. On mint 1.10.1 the timeout closes the connection and
  # the next request opens a new one.
  #
  # The Finch fix is https://github.com/sneako/finch/pull/397 ("Close abandoned
  # HTTP/1 connections after request errors"), which is open and in no release.
  # When a Finch release includes it, the lock takes that release and mint 1.11
  # together, and this test passes on both.

  @completion %{
    "id" => "late",
    "object" => "chat.completion",
    "model" => "timeout-model",
    "choices" => [
      %{
        "index" => 0,
        "finish_reason" => "stop",
        "message" => %{"role" => "assistant", "content" => "pong"}
      }
    ],
    "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
  }

  test "the call after a timed-out call is answered on a new connection" do
    {:ok, seen} = Agent.start_link(fn -> [] end)

    # Bandit serves each HTTP/1 connection from one process, so the handler's
    # pid names the connection a request came in on. The first request is held
    # past the client's timeout; every later one is answered at once.
    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        connection = self()
        count = Agent.get_and_update(seen, &{length(&1) + 1, &1 ++ [connection]})

        if count == 1 do
          receive do
            :release -> :ok
          after
            2_000 -> :ok
          end
        end

        {200, @completion}
      end)

    lm =
      Imp.req_llm(
        %{
          provider: :openai,
          id: "timeout-model",
          model: "timeout-model",
          base_url: base_url <> "/v1"
        },
        api_key: "local-test-key",
        cache: false
      )

    # ReqLLM's Finch pool spreads a host's requests at random over several
    # one-connection shards, so a request after the timeout meets the stuck
    # connection only when it draws the same shard. Choosing the first shard
    # for every request makes that meeting certain.
    finch = [name: ReqLLM.Application.finch_name(), pool_strategy: &hd/1]
    opts = [timeout: 200, max_retries: 0, req_http_options: [finch: finch]]
    messages = [%{role: :user, content: "ping"}]

    assert {:error, %Imp.LMError{retryable: true}} = Imp.LM.generate(lm, messages, opts)
    assert {:ok, _reply} = Imp.LM.generate(lm, messages, opts)

    assert [first, second] = Agent.get(seen, & &1)
    refute first == second
  end
end

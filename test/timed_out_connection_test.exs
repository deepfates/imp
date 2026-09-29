defmodule Imp.TimedOutConnectionTest do
  use ExUnit.Case, async: true

  # mint 1.11 leaves an HTTP/1 connection open after a receive timeout, with
  # the request still in flight. Finch closes such a connection rather than
  # returning it to its pool (from 0.24.0, which mix.exs requires), so the next
  # request opens a new connection. A pool that reused it would write the next
  # request behind the one that was never answered, and that request would time
  # out or fail when the late answer arrived.

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
    test_pid = self()
    {:ok, seen} = Agent.start_link(fn -> [] end)

    # Bandit serves each HTTP/1 connection from one process, so the handler's
    # pid names the connection a request came in on. The first request is not
    # answered while the test runs, so the first call times out however slow
    # the machine is, and its connection stays busy: a request written behind
    # it would not be answered either. Every later request is answered at once.
    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        connection = self()
        count = Agent.get_and_update(seen, &{length(&1) + 1, &1 ++ [connection]})

        if count == 1 do
          test_ref = Process.monitor(test_pid)

          receive do
            {:DOWN, ^test_ref, :process, _pid, _reason} -> :ok
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
    opts = [max_retries: 0, req_http_options: [finch: finch]]
    messages = [%{role: :user, content: "ping"}]

    assert {:error, %Imp.LMError{retryable: true}} =
             Imp.LM.generate(lm, messages, Keyword.put(opts, :timeout, 200))

    # The second call keeps ReqLLM's own receive timeout. On a new connection
    # it is answered at once; on the stuck one it is not answered, and fails
    # when that timeout runs out.
    assert {:ok, _reply} = Imp.LM.generate(lm, messages, opts)

    assert [first, second] = Agent.get(seen, & &1)
    refute first == second
  end
end

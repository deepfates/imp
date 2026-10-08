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

    # Bandit serves each HTTP/1 connection from one process, so the handler's
    # pid names the connection a request came in on. The request that says
    # "hold" is not answered while the test runs, so the first call times out
    # however slow the machine is, and its connection stays busy: a request
    # written behind it would not be answered either. Every other request is
    # answered at once. The held request is picked by its content, not by
    # arrival order: on a loaded machine the second call's request can reach
    # the server before the first one's.
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        if request.body =~ "hold" do
          send(test_pid, {:held, self()})
          test_ref = Process.monitor(test_pid)

          receive do
            {:DOWN, ^test_ref, :process, _pid, _reason} -> :ok
          end
        else
          send(test_pid, {:answered, self()})
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

    # The receive timeout starts once the request is written, so the server
    # gets the held request even when the call has already timed out.
    assert {:error, %Imp.LMError{retryable: true}} =
             Imp.LM.generate(
               lm,
               [%{role: :user, content: "hold"}],
               Keyword.put(opts, :timeout, 200)
             )

    held = receive(do: ({:held, connection} -> connection))

    # The second call keeps ReqLLM's own receive timeout. On a new connection
    # it is answered at once; on the stuck one it is not answered, and fails
    # when that timeout runs out.
    assert {:ok, _reply} = Imp.LM.generate(lm, [%{role: :user, content: "ping"}], opts)

    assert_received {:answered, answered}
    refute answered == held
  end
end

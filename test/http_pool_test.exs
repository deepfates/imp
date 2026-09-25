defmodule HTTPPoolTest do
  use ExUnit.Case, async: true

  # ReqLLM's default pool is eight one-connection pools picked at random, so
  # concurrent calls collide below eight; Imp sends its requests through one
  # pool of `Imp.Settings.http_pool_size/0` connections instead.

  defmodule Stub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:opts, opts})

      {:ok,
       %ReqLLM.Response{
         id: "r",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("pong")
       }}
    end
  end

  defp sent_http_opts(opts) do
    lm =
      Imp.req_llm(
        "openai:gpt-4o-mini",
        [req_module: Stub, test_pid: self(), cache: false] ++ opts
      )

    assert {:ok, _output} = Imp.LM.generate(lm, [%{role: :user, content: "ping"}], [])
    assert_received {:opts, sent}
    Keyword.get(sent, :req_http_options, [])
  end

  test "requests go through Imp's pool, which Imp starts" do
    assert sent_http_opts([])[:finch] == [name: Imp.Finch]
    assert is_pid(Process.whereis(Imp.Finch))
  end

  test "a caller's own pool or connect options are left alone" do
    assert sent_http_opts(req_http_options: [finch: [name: MyFinch]])[:finch] == [name: MyFinch]

    refute Keyword.has_key?(
             sent_http_opts(req_http_options: [connect_options: [timeout: 1]]),
             :finch
           )
  end

  test "async_max_workers may not exceed the pool" do
    size = Imp.Settings.http_pool_size()
    assert Imp.Settings.context([async_max_workers: size], fn -> :ok end) == :ok

    assert_raise ArgumentError, ~r/http_pool_size/, fn ->
      Imp.Settings.context([async_max_workers: size + 1], fn -> :ok end)
    end
  end
end

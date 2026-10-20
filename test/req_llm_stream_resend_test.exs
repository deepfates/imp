defmodule Imp.ReqLLMStreamResendTest do
  @moduledoc """
  A streamed call through `Imp.Clients.ReqLLM` sends a failed attempt again
  the same way a non-streamed call does: ReqLLM's streaming retries are off,
  Imp sends the attempt again itself before the stream's first chunk, and each
  resend is a `:model_resend` event on the run's record. A timed-out attempt
  is not sent again.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  defmodule OptsStub do
    def stream_text(_model, _messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:opts, opts})
      {:error, :stubbed}
    end
  end

  # A stream that fails to open at all, as a refused connection.
  defmodule RefusedStub do
    def stream_text(_model, _messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), :opened)
      {:error, %Req.TransportError{reason: :econnrefused}}
    end
  end

  defmodule Collecting do
    @behaviour Imp.Module
    defstruct [:program, provider_stream: true, deadline: :infinity]

    @impl true
    def call(%__MODULE__{} = module, inputs) do
      Imp.Deadline.with_deadline(module.deadline, fn ->
        Imp.collect(module.program, inputs, provider_stream: module.provider_stream)
      end)
    end
  end

  @answer "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"

  # A raw listener that accepts every connection and answers the nth request
  # with `respond.(n)`: `:hang` reads the request and never answers, `:close`
  # reads it and closes the connection, `{:status, status, headers}` answers
  # that status with an empty JSON error body, `:ok` answers a complete
  # OpenAI-style event stream and `:ok_json` a complete non-streamed answer.
  defp listener(respond) do
    owner = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    acceptor =
      spawn_link(fn ->
        Stream.iterate(1, &(&1 + 1))
        |> Stream.each(fn n ->
          {:ok, socket} = :gen_tcp.accept(listen)
          send(owner, :request_received)
          holder = spawn(fn -> serve(socket, respond.(n)) end)
          :gen_tcp.controlling_process(socket, holder)
        end)
        |> Stream.run()
      end)

    on_exit(fn -> Process.exit(acceptor, :kill) end)
    "http://127.0.0.1:#{port}/api/v1"
  end

  defp serve(socket, mode) do
    read_request(socket, "")

    case mode do
      :hang ->
        Process.sleep(:infinity)

      :close ->
        :gen_tcp.close(socket)

      # A provider at work: the response has begun with a keepalive comment,
      # which makes no chunk, and then the connection drops.
      :keepalive_then_close ->
        comment = ": OPENROUTER PROCESSING\n\n"

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
            "transfer-encoding: chunked\r\n\r\n" <>
            Integer.to_string(byte_size(comment), 16) <> "\r\n" <> comment <> "\r\n"
        )

        Process.sleep(150)
        :gen_tcp.close(socket)

      {:status, status, headers} ->
        body = ~s({"error":{"message":"rate limited"}})

        head =
          Enum.map_join(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\n" <>
            head <> "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )

        Process.sleep(200)
        :gen_tcp.close(socket)

      :ok_json ->
        body =
          Jason.encode!(%{
            id: "c1",
            object: "chat.completion",
            model: "example/model",
            choices: [
              %{index: 0, message: %{role: "assistant", content: @answer}, finish_reason: "stop"}
            ]
          })

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )

        Process.sleep(200)
        :gen_tcp.close(socket)

      :ok ->
        delta = Jason.encode!(%{choices: [%{index: 0, delta: %{content: @answer}}]})

        finish =
          Jason.encode!(%{choices: [%{index: 0, delta: %{}, finish_reason: "stop"}]})

        body = "data: #{delta}\n\ndata: #{finish}\n\ndata: [DONE]\n\n"

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )

        Process.sleep(200)
        :gen_tcp.close(socket)
    end
  end

  # Reads the request's head and as much of its body as `content-length` says,
  # so the client has sent the whole request before it is answered.
  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, head) do
            [_all, n] -> String.to_integer(n)
            nil -> 0
          end

        if byte_size(body) < length, do: recv_more(socket, acc), else: :ok

      [_partial] ->
        recv_more(socket, acc)
    end
  end

  defp recv_more(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read_request(socket, acc <> data)
      {:error, _reason} -> :ok
    end
  end

  defp run_once(base_url, lm_opts, call_opts \\ []) do
    lm =
      Imp.req_llm(
        %{provider: :openrouter, id: "example/model"},
        [api_key: "test", base_url: base_url, cache: false] ++ lm_opts
      )

    run_once_with(lm, call_opts)
  end

  defp run_once_with(lm, call_opts \\ []) do
    owner = self()

    program = "question -> answer" |> Imp.signature("Answer.") |> Imp.predict(lm: lm)

    {:ok, run} =
      Imp.Run.start(struct!(Collecting, [program: program] ++ call_opts), %{question: "hello"},
        event_sink: fn event ->
          send(owner, {:event, event})
          :ok
        end
      )

    {elapsed, result} = :timer.tc(fn -> Task.await(run.task, 15_000) end)
    {div(elapsed, 1_000), result, events_until_end(), length(drain(:request_received))}
  end

  defp events_until_end do
    assert_receive {:event, event}, 1_000

    if event.kind in [:run_finished, :run_failed, :run_cancelled],
      do: [event],
      else: [event | events_until_end()]
  end

  defp drain(tag) do
    receive do
      ^tag -> [tag | drain(tag)]
    after
      0 -> []
    end
  end

  defp kinds(events), do: Enum.map(events, & &1.kind)

  # A base URL nothing listens on, so every connection is refused.
  defp refused_url do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}/api/v1"
  end

  test "a stream is opened with ReqLLM's retries off" do
    lm =
      Imp.req_llm(%{provider: :openrouter, id: "example/model"},
        test_pid: self(),
        req_module: OptsStub
      )

    _ = lm |> Imp.Clients.ReqLLM.stream([%{role: :user, content: "hi"}], []) |> Enum.to_list()

    assert_received {:opts, opts}
    assert Keyword.fetch!(opts, :max_retries) == 0
  end

  test "a stream whose provider never answers gets one request and no resend" do
    {_elapsed, result, events, requests} =
      run_once(listener(fn _n -> :hang end), receive_timeout: 300)

    assert {:error, _reason} = result
    assert requests == 1
    assert kinds(events) == [:run_started, :model_request, :model_response, :run_failed]
  end

  test "each streamed attempt sent again is its own :model_resend event on the call" do
    {_elapsed, result, events, _requests} =
      run_once(refused_url(), receive_timeout: 1_000, max_retries: 2)

    assert {:error, _reason} = result

    assert kinds(events) == [
             :run_started,
             :model_request,
             :model_resend,
             :model_resend,
             :model_response,
             :run_failed
           ]

    [request] = Enum.filter(events, &(&1.kind == :model_request))
    resends = Enum.filter(events, &(&1.kind == :model_resend))

    assert [1, 2] == Enum.map(resends, & &1.metadata.attempt)
    assert Enum.all?(resends, &(&1.metadata.model_call_id == request.metadata.model_call_id))
    assert Enum.all?(resends, &(&1.metadata.retry_in_ms == 0))
  end

  test "a 429 is sent again after its retry-after, and the stream that follows is the answer" do
    respond = fn
      1 -> {:status, 429, [{"retry-after", "0"}]}
      _n -> :ok
    end

    {_elapsed, result, events, requests} = run_once(listener(respond), receive_timeout: 1_000)

    assert {:ok, prediction} = result
    assert Imp.get(prediction, :answer) == "Paris"
    assert requests == 2

    assert kinds(events) == [
             :run_started,
             :model_request,
             :model_resend,
             :model_response,
             :run_finished
           ]

    [resend] = Enum.filter(events, &(&1.kind == :model_resend))
    assert resend.metadata.retry_in_ms == 0
    assert %Imp.LMError{status: 429} = resend.error
  end

  test "max_retries: 0 opens a failed stream once" do
    {_elapsed, _result, events, _requests} =
      run_once(refused_url(), receive_timeout: 1_000, max_retries: 0)

    refute :model_resend in kinds(events)
  end

  # ReqLLM does not say whether a closed stream's response had begun, and a
  # provider at work sends keepalive bytes that make no chunk, so a closed
  # stream may follow billed work: it is not opened again.
  for mode <- [:close, :keepalive_then_close] do
    test "a stream whose connection closes is not opened again (#{mode})" do
      {_elapsed, result, events, requests} =
        run_once(listener(fn _n -> unquote(mode) end), receive_timeout: 2_000, max_retries: 2)

      assert {:error, _reason} = result
      assert requests == 1
      refute :model_resend in kinds(events)
    end
  end

  test "a stream that fails to open is sent again, and its error is recorded once" do
    lm =
      Imp.req_llm(%{provider: :openrouter, id: "example/model"},
        test_pid: self(),
        req_module: RefusedStub,
        max_retries: 1
      )

    {_elapsed, result, events, _requests} = run_once_with(lm)

    assert {:error, %Imp.LMError{}} = result
    assert_received :opened
    assert_received :opened
    assert [resend] = Enum.filter(events, &(&1.kind == :model_resend))
    assert %Imp.LMError{reason: %Req.TransportError{reason: :econnrefused}} = resend.error
  end

  # A provider asking for an hour is not waited for, by either kind of call:
  # the 429 is the call's answer, and the run's `request_retry:` or the caller
  # decides whether to wait that long.
  for provider_stream <- [true, false] do
    test "a 429 asking for a wait over a minute is returned, not slept on (stream: #{provider_stream})" do
      {elapsed, result, events, requests} =
        run_once(
          listener(fn _n -> {:status, 429, [{"retry-after", "3600"}]} end),
          [receive_timeout: 1_000],
          provider_stream: unquote(provider_stream)
        )

      assert {:error, %Imp.LMError{status: 429}} = result
      assert requests == 1
      assert elapsed < 5_000
      refute :model_resend in kinds(events)
    end

    # Under a deadline, a wait that leaves the next attempt too little time
    # to answer is not taken: the call fails with the 429 it got, not with
    # the timeout of an attempt that never had time to answer.
    test "a 429 whose wait leaves no time to answer is returned under a deadline (stream: #{provider_stream})" do
      respond = fn
        1 -> {:status, 429, [{"retry-after", "1"}]}
        _n -> :hang
      end

      {_elapsed, result, events, requests} =
        run_once(listener(respond), [receive_timeout: 10_000],
          provider_stream: unquote(provider_stream),
          deadline: 2_500
        )

      assert {:error, %Imp.LMError{status: 429}} = result
      assert requests == 1
      refute :model_resend in kinds(events)
    end
  end

  # An attempt sent again at once takes nothing from a deadline by waiting,
  # so a short deadline does not stop it.
  for {provider_stream, first} <- [{true, :rate_limited}, {false, :rate_limited}, {false, :close}] do
    test "under a short deadline an attempt is still sent again at once (stream: #{provider_stream}, #{first})" do
      respond = fn
        1 when unquote(first) == :close -> :close
        1 -> {:status, 429, [{"retry-after", "0"}]}
        _n -> if unquote(provider_stream), do: :ok, else: :ok_json
      end

      {_elapsed, result, events, requests} =
        run_once(listener(respond), [receive_timeout: 2_000],
          provider_stream: unquote(provider_stream),
          deadline: 4_000
        )

      assert {:ok, prediction} = result
      assert Imp.get(prediction, :answer) == "Paris"
      assert requests == 2
      assert :model_resend in kinds(events)
    end
  end
end

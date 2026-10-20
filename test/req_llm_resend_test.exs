defmodule Imp.ReqLLMResendTest do
  @moduledoc """
  A call through `Imp.Clients.ReqLLM` with no deadline waits a bounded time
  for each attempt, and every attempt it sends again is on the run's record
  as a `:model_resend` event.
  """
  use ExUnit.Case, async: true

  defmodule OptsStub do
    def generate_text(_model, _messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:opts, opts})
      {:error, :stubbed}
    end
  end

  # A raw listener that accepts every connection. `:hang` reads the request
  # and never answers; `:close` reads it and closes the connection.
  defp listener(mode) do
    owner = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    acceptor =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          send(owner, :request_received)

          holder =
            spawn(fn ->
              :gen_tcp.recv(socket, 0, 1_000)
              if mode == :close, do: :gen_tcp.close(socket), else: Process.sleep(:infinity)
            end)

          :gen_tcp.controlling_process(socket, holder)
        end)
        |> Stream.run()
      end)

    on_exit(fn -> Process.exit(acceptor, :kill) end)
    "http://127.0.0.1:#{port}/api/v1"
  end

  defp run_once(base_url, lm_opts) do
    owner = self()

    lm =
      Imp.req_llm(
        %{provider: :openrouter, id: "example/model"},
        [api_key: "test", base_url: base_url, cache: false] ++ lm_opts
      )

    program = "question -> answer" |> Imp.signature("Answer.") |> Imp.predict(lm: lm)

    {:ok, run} =
      Imp.Run.start(program, %{question: "hello"},
        event_sink: fn event ->
          send(owner, {:event, event})
          :ok
        end
      )

    {elapsed, result} = :timer.tc(fn -> Task.await(run.task, 10_000) end)
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

  test "with no deadline, a call has a 10-minute receive timeout and ReqLLM's retries off" do
    lm =
      Imp.req_llm(%{provider: :openrouter, id: "example/model"},
        test_pid: self(),
        req_module: OptsStub
      )

    assert {:error, _} = Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hi"}], [])

    assert_received {:opts, opts}
    assert Keyword.fetch!(opts, :receive_timeout) == 600_000
    assert Keyword.fetch!(opts, :max_retries) == 0
  end

  test "a provider that never answers gets one bounded request and no resend" do
    {elapsed, result, events, requests} = run_once(listener(:hang), receive_timeout: 300)

    assert {:error, %Imp.LMError{}} = result
    assert requests == 1
    assert elapsed < 3_000

    assert Enum.map(events, & &1.kind) ==
             [:run_started, :model_request, :model_response, :run_failed]
  end

  test "each attempt sent again is its own :model_resend event on the call" do
    {_elapsed, result, events, requests} =
      run_once(listener(:close), receive_timeout: 1_000, max_retries: 2)

    assert {:error, %Imp.LMError{}} = result
    assert requests == 3

    assert Enum.map(events, & &1.kind) ==
             [
               :run_started,
               :model_request,
               :model_resend,
               :model_resend,
               :model_response,
               :run_failed
             ]

    [request] = Enum.filter(events, &(&1.kind == :model_request))
    resends = Enum.filter(events, &(&1.kind == :model_resend))
    call_id = request.metadata.model_call_id

    assert [1, 2] == Enum.map(resends, & &1.metadata.attempt)
    assert Enum.all?(resends, &(&1.metadata.model_call_id == call_id))
    assert Enum.all?(resends, &(&1.metadata.retry_in_ms == 0))
    assert Enum.all?(resends, &(&1.error != nil))
  end

  test "max_retries: 0 sends a failed attempt once" do
    {_elapsed, _result, events, requests} =
      run_once(listener(:close), receive_timeout: 1_000, max_retries: 0)

    assert requests == 1
    refute Enum.any?(events, &(&1.kind == :model_resend))
  end
end

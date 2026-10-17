defmodule Imp.RunRequestRetryTest do
  @moduledoc """
  `Imp.Run.start/3`'s `request_retry:`: a model request that failed with an
  error a later attempt may get past is sent again, in the same run, after a
  wait, and every attempt is on the record.
  """
  use ExUnit.Case, async: true

  # A provider whose answers are scripted, failures included: `script` is an
  # Agent holding the replies still to come, the last repeated.
  defmodule Scripted do
    @behaviour Imp.LM
    defstruct [:script]

    @impl true
    def generate(%__MODULE__{script: script}, _messages, _opts) do
      Agent.get_and_update(script, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end
  end

  # An LM that wraps another and calls it through `Imp.LM.generate/3`, as an
  # optimizer's budget or a host's own wrapper does.
  defmodule Wrapper do
    @behaviour Imp.LM
    defstruct [:inner]

    @impl true
    def generate(%__MODULE__{inner: inner}, messages, opts),
      do: Imp.LM.generate(inner, messages, opts)
  end

  # A program that makes one model request and returns what it got.
  defmodule OneRequest do
    @behaviour Imp.Module
    defstruct [:lm]

    @impl true
    def call(%{lm: lm}, _inputs) do
      case Imp.LM.generate(lm, [%{role: :user, content: "hello"}]) do
        {:ok, output} -> {:ok, Imp.Prediction.new(%{answer: output})}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @outage {:error,
           %Imp.LMError{
             message: "502 Upstream error: connection refused",
             status: 502,
             retryable: true
           }}
  @refused {:error, %Imp.LMError{message: "400 bad request", status: 400, retryable: false}}

  defp run(script, opts) do
    {:ok, script} = Agent.start_link(fn -> script end)
    owner = self()
    {wrap, opts} = Keyword.pop(opts, :wrap, &Function.identity/1)

    {:ok, run} =
      Imp.Run.start(
        %OneRequest{lm: wrap.(%Scripted{script: script})},
        %{},
        [event_sink: fn event -> send(owner, {:event, event}) end] ++ opts
      )

    result = Task.await(run.task, 10_000)
    :ok = Imp.Run.stop(run)
    {result, responses(run, [])}
  end

  defp responses(_run, acc) do
    receive do
      {:event, %{kind: :model_response} = event} -> responses(nil, [event | acc])
      {:event, _event} -> responses(nil, acc)
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "a request the provider failed is sent again after each wait, and answers" do
    {result, responses} =
      run([@outage, @outage, {:ok, "hi"}],
        request_retry: [waits: [10, 30], reserve: 0],
        deadline: 5_000
      )

    assert {:ok, prediction} = result
    assert Imp.get(prediction, :answer) == "hi"

    # Three model calls, each its own; the two failures say how long the run
    # waited before the next attempt.
    assert [first, second, third] = responses
    assert first.error.status == 502 and first.metadata.retry_in_ms == 10
    assert second.error.status == 502 and second.metadata.retry_in_ms == 30
    assert third.error == nil and not Map.has_key?(third.metadata, :retry_in_ms)
    assert length(Enum.uniq(Enum.map(responses, & &1.metadata.model_call_id))) == 3
  end

  test "without request_retry nothing is sent again" do
    {result, responses} = run([@outage, {:ok, "hi"}], deadline: 5_000)

    assert {:error, %Imp.LMError{status: 502}} = result
    assert [only] = responses
    refute Map.has_key?(only.metadata, :retry_in_ms)
  end

  test "a request the provider refused is not sent again" do
    {result, responses} =
      run([@refused, {:ok, "hi"}], request_retry: [waits: [10], reserve: 0], deadline: 5_000)

    assert {:error, %Imp.LMError{status: 400}} = result
    assert [_only] = responses
  end

  test "without a deadline the waits are the bound" do
    {result, responses} = run([@outage], request_retry: [waits: [10, 10], reserve: 0])

    assert {:error, %Imp.LMError{status: 502}} = result
    assert [10, 10, nil] = Enum.map(responses, &Map.get(&1.metadata, :retry_in_ms))
  end

  test "with a deadline the last wait repeats until it would cut into the reserve" do
    started = System.monotonic_time(:millisecond)

    {result, responses} =
      run([@outage], request_retry: [waits: [20], reserve: 300], deadline: 600)

    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, %Imp.LMError{status: 502}} = result
    waits = Enum.map(responses, &Map.get(&1.metadata, :retry_in_ms))
    assert length(waits) > 3
    assert List.last(waits) == nil
    assert Enum.all?(Enum.drop(waits, -1), &(&1 == 20))
    # It stopped with the reserve still left.
    assert elapsed < 600 - 100
  end

  # Were each level to retry, the inner request's two attempts would each be
  # repeated by the outer one: four requests where two were asked for.
  test "a request made inside another is sent again only by the outermost" do
    {result, responses} =
      run([@outage, {:ok, "hi"}],
        request_retry: [waits: [10], reserve: 0],
        deadline: 5_000,
        wrap: &%Wrapper{inner: &1}
      )

    assert {:ok, _prediction} = result

    # Each request is recorded at both levels: the outer LM's and the inner's.
    # The failure was retried once, by the outer request, and the inner one
    # returned it without waiting.
    retried = Enum.filter(responses, &Map.has_key?(&1.metadata, :retry_in_ms))
    assert length(retried) == 1
    assert length(responses) == 4
  end

  test "an empty list of waits is refused, not taken as a bound" do
    assert_raise ArgumentError, ~r/non-empty list/, fn ->
      Imp.Run.start(%OneRequest{lm: nil}, %{}, request_retry: [waits: []], deadline: 5_000)
    end
  end

  # A provider that says when to come back is not asked sooner.
  test "a provider's retry-after longer than the wait is waited instead" do
    limited =
      {:error,
       %Imp.LMError{
         message: "429 rate limited",
         status: 429,
         retryable: true,
         reason: %{headers: %{"retry-after" => ["1"]}}
       }}

    {result, responses} =
      run([limited, {:ok, "hi"}], request_retry: [waits: [10], reserve: 0], deadline: 5_000)

    assert {:ok, _prediction} = result
    assert [first, _second] = responses
    assert first.metadata.retry_in_ms == 1_000
  end
end

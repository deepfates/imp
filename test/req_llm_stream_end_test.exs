defmodule Imp.ReqLLMStreamEndTest do
  use ExUnit.Case, async: true

  alias Imp.Streaming.Messages.StreamResponse

  # These streams come from ReqLLM itself, decoding server-sent events from a
  # local server, so they end the way a provider's stream does: as a
  # `Stream.resource` that has run out, not as a list.

  @content %{
    "id" => "gen-1",
    "model" => "local-model",
    "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "pong"}}]
  }

  @finish %{
    "id" => "gen-1",
    "model" => "local-model",
    "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
  }

  @usage %{
    "id" => "gen-1",
    "model" => "local-model",
    "choices" => [],
    "usage" => %{
      "prompt_tokens" => 7,
      "completion_tokens" => 1,
      "total_tokens" => 8,
      "cost" => 0.00042
    }
  }

  @byok_usage %{
    "id" => "gen-1",
    "model" => "local-model",
    "choices" => [],
    "usage" => %{
      "prompt_tokens" => 7,
      "completion_tokens" => 1,
      "total_tokens" => 8,
      "cost" => 0.0001,
      "is_byok" => true,
      "cost_details" => %{"upstream_inference_cost" => 0.002}
    }
  }

  defp sse(events, done? \\ true) do
    body = Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
    if done?, do: body <> "data: [DONE]\n\n", else: body
  end

  defp lm(body, model \\ %{}) do
    url = Imp.Test.LocalHTTP.start(fn _request -> {200, body} end)

    Imp.req_llm(
      Map.merge(
        %{
          provider: :openrouter,
          id: "local-model",
          model: "local-model",
          base_url: url <> "/api/v1"
        },
        model
      ),
      api_key: "local-test-key",
      cache: false
    )
  end

  defp priced_lm(body) do
    lm(body, %{
      pricing: %{
        currency: "USD",
        components: [
          %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 0.1},
          %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 0.4}
        ]
      }
    })
  end

  defp stream(lm),
    do: lm |> Imp.Clients.ReqLLM.stream([%{role: :user, content: "ping"}], []) |> Enum.to_list()

  test "a provider stream that runs to its end closes with one done event carrying usage and cost" do
    events = stream(lm(sse([@content, @finish, @usage])))

    assert [%StreamResponse{chunk: "pong", done: false}, %StreamResponse{done: true} = last] =
             events

    assert last.chunk == nil
    assert last.metadata.finish_reason == :stop
    assert %{input_tokens: 7, output_tokens: 1, total_tokens: 8} = last.metadata.usage
    assert last.metadata.usage["cost"] == 0.00042
  end

  test "an error the provider sends inside the stream ends it as a failure, with what arrived" do
    error = %{"error" => %{"message" => "upstream died", "code" => 502}}
    events = stream(lm(sse([@content, @usage, error], false)))

    assert [%StreamResponse{chunk: "pong"}, %StreamResponse{done: true} = last] = events
    assert {:error, %Imp.LMError{retryable: true} = reason} = last.chunk
    assert reason.message =~ "upstream died"
    assert %{input_tokens: 7} = last.metadata.usage
    assert last.metadata.usage["cost"] == 0.00042
    refute Enum.any?(events, &match?(%StreamResponse{done: true, chunk: nil}, &1))
  end

  test "a stream whose body stops with no finish and no [DONE] is not a completion" do
    events = stream(lm(sse([@content], false)))

    assert [
             %StreamResponse{chunk: "pong"},
             %StreamResponse{
               chunk: {:error, %Imp.LMError{reason: {:stream_finished, :incomplete}}},
               done: true,
               metadata: %{finish_reason: :incomplete}
             }
           ] = events
  end

  # A ReqLLM stream built from chunks, with a real metadata handle answering
  # what ReqLLM concluded about the stream.
  defmodule FinishStub do
    def stream_text(model, messages, opts) do
      chunks =
        Keyword.get_lazy(opts, :chunks, fn ->
          [
            ReqLLM.StreamChunk.text("partial"),
            ReqLLM.StreamChunk.meta(%{finish_reason: Keyword.fetch!(opts, :finish_reason)})
          ]
        end)

      handle_metadata = Keyword.get(opts, :handle_metadata, %{})

      {:ok, handle} =
        ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> handle_metadata end)

      stream =
        Stream.resource(
          fn -> chunks end,
          fn
            [] -> {:halt, []}
            [chunk | rest] -> {[chunk], rest}
          end,
          fn _state -> :ok end
        )

      {:ok,
       %ReqLLM.StreamResponse{
         stream: stream,
         metadata_handle: handle,
         cancel: fn -> :ok end,
         model: model,
         context: ReqLLM.Context.new(messages)
       }}
    end
  end

  test "a stream that finishes cancelled or in error is not a completion" do
    for finish_reason <- [:cancelled, :error] do
      events =
        %{provider: :openai, id: "local-model", model: "local-model"}
        |> Imp.req_llm(req_module: FinishStub, finish_reason: finish_reason, cache: false)
        |> stream()

      assert [
               %StreamResponse{chunk: "partial"},
               %StreamResponse{
                 chunk: {:error, %Imp.LMError{reason: {:stream_finished, ^finish_reason}}},
                 done: true,
                 metadata: %{finish_reason: ^finish_reason}
               }
             ] = events
    end
  end

  test "usage only ReqLLM's metadata handle reported is on the done event" do
    usage = %{input_tokens: 4, output_tokens: 2, total_tokens: 6}

    events =
      %{provider: :openai, id: "local-model", model: "local-model"}
      |> Imp.req_llm(
        req_module: FinishStub,
        chunks: [ReqLLM.StreamChunk.text("pong")],
        handle_metadata: %{usage: usage, finish_reason: :stop},
        cache: false
      )
      |> stream()

    assert [
             %StreamResponse{chunk: "pong"},
             %StreamResponse{done: true, metadata: %{usage: ^usage, finish_reason: :stop}}
           ] = events
  end

  test "the client names the provider and model id of every model shape it accepts" do
    for model <- [
          "openai:gpt-x",
          {:openai, id: "gpt-x"},
          {:openai, model: "gpt-x"},
          {:openai, "gpt-x", []},
          %{provider: :openai, id: "gpt-x"},
          %{"provider" => "openai", "id" => "gpt-x"}
        ] do
      assert Imp.Clients.ReqLLM.model_identity(model) == {"openai", "gpt-x"}, inspect(model)
    end
  end

  defmodule Collecting do
    @behaviour Imp.Module
    defstruct [:program]

    @impl true
    def call(%__MODULE__{program: program}, inputs),
      do: Imp.collect(program, inputs, provider_stream: true)
  end

  test "a streamed call records the usage and cost the provider reported at the end" do
    answer = "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"
    content = put_in(@content, ["choices", Access.at(0), "delta", "content"], answer)
    program = Imp.predict("question -> answer", lm: lm(sse([content, @finish, @usage])))

    {:ok, run} = Imp.Run.start(%Collecting{program: program}, %{question: "Capital of France?"})
    assert {:ok, prediction} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)

    assert Imp.get(prediction, :answer) == "Paris"
    assert [response] = Enum.filter(events, &(&1.kind == :model_response))
    assert %{input_tokens: 7, output_tokens: 1, total_tokens: 8} = response.metadata.usage
    assert response.metadata.usage["cost"] == 0.00042
    assert response.metadata.cost == 0.00042
  end

  test "an OpenRouter stream on the caller's own key costs the fee plus the upstream charge" do
    answer = "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"
    content = put_in(@content, ["choices", Access.at(0), "delta", "content"], answer)
    client = lm(sse([content, @finish, @byok_usage]))

    assert %StreamResponse{done: true, metadata: %{usage: usage}} =
             client |> stream() |> List.last()

    assert usage["cost"] == 0.0001

    program = Imp.predict("question -> answer", lm: client)
    {:ok, run} = Imp.Run.start(%Collecting{program: program}, %{question: "Capital of France?"})
    assert {:ok, _prediction} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)

    assert [response] = Enum.filter(events, &(&1.kind == :model_response))
    assert_in_delta response.metadata.cost, 0.0021, 1.0e-12
    assert response.metadata.usage["cost"] == 0.0001
  end

  defp run(program) do
    {:ok, run} = Imp.Run.start(%Collecting{program: program}, %{question: "Capital of France?"})

    {result, usage} = Imp.Usage.track(fn -> Task.await(run.task) end)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)
    {result, usage, events}
  end

  test "a stream that fails after the provider reported usage records that spend" do
    error = %{"error" => %{"message" => "upstream died"}}
    program = Imp.predict("question -> answer", lm: lm(sse([@content, @usage, error], false)))

    assert {{:error, %Imp.LMError{message: message}}, _usage, events} = run(program)
    assert message =~ "upstream died"

    assert [response] = Enum.filter(events, &(&1.kind == :model_response))
    assert %Imp.LMError{} = response.error
    assert %{input_tokens: 7, output_tokens: 1, total_tokens: 8} = response.metadata.usage
    assert response.metadata.cost == 0.00042
  end

  test "a stream that fails after a byok usage chunk records the resolved charge" do
    error = %{"error" => %{"message" => "upstream died"}}

    charged =
      Imp.predict("question -> answer", lm: lm(sse([@content, @byok_usage, error], false)))

    assert {{:error, %Imp.LMError{}}, _usage, events} = run(charged)
    assert [response] = Enum.filter(events, &(&1.kind == :model_response))
    assert_in_delta response.metadata.cost, 0.0021, 1.0e-12
    assert response.metadata.usage["cost"] == 0.0001

    bare = %{@byok_usage | "usage" => Map.delete(@byok_usage["usage"], "cost_details")}

    missing =
      Imp.predict("question -> answer", lm: lm(sse([@content, bare, error], false)))

    assert {{:error, %Imp.LMError{}}, _usage, missing_events} = run(missing)
    assert [partial] = Enum.filter(missing_events, &(&1.kind == :model_response))
    assert partial.metadata.cost == nil
    assert partial.metadata.usage["cost"] == 0.0001
  end

  test "a failure that carries a partial response counts its usage and returns the reason" do
    lm = Imp.req_llm(%{provider: :openrouter, id: "m", model: "m"}, cache: false)
    request = Imp.LM.new_request(lm, [%{role: :user, content: "ping"}], [], "test")

    {:ok, partial} =
      Imp.Core.response(%{
        __imp_lm_output__: "po",
        __imp_lm_metadata__: %{
          req_llm: %{
            provider: "openrouter",
            model: "m",
            usage: %{input_tokens: 7, output_tokens: 1}
          }
        }
      })

    assert {{:error, :broken}, usage} =
             Imp.Usage.track(fn ->
               Imp.LM.record(lm, request, fn _request -> {:error, :broken, partial} end)
             end)

    assert usage == %{"openrouter/m" => %{input_tokens: 7, output_tokens: 1}}
  end

  # A `{provider, opts}` tuple and a string-keyed map are model shapes
  # ReqLLM accepts; a streamed call through either records its provider and model.
  test "a streamed call records provider and model for tuple and string-keyed specs" do
    for model <- [{:openai, id: "local-model"}, %{"provider" => "openai", "id" => "local-model"}] do
      lm =
        Imp.req_llm(model,
          req_module: FinishStub,
          chunks: [
            ReqLLM.StreamChunk.text("[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"),
            ReqLLM.StreamChunk.meta(%{usage: %{input_tokens: 1}, finish_reason: :stop})
          ],
          cache: false
        )

      program = Imp.predict("question -> answer", lm: lm)
      assert {{:ok, _prediction}, _usage, events} = run(program)
      assert [response] = Enum.filter(events, &(&1.kind == :model_response))

      assert %{provider: "openai", model: "local-model"} =
               response.metadata.response.req_llm,
             inspect(model)
    end
  end

  defp track_collect(program) do
    Imp.Usage.track(fn ->
      Imp.collect(program, %{question: "Capital of France?"}, provider_stream: true)
    end)
  end

  # A streamed call is counted as a non-streamed one is: what the provider
  # charged as `cost`, ReqLLM's catalog price as `estimated_cost`, and both in
  # the usage `Imp.Usage.track` returns around `Imp.collect`.
  test "a streamed call carries the same charge and estimate as a non-streamed one" do
    answer = "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"
    content = put_in(@content, ["choices", Access.at(0), "delta", "content"], answer)

    completion = %{
      "id" => "gen-1",
      "model" => "local-model",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => answer}
        }
      ],
      "usage" => @usage["usage"]
    }

    streamed = Imp.predict("question -> answer", lm: priced_lm(sse([content, @finish, @usage])))
    plain = Imp.predict("question -> answer", lm: priced_lm(Jason.encode!(completion)))

    {:ok, run} = Imp.Run.start(plain, %{question: "?"})
    assert {:ok, _prediction} = Task.await(run.task)
    [expected] = Enum.filter(Imp.Run.events(run), &(&1.kind == :model_response))
    Imp.Run.stop(run)
    assert is_float(expected.metadata.estimated_cost)

    assert {{:ok, prediction}, _usage, events} = run(streamed)
    assert Imp.get(prediction, :answer) == "Paris"
    assert [response] = Enum.filter(events, &(&1.kind == :model_response))
    assert response.metadata.cost == 0.00042
    assert response.metadata.estimated_cost == expected.metadata.estimated_cost

    assert {{:ok, _prediction}, usage} = track_collect(streamed)
    assert %{"openrouter/local-model" => tracked} = usage
    assert %{input_tokens: 7, output_tokens: 1, total_tokens: 8} = tracked
    assert tracked["cost"] == 0.00042
    assert tracked.total_cost == expected.metadata.estimated_cost
  end

  test "a streamed call that failed after usage arrived is counted by Imp.Usage" do
    error = %{"error" => %{"message" => "upstream died"}}
    program = Imp.predict("question -> answer", lm: lm(sse([@content, @usage, error], false)))

    # With `track_usage` on, the predictor keeps a tracker of its own, and
    # the failed call still reaches the caller's.
    for track_usage <- [false, true] do
      assert {{:error, %Imp.LMError{}}, usage} =
               Imp.context([track_usage: track_usage], fn -> track_collect(program) end)

      assert %{"openrouter/local-model" => %{input_tokens: 7, output_tokens: 1} = tracked} =
               usage,
             "track_usage: #{track_usage}"

      assert tracked["cost"] == 0.00042
    end
  end
end

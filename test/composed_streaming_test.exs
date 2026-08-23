defmodule Imp.ComposedStreamingTest do
  use ExUnit.Case, async: true

  alias Imp.Streaming.Messages.StreamListener
  alias Imp.Streaming.Messages.StreamResponse

  defmodule ScriptedStreamLM do
    defstruct [:owner, :responses]

    def generate(_lm, _messages, _opts),
      do: {:error, :generate_must_not_replace_streaming}

    def stream(%__MODULE__{owner: owner, responses: responses}, messages, _opts) do
      rendered = Enum.map_join(messages, "\n", &to_string(&1.content))
      send(owner, {:stream_request, rendered})

      Agent.get_and_update(responses, fn
        [events | rest] -> {events, rest}
        [] -> raise "unexpected extra stream request"
      end)
    end
  end

  defmodule BlockingStreamLM do
    defstruct [:owner]

    def generate(_lm, _messages, _opts), do: {:error, :generate_must_not_run}

    def stream(%__MODULE__{owner: owner}, _messages, _opts) do
      Stream.resource(
        fn ->
          send(owner, :provider_opened)
          :first
        end,
        fn
          :first ->
            {[%StreamResponse{chunk: "[[ ## answer ## ]]\npartial"}], :blocked}

          :blocked ->
            send(owner, :provider_pulled_again)

            receive do
              :never -> {:halt, :done}
            end
        end,
        fn _state -> send(owner, :provider_cleaned) end
      )
    end
  end

  test "streams selected fields from both predictors while executing real composed control flow" do
    {:ok, responses} =
      Agent.start_link(fn ->
        [
          [
            %StreamResponse{chunk: "[[ ## evidence ## ]]\nsecurity signal"},
            %StreamResponse{chunk: "\n\n[[ ## completed ## ]]", done: true}
          ],
          [
            %StreamResponse{chunk: "[[ ## route ## ]]\nR68"},
            %StreamResponse{chunk: "\n\n[[ ## completed ## ]]", done: true}
          ]
        ]
      end)

    lm = %ScriptedStreamLM{owner: self(), responses: responses}
    program = Imp.TestSupport.TwoStageOptimizerProgram.new(lm)

    listeners = [
      StreamListener.new(signature_field_name: :evidence),
      StreamListener.new(signature_field_name: :route)
    ]

    events =
      program
      |> Imp.stream(%{utterance: "Someone changed the invoice URL"},
        provider_stream: true,
        stream_listeners: listeners
      )
      |> Enum.to_list()

    assert_receive {:stream_request, first_prompt}
    assert first_prompt =~ "Someone changed the invoice URL"

    assert_receive {:stream_request, second_prompt}
    assert second_prompt =~ "security signal"

    chunks = Enum.filter(events, &match?(%StreamResponse{}, &1))
    prediction = List.last(events)

    assert Enum.any?(chunks, fn event ->
             event.metadata.predict_name == "analyze_intent" and
               event.metadata.signature_field_name == "evidence" and
               event.chunk == "security signal"
           end)

    assert Enum.any?(chunks, fn event ->
             event.metadata.predict_name == "classify_route" and
               event.metadata.signature_field_name == "route" and event.chunk == "R68"
           end)

    assert %Imp.Prediction{} = prediction
    assert Imp.get(prediction, :route) == "R68"
  end

  test "early consumer halt cancels the owned program and cleans the provider stream" do
    program = Imp.predict("question -> answer", lm: %BlockingStreamLM{owner: self()})

    assert [%StreamResponse{chunk: "[[ ## answer ## ]]\npartial"}] =
             program
             |> Imp.stream(%{question: "keep going"}, provider_stream: true)
             |> Enum.take(1)

    assert_receive :provider_opened
    assert_receive :provider_cleaned, 1_000
    refute_receive :provider_pulled_again
  end

  test "consumer death cleans the owned provider stream without another demand" do
    parent = self()
    program = Imp.predict("question -> answer", lm: %BlockingStreamLM{owner: parent})

    consumer =
      spawn(fn ->
        program
        |> Imp.stream(%{question: "keep going"}, provider_stream: true)
        |> Enum.each(fn event ->
          send(parent, {:consumer_event, event})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:consumer_event, %StreamResponse{chunk: "[[ ## answer ## ]]\npartial"}}
    Process.exit(consumer, :kill)

    assert_receive :provider_opened
    assert_receive :provider_cleaned, 1_000
    refute_receive :provider_pulled_again
  end

  test "streaming inside an admitted task reuses its sole worker without deadlock" do
    result =
      Imp.context([async_max_workers: 1], fn ->
        task =
          Imp.Tasks.async_nolink(fn ->
            program =
              Imp.predict("question -> answer",
                lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "pong"} end)
              )

            program
            |> Imp.stream(%{question: "say pong"}, provider_stream: true)
            |> Enum.to_list()
          end)

        Task.await(task, 1_000)
      end)

    assert [%Imp.Prediction{} = prediction] = result
    assert Imp.get(prediction, :answer) == "pong"
  end

  test "provider errors terminate the composed call without a false final prediction" do
    {:ok, responses} =
      Agent.start_link(fn ->
        [
          [
            %StreamResponse{chunk: "[[ ## evidence ## ]]\npartial"},
            %StreamResponse{chunk: {:error, :provider_failed}, done: true}
          ]
        ]
      end)

    program =
      Imp.TestSupport.TwoStageOptimizerProgram.new(%ScriptedStreamLM{
        owner: self(),
        responses: responses
      })

    listener = StreamListener.new(signature_field_name: :evidence)

    events =
      program
      |> Imp.stream(%{utterance: "broken transport"},
        provider_stream: true,
        stream_listeners: [listener]
      )
      |> Enum.to_list()

    assert Enum.count(events, &match?(%StreamResponse{chunk: {:error, :provider_failed}}, &1)) ==
             1

    refute Enum.any?(events, &match?(%Imp.Prediction{}, &1))
    assert_receive {:stream_request, _first_prompt}
    refute_receive {:stream_request, _second_prompt}
  end
end

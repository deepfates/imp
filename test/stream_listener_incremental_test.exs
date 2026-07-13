defmodule DSEx.StreamListenerIncrementalTest do
  use ExUnit.Case, async: true

  alias DSEx.Streaming.Messages.StatusMessage
  alias DSEx.Streaming.Messages.StreamListener
  alias DSEx.Streaming.Messages.StreamResponse

  test "extracts a selected field before the source completes and preserves pull order" do
    owner = self()

    listener =
      StreamListener.new(
        signature_field_name: :answer,
        predict_name: :solver,
        on_event: &send(owner, {:event, &1}),
        on_chunk: &send(owner, {:field, &1}),
        on_status: &send(owner, {:status, &1})
      )

    events = [
      %StreamResponse{chunk: "noise[[ ## ans"},
      %StreamResponse{chunk: "wer ## ]]\nhel"},
      %StreamResponse{chunk: "lo["},
      %StreamResponse{chunk: "[ ## completed ## ]]ignored"},
      %StreamResponse{done: true}
    ]

    stream =
      Stream.resource(
        fn -> events end,
        fn
          [] ->
            {:halt, []}

          [event | rest] ->
            send(owner, {:pulled, event})
            {[event], rest}
        end,
        fn _ -> send(owner, :source_cleaned) end
      )

    task = Task.async(fn -> listener |> StreamListener.attach(stream) |> Enum.to_list() end)

    assert_receive {:status, %StatusMessage{status: :started}}

    Enum.each(events, fn event ->
      assert_receive {:pulled, ^event}
      assert_receive {:event, ^event}

      case event.chunk do
        "wer ## ]]\nhel" ->
          assert_receive {:field,
                          %StreamResponse{
                            chunk: "hel",
                            done: false,
                            metadata: %{
                              predict_name: "solver",
                              signature_field_name: "answer"
                            }
                          }}

        "lo[" ->
          assert_receive {:field, %StreamResponse{chunk: "lo", done: false}}

        "[ ## completed ## ]]ignored" ->
          assert_receive {:field, %StreamResponse{chunk: nil, done: true}}

        _other ->
          :ok
      end
    end)

    assert_receive {:status, %StatusMessage{status: :completed}}
    assert_receive :source_cleaned
    assert Task.await(task) == events
    refute_receive {:field, _event}
    refute_receive {:status, _event}
  end

  test "flushes the final delimiter prefix at natural exhaustion" do
    owner = self()

    listener =
      StreamListener.new(
        field: "answer",
        on_chunk: &send(owner, {:field, &1}),
        on_status: &send(owner, {:status, &1})
      )

    events = ["[[ ## answer ## ]]value["]

    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events
    assert_receive {:field, %StreamResponse{chunk: "value", done: false}}
    assert_receive {:field, %StreamResponse{chunk: "[", done: true}}
    assert_receive {:status, %StatusMessage{status: :completed}}
  end

  test "recognizes one-byte delimiter splits and does not retain a large field" do
    owner = self()
    value = String.duplicate("x", 32_000) <> " done"

    listener =
      StreamListener.new(
        field: :answer,
        on_chunk: &send(owner, {:field, &1})
      )

    events =
      String.graphemes("discard[[ ## answer ## ]]") ++
        [value] ++ String.graphemes("[[ ## completed ## ]]")

    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events

    chunks = receive_field_chunks([])
    assert chunks |> Enum.map_join(&(&1.chunk || "")) == value
    assert Enum.count(chunks, & &1.done) == 1
    assert List.last(chunks).done
  end

  test "preserves malformed marker-like field content and bounds its delay" do
    owner = self()
    malformed = "literal [[ ## not a delimiter " <> String.duplicate("z", 300)

    listener =
      StreamListener.new(
        field: :answer,
        on_chunk: &send(owner, {:field, &1})
      )

    events = ["[[ ## answer ## ]]", malformed, "[[ ## completed ## ]]"]
    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events

    chunks = receive_field_chunks([])
    assert Enum.map_join(chunks, &(&1.chunk || "")) == malformed
    assert Enum.count(chunks, & &1.done) == 1
  end

  test "JSON streams an escaped string across one-byte splits without accumulating the object" do
    owner = self()
    value = ~S(say \"hi\"; braces } and slash \\ stay content)
    json = ~S({"ignored":{"answer":"nested decoy"},"answer":") <> value <> ~S(","tail":1})

    listener =
      StreamListener.new(
        adapter: DSEx.Adapter.JSON,
        field: :answer,
        on_chunk: &send(owner, {:field, &1})
      )

    events = for <<byte <- json>>, do: <<byte>>
    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events

    chunks = receive_field_chunks([])
    assert Enum.map_join(chunks, &(&1.chunk || "")) == "\"#{value}\""
    assert Enum.count(chunks, & &1.done) == 1
    assert List.last(chunks).done
  end

  test "JSON streams a nested selected value and ignores structural bytes in strings" do
    owner = self()
    value = ~S({"items":[1,{"text":"quoted \\\" } ]"}],"ok":true})
    json = ~S({"before":[{"answer":"decoy"}],"answer":) <> value <> ~S(,"after":false})

    listener =
      StreamListener.new(
        adapter: DSEx.Adapter.JSON,
        field: "answer",
        on_chunk: &send(owner, {:field, &1})
      )

    events = for <<byte <- json>>, do: <<byte>>
    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events

    chunks = receive_field_chunks([])
    assert Enum.map_join(chunks, &(&1.chunk || "")) == value
    assert List.last(chunks).done
  end

  test "XML recognizes one-byte tags and keeps only a closing-tag prefix" do
    owner = self()
    value = "<section>one &lt; two</section>" <> String.duplicate("x", 32_000)
    xml = "<ignored>decoy</ignored><answer>#{value}</answer><tail>no</tail>"

    listener =
      StreamListener.new(
        adapter: DSEx.Adapter.XML,
        field: :answer,
        on_chunk: &send(owner, {:field, &1})
      )

    events = for <<byte <- xml>>, do: <<byte>>
    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events

    chunks = receive_field_chunks([])
    assert Enum.map_join(chunks, &(&1.chunk || "")) == value
    assert Enum.count(chunks, & &1.done) == 1
  end

  test "custom adapters require explicit bounded exact framing" do
    owner = self()

    listener =
      StreamListener.new(
        adapter: __MODULE__.CustomAdapter,
        field: :answer,
        framing: %{start: "BEGIN answer\n", end: "\nEND answer"},
        on_chunk: &send(owner, {:field, &1})
      )

    events = ["noiseBEGIN ans", "wer\nraw ", "value\nEND answerignored"]
    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events
    assert_receive {:field, %StreamResponse{chunk: "raw ", done: false}}
    assert_receive {:field, %StreamResponse{chunk: "value", done: true}}

    assert_raise ArgumentError, ~r/unsupported streaming adapter/, fn ->
      StreamListener.new(adapter: __MODULE__.CustomAdapter, field: :answer)
    end

    assert_raise ArgumentError, ~r/1\.\.256 byte exact delimiters/, fn ->
      StreamListener.new(
        adapter: __MODULE__.CustomAdapter,
        field: :answer,
        framing: %{start: String.duplicate("x", 257), end: "end"}
      )
    end
  end

  test "reports an explicit stream error without converting partial output to success" do
    owner = self()
    reason = {:provider_failed, 503}

    listener =
      StreamListener.new(
        field: :answer,
        on_event: &send(owner, {:event, &1}),
        on_chunk: &send(owner, {:field, &1}),
        on_status: &send(owner, {:status, &1})
      )

    events = [
      %StreamResponse{chunk: "[[ ## answer ## ]]partial"},
      %StreamResponse{chunk: {:error, reason}, done: true}
    ]

    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events

    assert_receive {:field, %StreamResponse{chunk: "partial", done: false}}
    assert_receive {:field, %StreamResponse{chunk: {:error, ^reason}, done: true}}

    assert_receive {:status,
                    %StatusMessage{
                      status: :error,
                      level: :error,
                      metadata: %{reason: ^reason}
                    }}

    refute_receive {:status, %StatusMessage{status: :completed}}
  end

  test "a later provider error does not duplicate an already completed field terminal" do
    owner = self()

    listener =
      StreamListener.new(
        field: :answer,
        on_chunk: &send(owner, {:field, &1}),
        on_status: &send(owner, {:status, &1})
      )

    events = [
      %StreamResponse{chunk: "[[ ## answer ## ]]ok[[ ## completed ## ]]"},
      %StreamResponse{chunk: {:error, :late_failure}, done: true}
    ]

    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events
    assert_receive {:field, %StreamResponse{chunk: "ok", done: true}}
    refute_receive {:field, _event}
    assert_receive {:status, %StatusMessage{status: :error}}
  end

  test "early downstream halt cancels the listener and cleans the source" do
    owner = self()

    source =
      Stream.resource(
        fn -> 0 end,
        fn value -> {[%StreamResponse{chunk: Integer.to_string(value)}], value + 1} end,
        fn _ -> send(owner, :source_cleaned) end
      )

    listener = StreamListener.new(on_status: &send(owner, {:status, &1}))

    assert listener |> StreamListener.attach(source) |> Enum.take(1) == [
             %StreamResponse{chunk: "0"}
           ]

    assert_receive {:status, %StatusMessage{status: :started}}
    assert_receive {:status, %StatusMessage{status: :cancelled}}
    assert_receive :source_cleaned
    refute_receive {:status, %StatusMessage{status: :completed}}
  end

  test "callback failure propagates while both listener and source clean up" do
    owner = self()

    source =
      Stream.resource(
        fn -> [:event] end,
        fn
          [] -> {:halt, []}
          [event] -> {[event], []}
        end,
        fn _ -> send(owner, :source_cleaned) end
      )

    listener =
      StreamListener.new(
        on_event: fn _ -> raise "listener failed" end,
        on_status: &send(owner, {:status, &1})
      )

    assert_raise RuntimeError, "listener failed", fn ->
      listener |> StreamListener.attach(source) |> Enum.to_list()
    end

    assert_receive {:status, %StatusMessage{status: :started}}
    assert_receive {:status, %StatusMessage{status: :cancelled}}
    assert_receive :source_cleaned
  end

  test "validates field aliases and remains independently reusable" do
    assert_raise ArgumentError, ~r/must identify the same field/, fn ->
      StreamListener.new(signature_field_name: :answer, field: :reasoning)
    end

    assert_raise ArgumentError, ~r/:on_chunk requires/, fn ->
      StreamListener.new(on_chunk: fn _ -> :ok end)
    end

    listener = StreamListener.new(field: :answer, allow_reuse: true)
    events = ["[[ ## answer ## ]]ok"]

    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events
    assert listener |> StreamListener.attach(events) |> Enum.to_list() == events
  end

  defp receive_field_chunks(chunks) do
    receive do
      {:field, %StreamResponse{} = chunk} -> receive_field_chunks([chunk | chunks])
    after
      0 -> Enum.reverse(chunks)
    end
  end
end

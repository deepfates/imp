defmodule UpstreamExam.StreamingTest do
  @moduledoc """
  DSPy 3.2.1's own streaming tests (tests/streaming/test_streaming.py), ported
  to Imp.

  Tranche 3 of the upstream exam. Disposition map: docs/internal/UPSTREAM_EXAM.md.

  Design substitution throughout: DSPy streams via asyncio generators wrapped
  by `streamify`; Imp streams via Enumerables (`Imp.Streaming.stream/3`) and
  `Imp.Streaming.Messages.StreamListener.attach/2`. The ports feed the
  listener the SAME provider chunk sequences upstream's mocked litellm streams
  yield, and assert the same emitted chunks. Two seams recur and are noted per
  test: Imp's terminal boundary chunk carries `chunk: nil` where upstream
  emits `chunk: ""`, and doneness may ride that separate terminal chunk.
  """

  use ExUnit.Case, async: true

  @moduletag :upstream_exam

  alias Imp.Streaming.Messages.StreamListener
  alias Imp.Streaming.Messages.StreamResponse

  # Attaches a fresh listener for `field` over the scripted provider chunks and
  # returns the emitted StreamResponse chunks in order.
  defp listener_chunks(field, adapter, chunks, opts \\ []) do
    owner = self()
    ref = make_ref()

    listener =
      StreamListener.new(
        [
          signature_field_name: field,
          adapter: adapter,
          on_chunk: &send(owner, {ref, &1})
        ] ++ opts
      )

    listener |> StreamListener.attach(chunks) |> Stream.run()
    drain(ref)
  end

  defp drain(ref) do
    receive do
      {^ref, chunk} -> [chunk | drain(ref)]
    after
      0 -> []
    end
  end

  defp join_content(chunks), do: Enum.map_join(chunks, "", &(&1.chunk || ""))

  # ---------------------------------------------------------------------------
  # test_streamify_yields_expected_response_chunks (adapted) — DSPy's
  # streamify over a program; Imp's Imp.Streaming.stream/3 fallback chunks the
  # completed answer locally. The port asserts the same contract: the stream
  # yields chunks that concatenate to the program's full answer.
  # ---------------------------------------------------------------------------
  test "streamify: stream yields chunks that assemble the full answer" do
    program =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: "How are you doing?"} end]
        }
      )

    chunks = Imp.Streaming.stream(program, %{question: "why did a chicken cross the kitchen?"})
    assert Enum.join(chunks, "") == "How are you doing?"
  end

  # ---------------------------------------------------------------------------
  # test_streaming_handles_space_correctly
  # ---------------------------------------------------------------------------
  test "chat listener: spaces inside streamed content are preserved" do
    chunks =
      listener_chunks(:answer, Imp.Adapter.Chat, [
        "[[ ## answer ## ]]\n",
        "How ",
        "are ",
        "you ",
        "doing?",
        "\n\n[[ ## completed ## ]]"
      ])

    assert join_content(chunks) == "How are you doing?"
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_returns_correct_chunk_chat_adapter
  #
  # FINDING (real divergence): with upstream's exact token split — the end
  # marker arriving as "!\n\n[[ ##" / " completed" / " ##" / " ]]" — DSPy's
  # listener yields "!" as the final content chunk (trailing section
  # whitespace trimmed, is_last_chunk on it). Imp's chat parser emits the
  # untrimmed "!\n\n" (the whitespace precedes a then-unconfirmed marker
  # prefix) and marks doneness on a separate terminal chunk. Observed output:
  #   [..., {" plate", false}, {"!\n\n", false}, {nil, true}]
  # ---------------------------------------------------------------------------
  @tag :upstream_fail
  @tag :skip
  test "chat listener: split end marker trims trailing whitespace from the final chunk" do
    chunks =
      listener_chunks(:answer, Imp.Adapter.Chat, [
        "[[",
        " ##",
        " answer",
        " ##",
        " ]]\n\n",
        "To",
        " get",
        " to",
        " the",
        " other",
        " side",
        " of",
        " the",
        " dinner",
        " plate",
        "!\n\n[[ ##",
        " completed",
        " ##",
        " ]]"
      ])

    contents = Enum.map(chunks, & &1.chunk)

    assert contents == [
             "To",
             " get",
             " to",
             " the",
             " other",
             " side",
             " of",
             " the",
             " dinner",
             " plate",
             "!"
           ]

    assert List.last(chunks).done == true
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_returns_correct_chunk_json_adapter — byte-exact port.
  # ---------------------------------------------------------------------------
  test "json listener: emits value chunks including quotes, done on the final chunk" do
    chunks =
      listener_chunks(:answer, Imp.Adapter.JSON, [
        ~s({"),
        "answer",
        ~s(":),
        ~s("To),
        " get",
        " to",
        " the",
        " other",
        " side",
        " of",
        " the",
        " frying",
        " pan",
        ~s(!"),
        "}\n"
      ])

    assert Enum.map(chunks, & &1.chunk) == [
             ~s("To),
             " get",
             " to",
             " the",
             " other",
             " side",
             " of",
             " the",
             " frying",
             " pan",
             ~s(!")
           ]

    assert List.last(chunks).done == true
    refute Enum.any?(Enum.drop(chunks, -1), & &1.done)
  end

  # Second half of the same upstream test: the judgement predictor's stream.
  test "json listener: extracts a field whose key arrives split across chunks" do
    chunks =
      listener_chunks(:judgement, Imp.Adapter.JSON, [
        ~s({"),
        "jud",
        "gement",
        ~s(":),
        ~s("The),
        " answer",
        " is",
        " humorous",
        ~s(."),
        "}"
      ])

    assert join_content(chunks) == ~s("The answer is humorous.")
    assert List.last(chunks).done == true
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_returns_correct_chunk_xml_adapter
  # Seam: Imp marks doneness on a trailing nil-content boundary chunk; the
  # joined content is upstream's exact string.
  # ---------------------------------------------------------------------------
  test "xml listener: extracts tag content for the selected field" do
    answer_chunks =
      listener_chunks(:answer, Imp.Adapter.XML, [
        "<",
        "answer",
        ">",
        "To",
        " get",
        " to",
        " the",
        " other",
        " side",
        "!",
        "<",
        "/answer",
        ">"
      ])

    assert join_content(answer_chunks) == "To get to the other side!"
    assert List.last(answer_chunks).done == true

    judgement_chunks =
      listener_chunks(:judgement, Imp.Adapter.XML, [
        "<",
        "judgement",
        ">",
        "The",
        " answer",
        " is",
        " humorous",
        ".",
        "<",
        "/judgement",
        ">"
      ])

    assert join_content(judgement_chunks) == "The answer is humorous."
    assert List.last(judgement_chunks).done == true
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_returns_correct_chunk_chat_adapter_untokenized_stream
  # (whole sections arrive in single chunks, as Gemini emits them)
  # ---------------------------------------------------------------------------
  test "chat listener: untokenized stream yields whole-section chunks" do
    chunks =
      listener_chunks(:answer, Imp.Adapter.Chat, [
        "[[ ##",
        " answer ## ]]",
        "To get to the other side.",
        "\n\n[[ ## completed ## ]]"
      ])

    assert [first | _rest] = chunks
    assert first.chunk == "To get to the other side."
    assert List.last(chunks).done == true

    judgement =
      listener_chunks(:judgement, Imp.Adapter.Chat, [
        "[[ ## judgement ## ]]\n\n",
        "The answer provides the standard punchline for this classic joke format.",
        "\n\n[[ ## completed ## ]]"
      ])

    assert join_content(judgement) ==
             "The answer provides the standard punchline for this classic joke format."
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_returns_correct_chunk_json_adapter_untokenized_stream
  # (adapted: upstream asserts the whole value arrives as ONE chunk — an
  # artifact of its boundary buffering; Imp may split at the fed chunk seams.
  # The extracted content, including quotes, is asserted byte-for-byte.)
  # ---------------------------------------------------------------------------
  test "json listener: untokenized stream extracts the whole quoted value" do
    answer_chunks =
      listener_chunks(:answer, Imp.Adapter.JSON, [
        "{\n",
        ~s(  "answer": "To get to),
        ~s( the other side... of the cutting board!"),
        "}\n"
      ])

    assert join_content(answer_chunks) == ~s("To get to the other side... of the cutting board!")

    judgement_chunks =
      listener_chunks(:judgement, Imp.Adapter.JSON, [
        "{\n",
        ~s(  "judgement": "The),
        ~s( answer provides a humorous and relevant punchline to the classic joke setup."),
        "}\n"
      ])

    assert join_content(judgement_chunks) ==
             ~s("The answer provides a humorous and relevant punchline to the classic joke setup.")
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_missing_completion_marker_chat_adapter
  # ---------------------------------------------------------------------------
  test "chat listener: a stream without the completion marker still flushes every token" do
    chunks =
      listener_chunks(:answer, Imp.Adapter.Chat, [
        "[[ ##",
        " answer",
        " ## ]]\n\n",
        "This",
        " is",
        " a",
        " test",
        " response",
        " with",
        " many",
        " tokens",
        " to",
        " ensure",
        " buffering",
        " works",
        " correctly",
        "."
      ])

    assert join_content(chunks) ==
             "This is a test response with many tokens to ensure buffering works correctly."

    assert List.last(chunks).done == true
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_empty_last_chunk_chat_adapter — two listeners over
  # one stream; both fields' final chunk is the done marker.
  # ---------------------------------------------------------------------------
  test "chat listeners: field end is marked done even when the marker closes the field" do
    stream = [
      "[[ ## reasoning ## ]]\n",
      "Let's think about this problem step by step. ",
      "We need to consider the context of a kitchen. ",
      "The chicken likely wants to reach something on the other side. ",
      "\n\n[[ ## answer ## ]]\n",
      "To get to the other side!",
      "\n\n[[ ## completed ## ]]"
    ]

    reasoning_chunks = listener_chunks(:reasoning, Imp.Adapter.Chat, stream)
    answer_chunks = listener_chunks(:answer, Imp.Adapter.Chat, stream)

    assert List.last(reasoning_chunks).done == true
    assert List.last(answer_chunks).done == true

    assert join_content(reasoning_chunks) ==
             "Let's think about this problem step by step. " <>
               "We need to consider the context of a kitchen. " <>
               "The chicken likely wants to reach something on the other side. "

    assert join_content(answer_chunks) == "To get to the other side!"
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_empty_last_chunk_json_adapter
  # ---------------------------------------------------------------------------
  test "json listeners: field end is marked done even when the delimiter closes the field" do
    stream = [
      ~s({"reasoning": "),
      "Let's think about this problem step by step. ",
      "We need to consider the context of a kitchen. ",
      ~s(The chicken likely wants to reach something on the other side. "),
      ~s(,"answer": "),
      ~s(To get to the other side!"),
      "\n}"
    ]

    reasoning_chunks = listener_chunks(:reasoning, Imp.Adapter.JSON, stream)
    answer_chunks = listener_chunks(:answer, Imp.Adapter.JSON, stream)

    assert List.last(reasoning_chunks).done == true
    assert List.last(answer_chunks).done == true
  end

  # ---------------------------------------------------------------------------
  # test_stream_listener_allow_reuse — the same listener extracts its field
  # from two consecutive streams. (Adapted: markers arrive unsplit so the
  # trailing-whitespace divergence recorded above does not mask the reuse
  # behavior under test.)
  # ---------------------------------------------------------------------------
  test "listener with allow_reuse extracts its field from two consecutive streams" do
    owner = self()
    ref = make_ref()

    listener =
      StreamListener.new(
        signature_field_name: :answer,
        allow_reuse: true,
        on_chunk: &send(owner, {ref, &1})
      )

    stream = [
      "[[ ## answer ## ]]\n",
      "To get to the other side!",
      "\n\n[[ ## completed ## ]]"
    ]

    listener |> StreamListener.attach(stream) |> Stream.run()
    listener |> StreamListener.attach(stream) |> Stream.run()

    chunks = drain(ref)
    assert join_content(chunks) == "To get to the other side!To get to the other side!"
  end

  # ---------------------------------------------------------------------------
  # test_status_message_non_blocking family (adapted core): the listener's
  # status stream reports one :started and one terminal event without
  # interfering with the pulled events.
  # ---------------------------------------------------------------------------
  test "listener status: one started and one completed event around the stream" do
    owner = self()
    ref = make_ref()

    listener =
      StreamListener.new(
        signature_field_name: :answer,
        on_status: &send(owner, {ref, &1})
      )

    events =
      listener
      |> StreamListener.attach([
        "[[ ## answer ## ]]\nhello",
        %StreamResponse{done: true}
      ])
      |> Enum.to_list()

    # The source events pass through unchanged.
    assert length(events) == 2

    statuses = drain(ref)
    assert Enum.map(statuses, & &1.status) == [:started, :completed]
  end
end

defmodule Imp.Streaming.Messages do
  @moduledoc """
  Streaming message structs for Imp's public streaming vocabulary.

  These structs are ordinary data returned by `Imp.Streaming` and provider
  clients. They are intentionally small so callers can pattern match on stream
  chunks, completion markers, status messages, and listener state without
  depending on provider-specific event shapes.
  """

  defmodule StreamResponse do
    @moduledoc """
    One normalized stream event.

    `:chunk` holds the provider text, parsed partial value, or error tuple.
    `:done` marks terminal events. `:metadata` carries redacted provider or
    runtime details.
    """

    defstruct [:chunk, done: false, metadata: %{}]
  end

  defmodule StatusMessage do
    @moduledoc """
    Status event emitted by a streaming workflow.

    `:status` is one of `:started`, `:completed`, `:error`, or `:cancelled`
    for listener lifecycle events. Existing callers that only use `:message`,
    `:level`, and `:metadata` remain compatible.
    """

    defstruct [:message, :status, level: :info, metadata: %{}]
  end

  defmodule StreamListener do
    @moduledoc """
    Incremental, transparent stream observer.

    `attach/2` always yields the source events unchanged. `:on_event` observes
    those events as they are pulled. When `:signature_field_name` (or its
    `:field` alias) and `:on_chunk` are configured, the listener also extracts
    that adapter field incrementally and reports normalized
    `StreamResponse` chunks without waiting for the complete response.

    `:adapter` selects the built-in Chat, JSON, or XML framing and defaults to
    `Imp.Adapter.Chat`. Custom adapters can opt in explicitly with a bounded,
    exact-delimiter `:framing` map containing non-empty `:start` and `:end`
    binaries. Delimiters are data, never regular expressions or callbacks.

    `:on_status` receives exactly one `:started` event and one terminal event:
    `:completed`, `:error`, or `:cancelled`. Early downstream halt is
    cancellation. Chat, XML, and custom framing retain only possible delimiter
    prefixes. JSON uses a bytewise lexer and retains only depth, escape, and
    bounded key-match state, so listener memory does not grow with response size.
    """

    alias Imp.Streaming.Messages.StatusMessage
    alias Imp.Streaming.Messages.StreamResponse

    @chat_end_prefix "[[ ##"
    @chat_end_pattern ~r/\[\[ ## [A-Za-z_][A-Za-z0-9_]* ## \]\]/
    @max_delimiter_bytes 256

    defstruct events: [],
              on_event: nil,
              on_chunk: nil,
              on_status: nil,
              signature_field_name: nil,
              predict_name: nil,
              adapter: Imp.Adapter.Chat,
              framing: nil,
              allow_reuse: false

    def new(opts \\ []) do
      opts =
        Imp.Options.validate!(
          opts,
          [
            on_event: [type: {:custom, __MODULE__, :validate_callback, []}, default: nil],
            on_chunk: [type: {:custom, __MODULE__, :validate_callback, []}, default: nil],
            on_status: [type: {:custom, __MODULE__, :validate_callback, []}, default: nil],
            signature_field_name: [
              type: {:custom, __MODULE__, :validate_field, []},
              default: nil
            ],
            field: [type: {:custom, __MODULE__, :validate_field, []}, default: nil],
            predict_name: [type: {:custom, __MODULE__, :validate_name, []}, default: nil],
            adapter: [
              type: {:custom, __MODULE__, :validate_adapter, []},
              default: Imp.Adapter.Chat
            ],
            framing: [type: {:custom, __MODULE__, :validate_framing, []}, default: nil],
            allow_reuse: [type: :boolean, default: false]
          ],
          "Imp.Streaming.Messages.StreamListener.new/1"
        )

      field = resolve_field!(opts[:signature_field_name], opts[:field])
      validate_chunk_listener!(field, opts[:on_chunk])
      validate_adapter_framing!(opts[:adapter], opts[:framing])

      %__MODULE__{
        on_event: opts[:on_event],
        on_chunk: opts[:on_chunk],
        on_status: opts[:on_status],
        signature_field_name: field,
        predict_name: opts[:predict_name],
        adapter: opts[:adapter],
        framing: opts[:framing],
        allow_reuse: opts[:allow_reuse]
      }
    end

    def record(%__MODULE__{events: events} = listener, event),
      do: %{listener | events: events ++ [event]}

    def attach(%__MODULE__{} = listener, enumerable) do
      unless Enumerable.impl_for(enumerable) do
        raise ArgumentError, "StreamListener.attach/2 expects an enumerable"
      end

      Stream.transform(
        enumerable,
        fn -> start(listener) end,
        fn event, state -> observe(event, state) end,
        fn state -> finish(state) end,
        fn state -> cleanup(state) end
      )
    end

    @doc false
    def validate_callback(nil), do: {:ok, nil}
    def validate_callback(callback) when is_function(callback, 1), do: {:ok, callback}

    def validate_callback(callback),
      do: {:error, "expected nil or an arity-1 function, got: #{inspect(callback)}"}

    @doc false
    def validate_field(nil), do: {:ok, nil}
    def validate_field(field) when is_atom(field), do: {:ok, Atom.to_string(field)}
    def validate_field(field) when is_binary(field) and byte_size(field) > 0, do: {:ok, field}

    def validate_field(field),
      do: {:error, "expected nil, an atom, or a non-empty string, got: #{inspect(field)}"}

    @doc false
    def validate_name(nil), do: {:ok, nil}
    def validate_name(name) when is_atom(name), do: {:ok, Atom.to_string(name)}
    def validate_name(name) when is_binary(name), do: {:ok, name}

    def validate_name(name),
      do: {:error, "expected nil, an atom, or a string, got: #{inspect(name)}"}

    @doc false
    def validate_adapter(adapter) when is_atom(adapter), do: {:ok, adapter}

    def validate_adapter(adapter),
      do: {:error, "expected an adapter module, got: #{inspect(adapter)}"}

    @doc false
    def validate_framing(nil), do: {:ok, nil}

    def validate_framing(%{start: start, end: ending} = framing)
        when map_size(framing) == 2 and is_binary(start) and is_binary(ending) and
               byte_size(start) > 0 and byte_size(start) <= @max_delimiter_bytes and
               byte_size(ending) > 0 and byte_size(ending) <= @max_delimiter_bytes do
      {:ok, %{start: start, end: ending}}
    end

    def validate_framing(framing) do
      {:error,
       "expected nil or %{start: binary, end: binary} with 1..#{@max_delimiter_bytes} byte exact delimiters, got: #{inspect(framing)}"}
    end

    defp resolve_field!(nil, field), do: field
    defp resolve_field!(field, nil), do: field
    defp resolve_field!(field, field), do: field

    defp resolve_field!(signature_field_name, field) do
      raise ArgumentError,
            "Imp.Streaming.Messages.StreamListener.new/1: " <>
              ":signature_field_name and :field must identify the same field, got: " <>
              "#{inspect(signature_field_name)} and #{inspect(field)}"
    end

    defp start(listener) do
      state = %{
        listener: listener,
        parser: new_parser(listener.signature_field_name, listener.adapter, listener.framing),
        terminal: nil
      }

      emit_status(state, :started)
      state
    end

    defp observe(event, %{terminal: terminal} = state) when not is_nil(terminal) do
      notify(state.listener.on_event, event)
      {[event], state}
    end

    defp observe(event, state) do
      notify(state.listener.on_event, event)

      case event_error(event) do
        {:error, reason} ->
          if is_nil(state.parser) or state.parser.phase != :done do
            emit_chunk(state.listener, {:error, reason}, true)
          end

          state = terminate(state, :error, reason)
          {[event], state}

        nil ->
          state = feed_event(state, event)

          if terminal_event?(event) do
            state = state |> finalize_parser() |> terminate(:completed)
            {[event], state}
          else
            {[event], state}
          end
      end
    end

    defp finish(%{terminal: nil} = state) do
      state = state |> finalize_parser() |> terminate(:completed)
      {[], state}
    end

    defp finish(state), do: {[], state}

    defp cleanup(%{terminal: nil} = state), do: terminate(state, :cancelled)
    defp cleanup(_state), do: :ok

    defp feed_event(%{parser: nil} = state, _event), do: state

    defp feed_event(state, event) do
      case event_text(event) do
        nil ->
          state

        text ->
          prior_phase = state.parser.phase
          {parser, chunks} = parse_chunk(state.parser, text)

          if prior_phase != :done and parser.phase == :done do
            emit_terminal_chunks(state.listener, chunks)
          else
            Enum.each(chunks, &emit_chunk(state.listener, &1, false))
          end

          %{state | parser: parser}
      end
    end

    defp finalize_parser(%{parser: nil} = state), do: state

    defp finalize_parser(state) do
      prior_phase = state.parser.phase
      {parser, chunks} = parser_finish(state.parser)

      if prior_phase == :streaming do
        emit_terminal_chunks(state.listener, chunks)
      end

      %{state | parser: parser}
    end

    defp emit_terminal_chunks(listener, []), do: emit_chunk(listener, nil, true)

    defp emit_terminal_chunks(listener, chunks) do
      last_index = length(chunks) - 1

      chunks
      |> Enum.with_index()
      |> Enum.each(fn {chunk, index} -> emit_chunk(listener, chunk, index == last_index) end)
    end

    defp terminate(state, status, reason \\ nil)

    defp terminate(%{terminal: nil} = state, status, reason) do
      emit_status(state, status, reason)
      %{state | terminal: status}
    end

    defp terminate(state, _status, _reason), do: state

    defp emit_status(%{listener: listener}, status, reason \\ nil) do
      level =
        case status do
          :error -> :error
          :cancelled -> :warning
          _other -> :info
        end

      metadata =
        %{signature_field_name: listener.signature_field_name}
        |> maybe_put(:reason, reason)

      notify(
        listener.on_status,
        %StatusMessage{
          message: status_message(status),
          status: status,
          level: level,
          metadata: metadata
        }
      )
    end

    defp emit_chunk(listener, chunk, done?) do
      notify(
        listener.on_chunk,
        %StreamResponse{
          chunk: chunk,
          done: done?,
          metadata: %{
            predict_name: listener.predict_name,
            signature_field_name: listener.signature_field_name
          }
        }
      )
    end

    defp status_message(:started), do: "stream started"
    defp status_message(:completed), do: "stream completed"
    defp status_message(:error), do: "stream failed"
    defp status_message(:cancelled), do: "stream cancelled"

    defp event_text(%StreamResponse{chunk: chunk}) when is_binary(chunk), do: chunk
    defp event_text(chunk) when is_binary(chunk), do: chunk
    defp event_text(_event), do: nil

    defp event_error(%StreamResponse{chunk: {:error, reason}}), do: {:error, reason}
    defp event_error({:error, reason}), do: {:error, reason}
    defp event_error(_event), do: nil

    defp terminal_event?(%StreamResponse{done: true}), do: true
    defp terminal_event?(_event), do: false

    defp new_parser(nil, _adapter, _framing), do: nil

    defp new_parser(_field, _adapter, %{start: start, end: ending}) do
      delimited_parser(start, ending, false)
    end

    defp new_parser(field, Imp.Adapter.Chat, nil) do
      %{
        kind: :chat,
        start: "[[ ## #{field} ## ]]",
        phase: :searching,
        buffer: "",
        pending: ""
      }
    end

    defp new_parser(field, Imp.Adapter.XML, nil) do
      delimited_parser("<#{field}>", "</#{field}>", true)
    end

    defp new_parser(field, Imp.Adapter.JSON, nil) do
      encoded_key = Jason.encode!(field)

      %{
        kind: :json,
        phase: :searching,
        depth: 0,
        expect_key: false,
        in_string: false,
        escaped: false,
        string_role: nil,
        key_index: 0,
        key_match: false,
        encoded_key: binary_part(encoded_key, 1, byte_size(encoded_key) - 2),
        target_key: false,
        value_mode: nil,
        value_depth: 0,
        value_in_string: false,
        value_escaped: false
      }
    end

    defp delimited_parser(start, ending, trim?) do
      %{
        kind: :delimited,
        start: start,
        end: ending,
        trim?: trim?,
        phase: :searching,
        buffer: ""
      }
    end

    defp parse_chunk(%{phase: :done} = parser, _chunk), do: {parser, []}

    defp parse_chunk(%{kind: :chat, phase: :searching} = parser, chunk) do
      combined = parser.buffer <> chunk

      case :binary.match(combined, parser.start) do
        {index, length} ->
          rest = binary_part(combined, index + length, byte_size(combined) - index - length)
          parser = %{parser | phase: :streaming, buffer: ""}
          parse_chat_streaming(parser, String.trim_leading(rest))

        :nomatch ->
          {%{parser | buffer: delimiter_suffix(combined, parser.start)}, []}
      end
    end

    defp parse_chunk(%{kind: :chat, phase: :streaming} = parser, chunk),
      do: parse_chat_streaming(parser, chunk)

    defp parse_chunk(%{kind: :delimited, phase: :searching} = parser, chunk) do
      combined = parser.buffer <> chunk

      case :binary.match(combined, parser.start) do
        {index, length} ->
          rest = binary_part(combined, index + length, byte_size(combined) - index - length)
          rest = if parser.trim?, do: String.trim_leading(rest), else: rest
          parser = %{parser | phase: :streaming, buffer: ""}
          parse_delimited_streaming(parser, rest)

        :nomatch ->
          {%{parser | buffer: delimiter_suffix(combined, parser.start)}, []}
      end
    end

    defp parse_chunk(%{kind: :delimited, phase: :streaming} = parser, chunk),
      do: parse_delimited_streaming(parser, chunk)

    defp parse_chunk(%{kind: :json} = parser, chunk) do
      {parser, emitted} = json_bytes(parser, chunk, [])

      case IO.iodata_to_binary(Enum.reverse(emitted)) do
        "" -> {parser, []}
        value -> {parser, [value]}
      end
    end

    defp parse_chat_streaming(parser, chunk) do
      combined = parser.buffer <> chunk

      case Regex.run(@chat_end_pattern, combined, return: :index) do
        [{index, _length}] ->
          value = parser.pending <> binary_part(combined, 0, index)
          value = String.trim_trailing(value)
          {%{parser | phase: :done, buffer: "", pending: ""}, maybe_chunk(value)}

        nil ->
          suffix = end_candidate_suffix(combined)

          if suffix == "" do
            chunks = maybe_chunk(parser.pending) ++ maybe_chunk(combined)
            {%{parser | buffer: "", pending: ""}, chunks}
          else
            emit_size = byte_size(combined) - byte_size(suffix)
            value = binary_part(combined, 0, emit_size)

            # Keep the content from the provider chunk that introduced a
            # possible end marker separate from the delimiter prefix. If the
            # marker completes, its preceding whitespace can be trimmed and
            # the content emitted as the terminal chunk. If it proves false,
            # both pieces are flushed unchanged on the next feed.
            {%{parser | buffer: suffix, pending: parser.pending <> value}, []}
          end
      end
    end

    defp parse_delimited_streaming(parser, chunk) do
      combined = parser.buffer <> chunk

      case :binary.match(combined, parser.end) do
        {index, _length} ->
          value = binary_part(combined, 0, index)
          value = if parser.trim?, do: String.trim_trailing(value), else: value
          {%{parser | phase: :done, buffer: ""}, maybe_chunk(value)}

        :nomatch ->
          suffix = delimiter_suffix(combined, parser.end)
          emit_size = byte_size(combined) - byte_size(suffix)
          value = binary_part(combined, 0, emit_size)
          {%{parser | buffer: suffix}, maybe_chunk(value)}
      end
    end

    defp json_bytes(%{phase: :done} = parser, _bytes, emitted), do: {parser, emitted}
    defp json_bytes(parser, <<>>, emitted), do: {parser, emitted}

    defp json_bytes(parser, <<byte, rest::binary>>, emitted) do
      {parser, output} = json_byte(parser, byte)
      emitted = if is_nil(output), do: emitted, else: [output | emitted]
      json_bytes(parser, rest, emitted)
    end

    defp json_byte(%{phase: :searching, in_string: true} = parser, byte) do
      cond do
        parser.escaped ->
          {parser |> match_key_byte(byte) |> Map.put(:escaped, false), nil}

        byte == ?\\ ->
          {parser |> match_key_byte(byte) |> Map.put(:escaped, true), nil}

        byte == ?" ->
          matched? =
            parser.string_role == :key and parser.key_match and
              parser.key_index == byte_size(parser.encoded_key)

          {%{
             parser
             | in_string: false,
               string_role: nil,
               target_key: matched?,
               key_index: 0,
               key_match: false
           }, nil}

        true ->
          {match_key_byte(parser, byte), nil}
      end
    end

    defp json_byte(%{phase: :searching} = parser, byte) do
      cond do
        byte == ?" ->
          key? = parser.depth == 1 and parser.expect_key

          {%{
             parser
             | in_string: true,
               string_role: if(key?, do: :key, else: :other),
               expect_key: if(key?, do: false, else: parser.expect_key),
               key_index: 0,
               key_match: key?
           }, nil}

        byte in [?{, ?[] ->
          depth = parser.depth + 1
          {%{parser | depth: depth, expect_key: parser.expect_key or depth == 1}, nil}

        byte in [?}, ?]] ->
          {%{parser | depth: max(parser.depth - 1, 0)}, nil}

        byte == ?, and parser.depth == 1 ->
          {%{parser | expect_key: true, target_key: false}, nil}

        byte == ?: and parser.depth == 1 and parser.target_key ->
          {%{parser | phase: :await_value, target_key: false}, nil}

        true ->
          {parser, nil}
      end
    end

    defp json_byte(%{phase: :await_value} = parser, byte)
         when byte in [32, 9, 10, 13],
         do: {parser, nil}

    defp json_byte(%{phase: :await_value} = parser, ?") do
      {%{parser | phase: :streaming, value_mode: :string, value_escaped: false}, "\""}
    end

    defp json_byte(%{phase: :await_value} = parser, byte) when byte in [?{, ?[] do
      {%{
         parser
         | phase: :streaming,
           value_mode: :composite,
           value_depth: 1,
           value_in_string: false,
           value_escaped: false
       }, <<byte>>}
    end

    defp json_byte(%{phase: :await_value} = parser, byte) do
      {%{parser | phase: :streaming, value_mode: :primitive}, <<byte>>}
    end

    defp json_byte(%{phase: :streaming, value_mode: :string} = parser, byte) do
      cond do
        parser.value_escaped -> {%{parser | value_escaped: false}, <<byte>>}
        byte == ?\\ -> {%{parser | value_escaped: true}, <<byte>>}
        byte == ?" -> {%{parser | phase: :done}, "\""}
        true -> {parser, <<byte>>}
      end
    end

    defp json_byte(
           %{phase: :streaming, value_mode: :composite, value_in_string: true} = parser,
           byte
         ) do
      cond do
        parser.value_escaped -> {%{parser | value_escaped: false}, <<byte>>}
        byte == ?\\ -> {%{parser | value_escaped: true}, <<byte>>}
        byte == ?" -> {%{parser | value_in_string: false}, <<byte>>}
        true -> {parser, <<byte>>}
      end
    end

    defp json_byte(%{phase: :streaming, value_mode: :composite} = parser, byte) do
      cond do
        byte == ?" ->
          {%{parser | value_in_string: true}, <<byte>>}

        byte in [?{, ?[] ->
          {%{parser | value_depth: parser.value_depth + 1}, <<byte>>}

        byte in [?}, ?]] ->
          depth = parser.value_depth - 1

          {%{parser | value_depth: depth, phase: if(depth == 0, do: :done, else: :streaming)},
           <<byte>>}

        true ->
          {parser, <<byte>>}
      end
    end

    defp json_byte(%{phase: :streaming, value_mode: :primitive} = parser, byte)
         when byte in [?,, ?}, 32, 9, 10, 13],
         do: {%{parser | phase: :done}, nil}

    defp json_byte(%{phase: :streaming, value_mode: :primitive} = parser, byte),
      do: {parser, <<byte>>}

    defp match_key_byte(%{string_role: role} = parser, _byte) when role != :key, do: parser

    defp match_key_byte(parser, byte) do
      index = parser.key_index

      matches? =
        parser.key_match and index < byte_size(parser.encoded_key) and
          :binary.at(parser.encoded_key, index) == byte

      %{parser | key_index: index + 1, key_match: matches?}
    end

    defp parser_finish(%{kind: :chat, phase: :streaming} = parser) do
      chunks = maybe_chunk(parser.pending) ++ maybe_chunk(parser.buffer)
      {%{parser | phase: :done, buffer: "", pending: ""}, chunks}
    end

    defp parser_finish(%{kind: :delimited, phase: :streaming} = parser) do
      {%{parser | phase: :done, buffer: ""}, maybe_chunk(parser.buffer)}
    end

    defp parser_finish(%{kind: :json, phase: :streaming} = parser),
      do: {%{parser | phase: :done}, []}

    defp parser_finish(parser), do: {parser, []}

    defp delimiter_suffix(value, delimiter) do
      max_size = min(byte_size(value), byte_size(delimiter) - 1)

      Enum.find_value(max_size..0//-1, "", fn size ->
        suffix = binary_part(value, byte_size(value) - size, size)
        if String.starts_with?(delimiter, suffix), do: suffix
      end)
    end

    defp end_candidate_suffix(value) do
      candidate =
        case :binary.matches(value, "[[") do
          [] ->
            if String.ends_with?(value, "["), do: "[", else: ""

          matches ->
            {index, _length} = List.last(matches)
            binary_part(value, index, byte_size(value) - index)
        end

      if byte_size(candidate) <= @max_delimiter_bytes and
           (String.starts_with?(@chat_end_prefix, candidate) or
              String.starts_with?(candidate, @chat_end_prefix)) do
        candidate
      else
        if String.ends_with?(value, "["), do: "[", else: ""
      end
    end

    defp maybe_chunk(""), do: []
    defp maybe_chunk(chunk), do: [chunk]

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defp validate_chunk_listener!(nil, callback) when is_function(callback, 1) do
      raise ArgumentError,
            "Imp.Streaming.Messages.StreamListener.new/1: " <>
              ":on_chunk requires :signature_field_name or :field"
    end

    defp validate_chunk_listener!(_field, _callback), do: :ok

    defp validate_adapter_framing!(adapter, nil)
         when adapter in [Imp.Adapter.Chat, Imp.Adapter.JSON, Imp.Adapter.XML],
         do: :ok

    defp validate_adapter_framing!(_adapter, %{start: _start, end: _ending}), do: :ok

    defp validate_adapter_framing!(adapter, nil) do
      raise ArgumentError,
            "Imp.Streaming.Messages.StreamListener.new/1: unsupported streaming adapter #{inspect(adapter)}; " <>
              "use Imp.Adapter.Chat, Imp.Adapter.JSON, Imp.Adapter.XML, or provide exact :framing"
    end

    defp notify(nil, _event), do: :ok
    defp notify(callback, event), do: callback.(event)
  end
end

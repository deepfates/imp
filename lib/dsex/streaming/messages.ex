defmodule DSEx.Streaming.Messages do
  @moduledoc """
  Streaming message structs for DSEx's public streaming vocabulary.

  These structs are ordinary data returned by `DSEx.Streaming` and provider
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

  defmodule StatusMessageProvider do
    @moduledoc "In-memory status message accumulator for tests and local tools."

    defstruct messages: []

    def push(%__MODULE__{messages: messages} = provider, message) do
      %{provider | messages: messages ++ [message]}
    end
  end

  defmodule StreamListener do
    @moduledoc """
    Incremental, transparent stream observer.

    `attach/2` always yields the source events unchanged. `:on_event` observes
    those events as they are pulled. When `:signature_field_name` (or its
    `:field` alias) and `:on_chunk` are configured, the listener also extracts
    that ChatAdapter field incrementally and reports normalized
    `StreamResponse` chunks without waiting for the complete response.

    `:on_status` receives exactly one `:started` event and one terminal event:
    `:completed`, `:error`, or `:cancelled`. Early downstream halt is
    cancellation. The implementation retains only possible delimiter prefixes,
    so listener memory does not grow with response size.
    """

    alias DSEx.Streaming.Messages.StatusMessage
    alias DSEx.Streaming.Messages.StreamResponse

    @chat_end_prefix "[[ ##"
    @chat_end_pattern ~r/\[\[ ## [A-Za-z_][A-Za-z0-9_]* ## \]\]/
    @max_delimiter_bytes 256

    defstruct events: [],
              on_event: nil,
              on_chunk: nil,
              on_status: nil,
              signature_field_name: nil,
              predict_name: nil,
              allow_reuse: false

    def new(opts \\ []) do
      opts =
        DSEx.Options.validate!(
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
            allow_reuse: [type: :boolean, default: false]
          ],
          "DSEx.Streaming.Messages.StreamListener.new/1"
        )

      field = resolve_field!(opts[:signature_field_name], opts[:field])
      validate_chunk_listener!(field, opts[:on_chunk])

      %__MODULE__{
        on_event: opts[:on_event],
        on_chunk: opts[:on_chunk],
        on_status: opts[:on_status],
        signature_field_name: field,
        predict_name: opts[:predict_name],
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

    def validate_callback(nil), do: {:ok, nil}
    def validate_callback(callback) when is_function(callback, 1), do: {:ok, callback}

    def validate_callback(callback),
      do: {:error, "expected nil or an arity-1 function, got: #{inspect(callback)}"}

    def validate_field(nil), do: {:ok, nil}
    def validate_field(field) when is_atom(field), do: {:ok, Atom.to_string(field)}
    def validate_field(field) when is_binary(field) and byte_size(field) > 0, do: {:ok, field}

    def validate_field(field),
      do: {:error, "expected nil, an atom, or a non-empty string, got: #{inspect(field)}"}

    def validate_name(nil), do: {:ok, nil}
    def validate_name(name) when is_atom(name), do: {:ok, Atom.to_string(name)}
    def validate_name(name) when is_binary(name), do: {:ok, name}

    def validate_name(name),
      do: {:error, "expected nil, an atom, or a string, got: #{inspect(name)}"}

    defp resolve_field!(nil, field), do: field
    defp resolve_field!(field, nil), do: field
    defp resolve_field!(field, field), do: field

    defp resolve_field!(signature_field_name, field) do
      raise ArgumentError,
            "DSEx.Streaming.Messages.StreamListener.new/1: " <>
              ":signature_field_name and :field must identify the same field, got: " <>
              "#{inspect(signature_field_name)} and #{inspect(field)}"
    end

    defp start(listener) do
      state = %{
        listener: listener,
        parser: new_parser(listener.signature_field_name),
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

    defp new_parser(nil), do: nil

    defp new_parser(field) do
      %{start: "[[ ## #{field} ## ]]", phase: :searching, buffer: ""}
    end

    defp parse_chunk(%{phase: :done} = parser, _chunk), do: {parser, []}

    defp parse_chunk(%{phase: :searching} = parser, chunk) do
      combined = parser.buffer <> chunk

      case :binary.match(combined, parser.start) do
        {index, length} ->
          rest = binary_part(combined, index + length, byte_size(combined) - index - length)
          parser = %{parser | phase: :streaming, buffer: ""}
          parse_streaming(parser, String.trim_leading(rest))

        :nomatch ->
          {%{parser | buffer: delimiter_suffix(combined, parser.start)}, []}
      end
    end

    defp parse_chunk(%{phase: :streaming} = parser, chunk), do: parse_streaming(parser, chunk)

    defp parse_streaming(parser, chunk) do
      combined = parser.buffer <> chunk

      case Regex.run(@chat_end_pattern, combined, return: :index) do
        [{index, _length}] ->
          value = combined |> binary_part(0, index) |> String.trim_trailing()
          {%{parser | phase: :done, buffer: ""}, maybe_chunk(value)}

        nil ->
          suffix = end_candidate_suffix(combined)
          emit_size = byte_size(combined) - byte_size(suffix)
          value = binary_part(combined, 0, emit_size)
          {%{parser | buffer: suffix}, maybe_chunk(value)}
      end
    end

    defp parser_finish(%{phase: :streaming} = parser) do
      {%{parser | phase: :done, buffer: ""}, maybe_chunk(parser.buffer)}
    end

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
            "DSEx.Streaming.Messages.StreamListener.new/1: " <>
              ":on_chunk requires :signature_field_name or :field"
    end

    defp validate_chunk_listener!(_field, _callback), do: :ok

    defp notify(nil, _event), do: :ok
    defp notify(callback, event), do: callback.(event)
  end
end

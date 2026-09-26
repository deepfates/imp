defmodule Imp.Streaming.Execution do
  @moduledoc false

  alias Imp.Streaming.Messages.StreamListener
  alias Imp.Streaming.Messages.StreamResponse

  @context_key {__MODULE__, :context}

  def context, do: Process.get(@context_key)

  def with_context(context, fun) when is_map(context) and is_function(fun, 0) do
    previous = Process.get(@context_key, :unset)
    Process.put(@context_key, context)

    try do
      fun.()
    after
      case previous do
        :unset -> Process.delete(@context_key)
        value -> Process.put(@context_key, value)
      end
    end
  end

  def generate(%Imp.Predict{} = predict, lm, messages, opts) do
    case stream_target(predict) do
      {:ok, name, context} -> stream_generate(context, name, lm, messages, opts)
      :ordinary -> Imp.LM.generate(lm, messages, opts)
    end
  end

  defp stream_target(%Imp.Predict{metadata: metadata}) do
    with %{targets: targets} = context when is_map(targets) <- context(),
         name when not is_nil(name) <-
           Map.get(metadata, :stream_predict_name) ||
             Map.get(metadata, :optimizer_predictor_name),
         true <- Map.has_key?(targets, normalize_name(name)) do
      {:ok, normalize_name(name), context}
    else
      _other -> :ordinary
    end
  end

  defp stream_generate(context, name, %module{} = lm, messages, opts) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :stream, 3) ->
        module.stream(lm, messages, unrecorded(opts))
        |> consume_stream(context, name, lm)

      true ->
        Imp.LM.generate(lm, messages, opts)
    end
  end

  defp stream_generate(context, name, module, messages, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :stream, 3) do
      module.stream(module, messages, unrecorded(opts))
      |> consume_stream(context, name, module)
    else
      Imp.LM.generate(module, messages, opts)
    end
  end

  defp stream_generate(_context, _name, lm, messages, opts),
    do: Imp.LM.generate(lm, messages, opts)

  # A streamed call goes to the provider without `Imp.LM.generate/3`, which is
  # where `:purpose` is taken off and recorded, and it emits no request event to
  # record it on; it is dropped so it is never sent.
  defp unrecorded(opts), do: Keyword.delete(opts, :purpose)

  defp consume_stream(stream, context, name, lm) do
    stream = attach_listeners(stream, context, name)

    result =
      Enum.reduce_while(stream, {:ok, [], %{}}, fn
        %StreamResponse{chunk: {:error, reason}}, _acc ->
          {:halt, {:error, reason}}

        %StreamResponse{} = event, {:ok, chunks, metadata} ->
          maybe_emit_raw(context, name, event)

          {:cont, {:ok, collect_chunk(event.chunk, chunks), collect_metadata(event, metadata)}}

        event, {:ok, chunks, metadata} ->
          maybe_emit_raw(context, name, event)
          {:cont, {:ok, collect_chunk(event, chunks), metadata}}
      end)

    case result do
      {:ok, chunks, metadata} ->
        chunks
        |> materialize_chunks()
        |> envelope(normalize_metadata(lm, metadata))
        |> then(&{:ok, &1})
        |> record_usage()

      {:error, _reason} = error ->
        error
    end
  rescue
    error -> {:error, {:lm_stream_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:lm_stream_failed, inspect({kind, reason})}}
  end

  defp attach_listeners(stream, %{targets: targets} = context, name) do
    case Map.fetch!(targets, name) do
      :raw -> stream
      listeners -> Enum.reduce(listeners, stream, &attach_listener(&1, &2, context, name))
    end
  end

  defp attach_listener(%StreamListener{} = listener, stream, context, name) do
    original = listener.on_chunk

    listener = %{
      listener
      | predict_name: name,
        on_chunk: fn event ->
          if is_function(original, 1), do: original.(event)

          # The owning program task emits one terminal error after the stream
          # unwinds. Do not also publish the listener's pass-through copy.
          unless match?(%StreamResponse{chunk: {:error, _reason}}, event),
            do: emit(context, event)
        end
    }

    StreamListener.attach(listener, stream)
  end

  defp maybe_emit_raw(%{targets: targets} = context, name, event) do
    if Map.fetch!(targets, name) == :raw, do: emit(context, event)
    :ok
  end

  defp emit(%{owner: owner, ref: ref}, event) do
    acknowledgement = make_ref()
    owner_monitor = Process.monitor(owner)
    send(owner, {:imp_stream, ref, self(), acknowledgement, event})

    try do
      receive do
        {:imp_stream_ack, ^acknowledgement} ->
          :ok

        {:imp_stream_cancel, ^ref, reason} ->
          throw({:imp_stream_cancelled, reason})

        {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
          throw({:imp_stream_consumer_exited, reason})
      end
    after
      Process.demonitor(owner_monitor, [:flush])
    end
  end

  defp collect_chunk(nil, chunks), do: chunks
  defp collect_chunk(chunk, chunks) when is_binary(chunk), do: [chunk | chunks]
  defp collect_chunk(%{reasoning: _reasoning}, chunks), do: chunks
  defp collect_chunk(chunk, chunks) when is_map(chunk), do: [chunk | chunks]
  defp collect_chunk(_chunk, chunks), do: chunks

  defp collect_metadata(
         %StreamResponse{chunk: %{reasoning: reasoning}, metadata: incoming},
         metadata
       )
       when is_binary(reasoning) do
    previous = Map.get(metadata, :native_reasoning, "")

    metadata
    |> Map.merge(incoming || %{})
    |> Map.put(:native_reasoning, previous <> reasoning)
  end

  defp collect_metadata(%StreamResponse{metadata: incoming}, metadata),
    do: Map.merge(metadata, incoming || %{})

  defp materialize_chunks(chunks) do
    chunks = Enum.reverse(chunks)

    cond do
      Enum.any?(chunks, &is_binary/1) -> Enum.filter(chunks, &is_binary/1) |> Enum.join()
      chunks == [] -> ""
      true -> Enum.reduce(chunks, %{}, &Map.merge(&2, &1))
    end
  end

  defp envelope(output, metadata) when map_size(metadata) == 0, do: output

  defp envelope(output, metadata),
    do: %{__imp_lm_output__: output, __imp_lm_metadata__: metadata}

  defp normalize_metadata(%Imp.Clients.ReqLLM{model: model}, metadata) do
    provider =
      case to_string(model) |> String.split(":", parts: 2) do
        [provider, _model] -> provider
        _other -> nil
      end

    req_llm = %{
      provider: provider,
      model: to_string(model),
      usage: metadata[:usage] || metadata["usage"],
      finish_reason: metadata[:finish_reason] || metadata["finish_reason"]
    }

    metadata
    |> Map.drop([:usage, "usage", :finish_reason, "finish_reason"])
    |> Map.put(:req_llm, req_llm)
  end

  defp normalize_metadata(_lm, metadata), do: metadata

  defp record_usage({:ok, value} = result) do
    Imp.Usage.maybe_record(value)
    result
  end

  defp normalize_name(name), do: to_string(name)
end

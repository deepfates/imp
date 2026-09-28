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

  defp stream_generate(context, name, lm, messages, opts) do
    module = lm_module(lm)

    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :stream, 3) do
      request = Imp.LM.new_request(lm, messages, opts, "Imp.stream/3")

      lm
      |> Imp.LM.record(request, fn request ->
        {messages, opts} = Imp.Core.request_parts(request)

        case lm |> module.stream(messages, opts) |> consume_stream(context, name, lm) do
          {:ok, raw} -> Imp.Core.response(raw)
          {:error, reason, raw} -> partial_failure(reason, raw)
          {:error, _reason} = error -> error
        end
      end)
      |> Imp.LM.legacy_result()
    else
      Imp.LM.generate(lm, messages, opts)
    end
  end

  # A stream that failed after the provider reported usage or cost may still
  # have been billed, so the failure carries what arrived as a partial
  # response for `Imp.LM.record/3` to record; the caller still gets only the
  # reason.
  defp partial_failure(reason, raw) do
    case Imp.Core.response(raw) do
      {:ok, partial} -> {:error, reason, partial}
      {:error, _invalid} -> {:error, reason}
    end
  end

  defp lm_module(%module{}), do: module
  defp lm_module(module), do: module

  defp consume_stream(stream, context, name, lm) do
    stream = attach_listeners(stream, context, name)

    result =
      Enum.reduce_while(stream, {:ok, [], %{}}, fn
        %StreamResponse{chunk: {:error, reason}} = event, {:ok, chunks, metadata} ->
          {:halt, {:error, reason, chunks, collect_metadata(event, metadata)}}

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

      {:error, reason, _chunks, metadata} when map_size(metadata) == 0 ->
        {:error, reason}

      {:error, reason, chunks, metadata} ->
        {:error, reason, envelope(materialize_chunks(chunks), normalize_metadata(lm, metadata))}
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

  # The streamed output is what the same completion returns unstreamed: text
  # alone is the joined text, and tool calls, which a provider streams one per
  # chunk, are all kept in order beside the text that came with them, in the
  # shape an unstreamed client returns (`Imp.LM.Result.tool_calls/2`).
  defp materialize_chunks(chunks) do
    {texts, maps} = chunks |> Enum.reverse() |> Enum.split_with(&is_binary/1)
    text = Enum.join(texts)
    calls = Enum.flat_map(maps, &List.wrap(Map.get(&1, :tool_calls, Map.get(&1, "tool_calls"))))

    cond do
      calls != [] ->
        maps
        |> Enum.reduce(%{}, &Map.merge(&2, &1))
        |> Map.drop([:tool_calls, "tool_calls"])
        |> Map.merge(Imp.LM.Result.tool_calls(calls, text))

      texts != [] or maps == [] ->
        text

      true ->
        Enum.reduce(maps, %{}, &Map.merge(&2, &1))
    end
  end

  defp envelope(output, metadata) when map_size(metadata) == 0, do: output

  defp envelope(output, metadata),
    do: %{__imp_lm_output__: output, __imp_lm_metadata__: metadata}

  # The model is the one the provider reported, as a non-streamed response
  # records it, and otherwise the id the client was configured with.
  defp normalize_metadata(%Imp.Clients.ReqLLM{model: model}, metadata) do
    {provider, model_id} = Imp.Clients.ReqLLM.model_identity(model)

    req_llm = %{
      provider: provider,
      model: metadata[:model] || metadata["model"] || model_id,
      usage: metadata[:usage] || metadata["usage"],
      finish_reason: metadata[:finish_reason] || metadata["finish_reason"]
    }

    metadata
    |> Map.drop([:usage, "usage", :finish_reason, "finish_reason"])
    |> Map.put(:req_llm, req_llm)
  end

  defp normalize_metadata(_lm, metadata), do: metadata

  defp normalize_name(name), do: to_string(name)
end

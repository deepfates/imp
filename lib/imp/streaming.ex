defmodule Imp.Streaming do
  @moduledoc "Enumerable-friendly streaming helpers."

  @option_schema [
    provider_stream: [type: :boolean, default: false],
    chunker: [
      type: {:custom, __MODULE__, :validate_chunker, []}
    ]
  ]

  @doc """
  Streams one program call as an Enumerable of chunks.

  With `provider_stream: true` and a provider-streaming-capable program,
  chunks arrive from the provider as it generates. Otherwise the program runs
  once and the result is chunked locally (grapheme by grapheme, or through
  the `:chunker` function when given).
  """
  def stream(program, inputs, opts \\ []) do
    owned_opts = validate_opts!(opts, "Imp.Streaming.stream/3")

    cond do
      owned_opts[:provider_stream] ->
        case Imp.ProgramAccess.provider_stream_predict(program) do
          %Imp.Predict.Predict{} = predict -> provider_stream(predict, inputs, opts)
          nil -> fallback_stream(program, inputs, opts)
        end

      true ->
        fallback_stream(program, inputs, opts)
    end
  end

  defp fallback_stream(program, inputs, opts) do
    case Keyword.get(opts, :chunker) do
      nil ->
        Stream.resource(
          fn -> call_once(program, inputs) end,
          fn
            {:done, _} -> {:halt, nil}
            {:ok, text} -> {String.graphemes(text), {:done, text}}
            {:error, reason} -> {[{:error, reason}], {:done, nil}}
          end,
          fn _ -> :ok end
        )

      chunker when is_function(chunker, 1) ->
        program
        |> call_once(inputs)
        |> case do
          {:ok, text} -> chunker.(text)
          {:error, reason} -> [{:error, reason}]
        end
        |> Stream.map(& &1)
    end
  end

  defp provider_stream(%Imp.Predict.Predict{} = program, inputs, opts) do
    with {:ok, inputs} <- normalize_inputs(inputs) do
      settings = Imp.Settings.get()

      adapter =
        if program.dynamic_adapter?,
          do: settings.adapter,
          else: program.adapter || settings.adapter

      lm = if program.dynamic_lm?, do: settings.lm, else: program.lm
      config = Keyword.merge(program.config, Keyword.drop(opts, [:provider_stream, :chunker]))

      with {:ok, messages} <-
             format_with_adapter(adapter, program.signature, inputs, demos: program.demos),
           {:ok, lm_opts} <- adapter_lm_opts(adapter, program.signature, config, lm) do
        stream_lm(lm, messages, lm_opts)
      else
        {:error, reason} -> error_response(reason)
      end
    else
      {:error, reason} ->
        [%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]
    end
  end

  defp stream_lm(%module{} = lm, messages, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :stream, 3) do
      module.stream(lm, messages, opts)
    else
      generate_once(lm, messages, opts)
    end
  end

  defp stream_lm(nil, _messages, _opts),
    do: [%Imp.Streaming.Messages.StreamResponse{chunk: {:error, :lm_not_configured}, done: true}]

  defp stream_lm(module, messages, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :stream, 3) do
      module.stream(module, messages, opts)
    else
      generate_once(module, messages, opts)
    end
  end

  defp stream_lm(%{module: module, opts: lm_opts} = lm, messages, opts) do
    with {:ok, lm_opts} <- validate_lm_opts(lm_opts) do
      opts = Keyword.merge(lm_opts, opts)

      if Code.ensure_loaded?(module) and function_exported?(module, :stream, 3) do
        module.stream(lm, messages, opts)
      else
        generate_once(lm, messages, opts)
      end
    else
      {:error, reason} -> error_response(reason)
    end
  end

  defp stream_lm(fun, messages, opts) when is_function(fun, 2),
    do: generate_once(fun, messages, opts)

  defp stream_lm(lm, _messages, _opts), do: error_response({:not_an_lm, lm})

  defp generate_once(lm, messages, opts) do
    case lm |> Imp.LM.generate(messages, opts) |> Imp.LM.Result.unwrap() do
      {:ok, value} ->
        [%Imp.Streaming.Messages.StreamResponse{chunk: stream_value(value)}]

      {:error, reason} ->
        [%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]
    end
  rescue
    error ->
      error_response({:lm_generate_failed, Exception.message(error)})
  catch
    kind, reason ->
      error_response({:lm_generate_failed, inspect({kind, reason})})
  end

  defp error_response(reason),
    do: [%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]

  defp format_with_adapter(adapter, signature, inputs, opts) do
    with :ok <- ensure_adapter_loaded(adapter),
         true <- function_exported?(adapter, :format, 3) do
      {:ok, adapter.format(signature, inputs, opts)}
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_adapter, adapter, :format}}
    end
  rescue
    error -> {:error, {:adapter_format_failed, adapter, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:adapter_format_failed, adapter, {kind, reason}}}
  end

  defp adapter_lm_opts(adapter, signature, config, lm) do
    with :ok <- ensure_adapter_loaded(adapter),
         true <-
           function_exported?(adapter, :lm_opts, 3) or function_exported?(adapter, :lm_opts, 2),
         {:ok, opts} <- call_adapter_lm_opts(adapter, signature, config, lm) do
      {:ok, Keyword.merge(config, opts)}
    else
      false -> {:ok, config}
      {:error, _reason} = error -> error
    end
  end

  defp call_adapter_lm_opts(adapter, signature, config, lm) do
    opts =
      if function_exported?(adapter, :lm_opts, 3) do
        adapter.lm_opts(signature, config, Imp.LM.response_format_capability(lm))
      else
        adapter.lm_opts(signature, config)
      end

    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error, {:invalid_adapter_lm_opts, adapter, opts}}
    end
  rescue
    error -> {:error, {:adapter_lm_opts_failed, adapter, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:adapter_lm_opts_failed, adapter, {kind, reason}}}
  end

  defp ensure_adapter_loaded(adapter) when is_atom(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, _module} -> :ok
      {:error, reason} -> {:error, {:adapter_not_loaded, adapter, reason}}
    end
  end

  defp ensure_adapter_loaded(adapter), do: {:error, {:invalid_adapter, adapter}}

  defp stream_value(%Imp.Prediction{} = prediction), do: Imp.Prediction.to_map(prediction)
  defp stream_value(value), do: value

  @doc """
  Collects stream chunks into a string.

  Successful streams return the collected string. If the stream emits an error
  chunk, collection stops and returns `{:error, reason}` instead of partial output.
  """
  @spec collect(term(), term(), keyword()) :: String.t() | {:error, term()}
  def collect(program, inputs, opts \\ []) do
    validate_opts!(opts, "Imp.Streaming.collect/3")
    outputs = output_names(program)

    result =
      program
      |> stream(inputs, opts)
      |> Enum.reduce_while([], fn value, chunks ->
        case stream_error(value) do
          {:error, reason} -> {:halt, {:error, reason}}
          nil -> {:cont, [collect_value(value, outputs) | chunks]}
        end
      end)

    case result do
      {:error, _reason} = error -> error
      chunks -> chunks |> Enum.reverse() |> Enum.join()
    end
  end

  defp collect_value(%Imp.Streaming.Messages.StreamResponse{chunk: nil}, _outputs), do: ""

  defp collect_value(%Imp.Streaming.Messages.StreamResponse{chunk: chunk}, outputs),
    do: collect_value(chunk, outputs)

  defp collect_value(%Imp.Prediction{} = prediction, outputs),
    do: collect_value(Imp.Prediction.to_map(prediction), outputs)

  defp collect_value(value, outputs) when is_map(value) do
    values =
      case outputs do
        [] -> Map.values(value)
        outputs -> Enum.map(outputs, &fetch_field(value, &1))
      end

    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(&to_string/1)
  end

  defp collect_value(value, _outputs), do: to_string(value)

  @doc """
  Parses provider chunks into incremental typed field updates.

  The parser follows the ChatAdapter delimiter format:
  `[[ ## field ## ]]` followed by field text. A field is emitted when the next
  field delimiter arrives or when the stream ends.
  """
  def incremental_fields(chunks, signature) do
    signature = Imp.Signature.ensure(signature)
    allowed = MapSet.new(Enum.map(signature.outputs, & &1.name))
    text = Enum.map_join(chunks, &to_string/1)

    ~r/\[\[\s*##\s*([a-zA-Z_][\w]*)\s*##\s*\]\](.*?)(?=\[\[\s*##\s*[a-zA-Z_][\w]*\s*##\s*\]\]|\z)/s
    |> Regex.scan(text)
    |> Enum.flat_map(fn [_, field, value] ->
      case field_event(field, String.trim(value), allowed) do
        nil -> []
        event -> [event]
      end
    end)
  end

  defp call_once(program, inputs) do
    case Imp.Module.call(program, inputs) do
      {:ok, prediction} ->
        text =
          prediction
          |> Imp.Prediction.to_map()
          |> collect_value(output_names(program))

        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_error(%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}}),
    do: {:error, reason}

  defp stream_error({:error, reason}), do: {:error, reason}
  defp stream_error(_value), do: nil

  defp output_names(program), do: Imp.ProgramAccess.output_names(program)

  defp fetch_field(map, key) do
    cond do
      Map.has_key?(map, key) ->
        Map.fetch!(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.fetch!(map, Atom.to_string(key))

      is_binary(key) ->
        fetch_existing_atom_key(map, key)

      true ->
        nil
    end
  end

  defp fetch_existing_atom_key(map, key) do
    atom = String.to_existing_atom(key)
    Map.get(map, atom)
  rescue
    ArgumentError -> nil
  end

  defp field_event(field, value, allowed) do
    key = existing_atom_or_string(field)
    if MapSet.member?(allowed, key), do: %{field: key, value: value}
  end

  defp existing_atom_or_string(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp validate_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Keyword.take(Keyword.keys(@option_schema))
      |> Imp.Options.validate!(@option_schema, context)
    else
      raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
  end

  def validate_chunker(nil), do: {:ok, nil}
  def validate_chunker(chunker) when is_function(chunker, 1), do: {:ok, chunker}

  def validate_chunker(chunker) do
    {:error, "expected nil or an arity-1 function, got: #{inspect(chunker)}"}
  end

  defp validate_lm_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error, {:invalid_lm_options, "expected keyword options, got: #{inspect(opts)}"}}
    end
  end

  defp validate_lm_opts(opts),
    do: {:error, {:invalid_lm_options, "expected keyword options, got: #{inspect(opts)}"}}

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_stream_inputs, "expected inputs as {key, value} pairs"}}
  end
end

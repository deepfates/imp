defmodule DSEx.Streaming do
  @moduledoc "Enumerable-friendly streaming helpers."

  @option_schema [
    provider_stream: [type: :boolean, default: false],
    chunker: [type: :any]
  ]

  def stream(program, inputs, opts \\ []) do
    owned_opts = validate_opts!(opts, "DSEx.Streaming.stream/3")
    validate_chunker!(owned_opts[:chunker], "DSEx.Streaming.stream/3")

    cond do
      owned_opts[:provider_stream] and match?(%DSEx.Predict.Predict{}, program) ->
        provider_stream(program, inputs, opts)

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

  defp provider_stream(%DSEx.Predict.Predict{} = program, inputs, opts) do
    with {:ok, inputs} <- normalize_inputs(inputs) do
      settings = DSEx.Settings.get()

      adapter =
        if program.dynamic_adapter?,
          do: settings.adapter,
          else: program.adapter || settings.adapter

      lm = if program.dynamic_lm?, do: settings.lm, else: program.lm
      messages = adapter.format(program.signature, inputs, demos: program.demos)

      stream_lm(
        lm,
        messages,
        Keyword.merge(program.config, Keyword.drop(opts, [:provider_stream, :chunker]))
      )
    else
      {:error, reason} ->
        [%DSEx.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]
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
    do: [%DSEx.Streaming.Messages.StreamResponse{chunk: {:error, :lm_not_configured}, done: true}]

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
    case DSEx.LM.generate(lm, messages, opts) do
      {:ok, value} ->
        [%DSEx.Streaming.Messages.StreamResponse{chunk: stream_value(value)}]

      {:error, reason} ->
        [%DSEx.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]
    end
  rescue
    error ->
      error_response({:lm_generate_failed, Exception.message(error)})
  catch
    kind, reason ->
      error_response({:lm_generate_failed, inspect({kind, reason})})
  end

  defp error_response(reason),
    do: [%DSEx.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]

  defp stream_value(%DSEx.Prediction{} = prediction), do: DSEx.Prediction.to_map(prediction)
  defp stream_value(value), do: value

  def collect(program, inputs, opts \\ []) do
    validate_opts!(opts, "DSEx.Streaming.collect/3")
    outputs = output_names(program)

    program
    |> stream(inputs, opts)
    |> Enum.reject(&error_chunk?/1)
    |> Enum.map_join(&collect_value(&1, outputs))
  end

  defp collect_value(%DSEx.Streaming.Messages.StreamResponse{chunk: nil}, _outputs), do: ""

  defp collect_value(%DSEx.Streaming.Messages.StreamResponse{chunk: chunk}, outputs),
    do: collect_value(chunk, outputs)

  defp collect_value(%DSEx.Prediction{} = prediction, outputs),
    do: collect_value(DSEx.Prediction.to_map(prediction), outputs)

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
    signature = DSEx.Signature.ensure(signature)
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
    case DSEx.Module.call(program, inputs) do
      {:ok, prediction} ->
        text =
          prediction
          |> DSEx.Prediction.to_map()
          |> collect_value(output_names(program))

        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp error_chunk?(%DSEx.Streaming.Messages.StreamResponse{chunk: {:error, _reason}}), do: true
  defp error_chunk?({:error, _reason}), do: true
  defp error_chunk?(_value), do: false

  defp output_names(%{signature: signature}), do: DSEx.Signature.output_names(signature)
  defp output_names(%DSEx.Predict.RAG{program: program}), do: output_names(program)
  defp output_names(_program), do: []

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
      |> DSEx.Options.validate!(@option_schema, context)
    else
      raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
  end

  defp validate_chunker!(nil, _context), do: :ok
  defp validate_chunker!(chunker, _context) when is_function(chunker, 1), do: :ok

  defp validate_chunker!(chunker, context) do
    raise ArgumentError,
          "#{context} expects :chunker to be nil or an arity-1 function; got: #{inspect(chunker)}"
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

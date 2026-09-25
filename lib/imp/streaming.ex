defmodule Imp.Streaming do
  @moduledoc "Enumerable-friendly streaming helpers."

  @option_schema [
    provider_stream: [type: :boolean, default: false],
    stream_listeners: [
      type: {:custom, __MODULE__, :validate_stream_listeners, []},
      default: []
    ],
    include_final_prediction: [type: :boolean, default: true],
    chunker: [
      type: {:custom, __MODULE__, :validate_chunker, []}
    ]
  ]

  @doc """
  Streams one program call as an Enumerable of chunks.

  With `provider_stream: true`, Imp executes the real program and streams from
  its named predictors as they are reached. `:stream_listeners` can select
  intermediate output fields; without listeners, normalized provider events
  from every named predictor are yielded. The final typed prediction is yielded
  by default and can be disabled with `include_final_prediction: false`.

  Composed modules expose their predictor names through the ordinary optimizer
  predictor callback in `Imp.Module`. A program with no named predictors
  returns a terminal `{:provider_stream_unsupported, module}` error.
  Without `provider_stream: true`, the program runs once and the result is
  chunked locally (grapheme by grapheme, or through the `:chunker` function).

  Either way a failure is the last element of the stream, as
  `%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}`.
  """
  def stream(program, inputs, opts \\ []) do
    owned_opts = validate_opts!(opts, "Imp.Streaming.stream/3")

    cond do
      owned_opts[:provider_stream] ->
        provider_program_stream(program, inputs, owned_opts)

      true ->
        fallback_stream(program, inputs, opts)
    end
  end

  defp provider_program_stream(program, inputs, opts) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         {:ok, program, targets} <- prepare_stream_program(program, opts[:stream_listeners]) do
      program_stream(program, inputs, targets, opts[:include_final_prediction])
    else
      {:error, {:provider_stream_unsupported, _module} = reason} -> error_response(reason)
      {:error, reason} -> error_response(reason)
    end
  end

  defp prepare_stream_program(%_module{} = program, listeners) do
    predictors = Imp.ProgramParameters.predictors(program)

    if predictors == [] do
      {:error, {:provider_stream_unsupported, program.__struct__}}
    else
      targets = resolve_targets!(predictors, listeners)

      tagged =
        Enum.reduce(predictors, program, fn %{name: name}, current ->
          Imp.ProgramParameters.update_predictor(current, name, fn predictor ->
            %{
              predictor
              | metadata: Map.put(predictor.metadata, :stream_predict_name, to_string(name))
            }
          end)
        end)

      {:ok, tagged, targets}
    end
  rescue
    error in ArgumentError -> {:error, {:provider_stream_configuration, Exception.message(error)}}
  end

  defp prepare_stream_program(program, _listeners),
    do: {:error, {:provider_stream_unsupported, program}}

  defp resolve_targets!(predictors, []) do
    Map.new(predictors, fn %{name: name} -> {to_string(name), :raw} end)
  end

  defp resolve_targets!(predictors, listeners) do
    Enum.reduce(listeners, %{}, fn listener, targets ->
      name = resolve_listener_predictor!(predictors, listener)
      Map.update(targets, name, [listener], &(&1 ++ [listener]))
    end)
  end

  defp resolve_listener_predictor!(predictors, %{predict_name: name}) when not is_nil(name) do
    wanted = to_string(name)

    if Enum.any?(predictors, &(to_string(&1.name) == wanted)) do
      wanted
    else
      raise ArgumentError,
            "stream listener names unknown predictor #{inspect(name)}; available names: " <>
              inspect(Enum.map(predictors, & &1.name))
    end
  end

  defp resolve_listener_predictor!(predictors, %{signature_field_name: field})
       when is_binary(field) do
    matches =
      Enum.filter(predictors, fn %{predictor: predictor} ->
        Enum.any?(predictor.signature.outputs, &(to_string(&1.name) == field))
      end)

    case matches do
      [%{name: name}] ->
        to_string(name)

      [] ->
        raise ArgumentError,
              "stream listener field #{inspect(field)} is not an output of any named predictor"

      many ->
        raise ArgumentError,
              "stream listener field #{inspect(field)} is ambiguous across predictors " <>
                inspect(Enum.map(many, & &1.name)) <> "; set :predict_name"
    end
  end

  defp resolve_listener_predictor!(_predictors, _listener) do
    raise ArgumentError,
          "stream listeners used for program streaming require :signature_field_name"
  end

  defp program_stream(program, inputs, targets, include_final?) do
    Stream.resource(
      fn -> start_program_stream(program, inputs, targets, include_final?) end,
      &next_program_stream/1,
      &stop_program_stream/1
    )
  end

  defp start_program_stream(program, inputs, targets, include_final?) do
    owner = self()
    ref = make_ref()
    context = %{owner: owner, ref: ref, targets: targets}

    task =
      Imp.Tasks.async_nolink_borrowed(fn ->
        Imp.Streaming.Execution.with_context(context, fn -> Imp.Module.call(program, inputs) end)
      end)

    %{task: task, ref: ref, include_final?: include_final?, done?: false, pending_ack: nil}
  end

  defp next_program_stream(%{done?: true} = state), do: {:halt, state}

  defp next_program_stream(state) do
    acknowledge(state.pending_ack)
    state = %{state | pending_ack: nil}

    receive do
      {:imp_stream, ref, producer, acknowledgement, event} when ref == state.ref ->
        {[event], %{state | pending_ack: {producer, acknowledgement}}}

      {task_ref, {:ok, %Imp.Prediction{} = prediction}} when task_ref == state.task.ref ->
        Process.demonitor(state.task.ref, [:flush])
        events = if state.include_final?, do: [prediction], else: []
        {events, %{state | done?: true}}

      {task_ref, {:error, reason}} when task_ref == state.task.ref ->
        Process.demonitor(state.task.ref, [:flush])
        {error_response(reason), %{state | done?: true}}

      {task_ref, other} when task_ref == state.task.ref ->
        Process.demonitor(state.task.ref, [:flush])
        {error_response({:invalid_stream_program_result, other}), %{state | done?: true}}

      {:DOWN, task_ref, :process, _pid, reason} when task_ref == state.task.ref ->
        {error_response({:stream_program_exited, reason}), %{state | done?: true}}
    end
  end

  defp stop_program_stream(%{task: task, ref: ref, done?: false}) do
    if Process.alive?(task.pid) do
      send(task.pid, {:imp_stream_cancel, ref, :consumer_halted})

      case Task.yield(task, 1_000) do
        nil -> Imp.Tasks.cancel(task, 5_000)
        _result -> :ok
      end
    end

    :ok
  end

  defp stop_program_stream(_state), do: :ok

  defp acknowledge(nil), do: :ok
  defp acknowledge({producer, ref}), do: send(producer, {:imp_stream_ack, ref})

  defp fallback_stream(program, inputs, opts) do
    case Keyword.get(opts, :chunker) do
      nil ->
        Stream.resource(
          fn -> call_once(program, inputs) end,
          fn
            {:done, _} -> {:halt, nil}
            {:ok, text} -> {String.graphemes(text), {:done, text}}
            {:error, reason} -> {error_response(reason), {:done, nil}}
          end,
          fn _ -> :ok end
        )

      chunker when is_function(chunker, 1) ->
        program
        |> call_once(inputs)
        |> case do
          {:ok, text} -> chunker.(text)
          {:error, reason} -> error_response(reason)
        end
        |> Stream.map(& &1)
    end
  end

  defp error_response(reason),
    do: [%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}]

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
          {:error, reason} ->
            {:halt, {:error, reason}}

          nil ->
            cond do
              match?(%Imp.Prediction{}, value) ->
                # A completed provider stream has now passed through the
                # program's adapter and output contract. Prefer that typed
                # final value over provider wire framing accumulated earlier.
                {:cont, [collect_value(value, outputs)]}

              true ->
                {:cont, [collect_value(value, outputs) | chunks]}
            end
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

  def validate_stream_listeners(listeners) when is_list(listeners) do
    if Enum.all?(listeners, &match?(%Imp.Streaming.Messages.StreamListener{}, &1)) do
      {:ok, listeners}
    else
      {:error, "expected a list of Imp.Streaming.Messages.StreamListener structs"}
    end
  end

  def validate_stream_listeners(listeners) do
    {:error,
     "expected a list of Imp.Streaming.Messages.StreamListener structs, got: #{inspect(listeners)}"}
  end

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_stream_inputs, "expected inputs as {key, value} pairs"}}
  end
end

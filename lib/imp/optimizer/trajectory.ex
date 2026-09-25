defmodule Imp.Optimizer.Trajectory do
  @moduledoc """
  Versioned, provider-neutral execution envelope shared by all optimizers.

  The original evaluation fields remain directly available. `project/3` adds a
  runtime identity and typed events for GEPA, MIPROv2, SIMBA, RLM, ReAct, and
  generic evaluation adapters. `dump/1` is the canonical cross-runtime wire
  representation: it is JSON-safe, deterministic, and redacts secrets in
  structured fields. Opaque attachment bytes are preserved unchanged. `load/1`
  validates the complete envelope and fails closed.
  """

  alias __MODULE__.{Cache, DecodeError, Event, Failure, Parameter, Timing, Usage}

  @schema_version 1
  @runtimes [:evaluation, :gepa, :mipro_v2, :simba, :rlm, :agent, :react, :optimize_anything]

  @type runtime ::
          :evaluation | :gepa | :mipro_v2 | :simba | :rlm | :agent | :react | :optimize_anything

  @enforce_keys [:index, :example, :score]
  defstruct [
    :index,
    :example,
    :prediction,
    :trace,
    :score,
    :feedback,
    :metric_metadata,
    :error,
    :program_id,
    :rollout_id,
    schema_version: @schema_version,
    runtime: :evaluation,
    events: [],
    usage: %Usage{},
    timing: %Timing{},
    cache: nil,
    named_parameters: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          runtime: runtime(),
          index: integer(),
          example: term(),
          prediction: term(),
          trace: list() | nil,
          score: number(),
          feedback: term(),
          metric_metadata: map() | nil,
          error: term(),
          program_id: term(),
          rollout_id: term(),
          events: list(),
          usage: struct(),
          timing: struct(),
          cache: struct() | nil,
          named_parameters: list(),
          metadata: map()
        }

  @doc "Returns the current trajectory wire schema version."
  def schema_version, do: @schema_version

  @doc "Projects an existing trajectory or runtime prediction into the canonical contract."
  @spec project(runtime(), t() | Imp.Prediction.t() | map(), keyword()) :: t()
  def project(runtime, value, opts \\ [])

  def project(runtime, value, opts) when runtime in @runtimes and is_list(opts) do
    base = projection_base(value, opts)

    base
    |> Map.replace!(:runtime, runtime)
    |> Map.replace!(:events, projected_events(value, opts))
    |> Map.replace!(:usage, typed_option(opts, :usage, Usage, base.usage))
    |> Map.replace!(:timing, typed_option(opts, :timing, Timing, base.timing))
    |> Map.replace!(:cache, typed_cache(Keyword.get(opts, :cache, base.cache)))
    |> Map.replace!(
      :named_parameters,
      typed_parameters(Keyword.get(opts, :named_parameters, base.named_parameters))
    )
    |> Map.replace!(:metadata, Keyword.get(opts, :metadata, base.metadata))
    |> validate!()
  end

  def project(runtime, _value, _opts) do
    raise ArgumentError,
          "unsupported trajectory runtime #{inspect(runtime)}; expected one of #{inspect(@runtimes)}"
  end

  @doc "Validates ordering, tool alignment, accounting, cache, and named parameter invariants."
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = trajectory) do
    validate_header!(trajectory)
    validate_payload!(trajectory)
    validate_events!(trajectory.events)
    validate_usage!(trajectory.usage)
    validate_timing!(trajectory.timing)
    validate_cache!(trajectory.cache)
    validate_parameters!(trajectory.named_parameters)
    trajectory
  end

  def validate!(other),
    do: invalid!("expected an Imp.Optimizer.Trajectory, got: #{inspect(other)}")

  @doc "Validates a batch as index-aligned, ordered canonical trajectories."
  @spec validate_aligned!([t()]) :: [t()]
  def validate_aligned!(trajectories) when is_list(trajectories) do
    Enum.each(trajectories, &validate!/1)
    indices = Enum.map(trajectories, & &1.index)

    unless indices == Enum.to_list(0..(length(indices) - 1)//1) or indices == [],
      do: invalid!("trajectory batch indices must be contiguous and ordered from zero")

    trajectories
  end

  def validate_aligned!(other),
    do: invalid!("aligned trajectories must be a list, got: #{inspect(other)}")

  @doc "Returns a secret-redacted trajectory while preserving all typed structs."
  @spec redact(t(), [atom() | String.t()]) :: t()
  def redact(%__MODULE__{} = trajectory, keys \\ Imp.Redaction.default_keys()) do
    redact_value(trajectory, keys)
  end

  @doc """
  True when this trajectory's failure came from a killed evaluation task
  (timeout or deadline exhaustion), not from model or metric behavior.
  """
  @spec killed?(t()) :: boolean()
  def killed?(%__MODULE__{error: {:task_exit, _reason}}), do: true
  def killed?(%__MODULE__{}), do: false

  @doc "Dumps every trajectory field into a deterministic JSON-safe versioned map."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = trajectory) do
    trajectory = trajectory |> validate!() |> redact()

    %{
      "type" => "imp_optimizer_trajectory",
      "schema_version" => trajectory.schema_version,
      "runtime" => Atom.to_string(trajectory.runtime),
      "index" => trajectory.index,
      "example" => encode_term(trajectory.example),
      "prediction" => encode_term(trajectory.prediction),
      "trace" => encode_term(trajectory.trace),
      "score" => trajectory.score,
      "feedback" => encode_term(trajectory.feedback),
      "metric_metadata" => encode_term(trajectory.metric_metadata),
      "error" => encode_term(trajectory.error),
      "program_id" => encode_term(trajectory.program_id),
      "rollout_id" => encode_term(trajectory.rollout_id),
      "events" => Enum.map(trajectory.events, &encode_struct/1),
      "usage" => encode_struct(trajectory.usage),
      "timing" => encode_struct(trajectory.timing),
      "cache" => encode_optional_struct(trajectory.cache),
      "named_parameters" => Enum.map(trajectory.named_parameters, &encode_struct/1),
      "metadata" => encode_term(trajectory.metadata)
    }
  end

  @doc "Loads and strictly validates a canonical trajectory wire map."
  @spec load(map()) :: {:ok, t()} | {:error, struct()}
  def load(state) do
    {:ok, load!(state)}
  rescue
    error in [ArgumentError, KeyError, DecodeError] ->
      {:error, %DecodeError{message: Exception.message(error)}}
  catch
    kind, reason -> {:error, %DecodeError{message: "#{kind}: #{inspect(reason)}"}}
  end

  @doc "Loads a trajectory or raises `DecodeError` for any malformed field."
  @spec load!(map()) :: t()
  def load!(%{"type" => "imp_optimizer_trajectory", "schema_version" => @schema_version} = state) do
    expected = MapSet.new(wire_keys())

    unless MapSet.new(Map.keys(state)) == expected,
      do: decode_error!("trajectory wire keys do not match schema version #{@schema_version}")

    runtime = decode_runtime(Map.fetch!(state, "runtime"))

    %__MODULE__{
      schema_version: @schema_version,
      runtime: runtime,
      index: Map.fetch!(state, "index"),
      example: decode_term(Map.fetch!(state, "example")),
      prediction: decode_term(Map.fetch!(state, "prediction")),
      trace: decode_term(Map.fetch!(state, "trace")),
      score: Map.fetch!(state, "score"),
      feedback: decode_term(Map.fetch!(state, "feedback")),
      metric_metadata: decode_term(Map.fetch!(state, "metric_metadata")),
      error: decode_term(Map.fetch!(state, "error")),
      program_id: decode_term(Map.fetch!(state, "program_id")),
      rollout_id: decode_term(Map.fetch!(state, "rollout_id")),
      events: decode_structs(Map.fetch!(state, "events"), Event),
      usage: decode_struct(Map.fetch!(state, "usage"), Usage),
      timing: decode_struct(Map.fetch!(state, "timing"), Timing),
      cache: decode_optional_struct(Map.fetch!(state, "cache"), Cache),
      named_parameters: decode_structs(Map.fetch!(state, "named_parameters"), Parameter),
      metadata: decode_term(Map.fetch!(state, "metadata"))
    }
    |> validate!()
  rescue
    error in [ArgumentError, KeyError, DecodeError] ->
      reraise %DecodeError{message: Exception.message(error)}, __STACKTRACE__
  end

  def load!(state),
    do: decode_error!("unsupported or malformed trajectory envelope: #{inspect(state)}")

  defp projection_base(%__MODULE__{} = trajectory, _opts), do: trajectory

  defp projection_base(%Imp.Prediction{} = prediction, opts) do
    %__MODULE__{
      index: Keyword.get(opts, :index, 0),
      example: Keyword.get(opts, :example),
      prediction: prediction,
      trace: prediction_trace(prediction),
      score: Keyword.get(opts, :score, prediction.score || 0.0),
      feedback: Keyword.get(opts, :feedback),
      metric_metadata: Keyword.get(opts, :metric_metadata, %{}),
      error: Keyword.get(opts, :error),
      program_id: Keyword.get(opts, :program_id),
      rollout_id: Keyword.get(opts, :rollout_id)
    }
  end

  defp projection_base(value, opts) when is_map(value) do
    %__MODULE__{
      index: fetch(value, :index, Keyword.get(opts, :index, 0)),
      example: fetch(value, :example, Keyword.get(opts, :example)),
      prediction: fetch(value, :prediction, fetch(value, :output)),
      trace: fetch(value, :trace, []),
      score: fetch(value, :score, Keyword.get(opts, :score, 0.0)),
      feedback: fetch(value, :feedback, Keyword.get(opts, :feedback)),
      metric_metadata: fetch(value, :metric_metadata, %{}),
      error: fetch(value, :error, Keyword.get(opts, :error)),
      program_id: fetch(value, :program_id, Keyword.get(opts, :program_id)),
      rollout_id: fetch(value, :rollout_id, Keyword.get(opts, :rollout_id)),
      events: fetch(value, :events, []),
      usage: fetch(value, :usage, %Usage{}),
      timing: fetch(value, :timing, %Timing{}),
      cache: fetch(value, :cache),
      named_parameters: fetch(value, :named_parameters, []),
      metadata: fetch(value, :metadata, %{})
    }
  end

  defp projected_events(value, opts) do
    case Keyword.fetch(opts, :events) do
      {:ok, events} -> typed_events(events)
      :error -> projected_value_events(value)
    end
  end

  defp projected_value_events(%__MODULE__{events: [_ | _] = events}), do: typed_events(events)

  defp projected_value_events(value) when is_map(value) do
    case fetch(value, :events) do
      events when is_list(events) and events != [] -> typed_events(events)
      _other -> value |> projection_trace() |> events_from_trace()
    end
  end

  defp projected_value_events(value), do: value |> projection_trace() |> events_from_trace()

  defp projection_trace(%__MODULE__{events: [_ | _] = events}), do: events
  defp projection_trace(%__MODULE__{trace: trace}), do: trace || []
  defp projection_trace(%Imp.Prediction{} = prediction), do: prediction_trace(prediction)
  defp projection_trace(value) when is_map(value), do: fetch(value, :trace, [])

  defp prediction_trace(%Imp.Prediction{metadata: metadata}) do
    fetch(metadata, :rlm_trace, fetch(metadata, :optimizer_trace, fetch(metadata, :trajectory))) ||
      fetch(metadata, :history, [])
  end

  defp events_from_trace(trace) when is_list(trace) do
    trace
    |> Enum.with_index()
    |> Enum.flat_map(&trace_events/1)
    |> Enum.with_index()
    |> Enum.map(fn {event, sequence} -> %{event | sequence: sequence} end)
  end

  defp events_from_trace(_), do: []

  defp trace_events({%Event{} = event, _trace_index}), do: [event]

  defp trace_events({%{predictor: component, inputs: input, outputs: output}, _trace_index}) do
    [%Event{sequence: 0, kind: :module, component: component, input: input, output: output}]
  end

  defp trace_events(
         {%{"predictor" => component, "inputs" => input, "outputs" => output}, _trace_index}
       ) do
    [%Event{sequence: 0, kind: :module, component: component, input: input, output: output}]
  end

  defp trace_events({event, trace_index}) when is_map(event) do
    cond do
      not is_nil(fetch(event, :tool)) and has_field?(event, :result) ->
        combined_tool_events(event, trace_index)

      not is_nil(fetch(event, :tool_calls)) ->
        parallel_tool_events(event, trace_index)

      true ->
        [runtime_event(event, 0)]
    end
  end

  defp trace_events({event, _trace_index}),
    do: [%Event{sequence: 0, kind: :runtime, output: event}]

  defp combined_tool_events(event, trace_index) do
    id = fetch(event, :id, "trace-#{trace_index}-call-0")
    name = fetch(event, :tool)
    result = fetch(event, :result)

    [
      %Event{
        sequence: 0,
        kind: :tool_call,
        tool_call_id: id,
        tool_name: name,
        input: fetch(event, :arguments, %{})
      },
      %Event{
        sequence: 0,
        kind: :tool_result,
        tool_call_id: id,
        tool_name: name,
        output: result,
        error: tool_error(result)
      }
    ]
  end

  defp parallel_tool_events(event, trace_index) do
    calls = collection_values(fetch(event, :tool_calls), :tool_calls)
    results = collection_values(fetch(event, :tool_call_results, []), :tool_call_results)

    call_events =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {call, call_index} ->
        %Event{
          sequence: 0,
          kind: :tool_call,
          tool_call_id: fetch(call, :id, "trace-#{trace_index}-call-#{call_index}"),
          tool_name: fetch(call, :name),
          input: fetch(call, :arguments, fetch(call, :args, %{}))
        }
      end)

    result_events =
      results
      |> Enum.with_index()
      |> Enum.map(fn {result, result_index} ->
        call = Enum.at(call_events, result_index)
        value = fetch(result, :result)

        %Event{
          sequence: 0,
          kind: :tool_result,
          tool_call_id: fetch(result, :id, call && call.tool_call_id),
          tool_name: fetch(result, :name, call && call.tool_name),
          output: value,
          error: tool_error(value)
        }
      end)

    call_events ++ result_events
  end

  defp collection_values(nil, _field), do: []
  defp collection_values(values, _field) when is_list(values), do: values
  defp collection_values(value, field) when is_map(value), do: fetch(value, field, [])
  defp collection_values(_value, _field), do: []

  defp tool_error({:error, reason}), do: reason
  defp tool_error(_result), do: nil

  defp runtime_event(event, sequence) do
    input = fetch(event, :input)
    output = fetch(event, :output)
    action = fetch(event, :action, :runtime)
    call = fetch(event, :tool_call)
    result = fetch(event, :tool_result)

    cond do
      is_map(call) ->
        %Event{
          sequence: sequence,
          kind: :tool_call,
          tool_call_id: fetch(call, :id),
          tool_name: fetch(call, :name),
          input: fetch(call, :arguments, fetch(call, :args, %{})),
          metadata: Map.drop(event, [:tool_call, "tool_call"])
        }

      is_map(result) ->
        %Event{
          sequence: sequence,
          kind: :tool_result,
          tool_call_id: fetch(result, :id),
          tool_name: fetch(result, :name),
          output: fetch(result, :result),
          error: fetch(result, :error)
        }

      true ->
        %Event{
          sequence: sequence,
          kind: action,
          component: fetch(event, :component),
          input: input,
          output: output,
          reasoning: fetch(input || %{}, :reasoning, fetch(event, :reasoning)),
          error: fetch(event, :error),
          started_at_us: fetch(event, :started_at_us),
          duration_us: fetch(event, :duration_us),
          metadata: Map.drop(event, event_known_keys())
        }
    end
  end

  defp typed_events(events) when is_list(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn
      {%Event{} = event, sequence} ->
        %{event | sequence: sequence}

      {event, sequence} when is_map(event) ->
        event |> atomize_known(Event) |> then(&struct!(Event, Map.put(&1, :sequence, sequence)))

      {event, _sequence} ->
        invalid!("event must be an Event or map, got: #{inspect(event)}")
    end)
  end

  defp typed_events(other), do: invalid!("events must be a list, got: #{inspect(other)}")

  defp typed_option(opts, key, module, current) do
    case Keyword.get(opts, key, current) do
      nil -> struct!(module, %{})
      %{__struct__: ^module} = value -> value
      value when is_map(value) -> struct!(module, atomize_known(value, module))
      value -> invalid!("#{key} must be a #{inspect(module)} or map, got: #{inspect(value)}")
    end
  end

  defp typed_cache(nil), do: nil
  defp typed_cache(%Cache{} = cache), do: cache
  defp typed_cache(cache) when is_map(cache), do: struct!(Cache, atomize_known(cache, Cache))

  defp typed_cache(cache),
    do: invalid!("cache must be a Cache, map, or nil, got: #{inspect(cache)}")

  defp typed_parameters(parameters) when is_map(parameters) do
    Enum.map(parameters, fn {name, value} ->
      %Parameter{name: name, kind: :opaque, value: value}
    end)
  end

  defp typed_parameters(parameters) when is_list(parameters) do
    Enum.map(parameters, fn
      %Parameter{} = parameter ->
        parameter

      parameter when is_map(parameter) ->
        struct!(Parameter, atomize_known(parameter, Parameter))

      parameter ->
        invalid!("named parameter must be a Parameter or map, got: #{inspect(parameter)}")
    end)
  end

  defp typed_parameters(other),
    do: invalid!("named_parameters must be a map or list, got: #{inspect(other)}")

  defp validate_events!(events) do
    expected = Enum.to_list(0..(length(events) - 1)//1)

    actual = Enum.map(events, &event_sequence!/1)

    unless actual == expected or actual == [],
      do: invalid!("event sequences must be contiguous and ordered from zero")

    Enum.reduce(events, %{}, fn event, calls ->
      validate_event_time!(event)
      validate_tool_alignment!(event, calls)
    end)
  end

  defp validate_header!(trajectory) do
    unless trajectory.schema_version == @schema_version,
      do: invalid!("unsupported schema_version #{inspect(trajectory.schema_version)}")

    unless trajectory.runtime in @runtimes,
      do: invalid!("unsupported runtime #{inspect(trajectory.runtime)}")

    unless is_integer(trajectory.index) and trajectory.index >= -1,
      do: invalid!("index must be an integer greater than or equal to -1")
  end

  defp validate_payload!(trajectory) do
    unless is_number(trajectory.score), do: invalid!("score must be numeric")
    unless is_list(trajectory.events), do: invalid!("events must be a list")

    unless is_map(trajectory.metric_metadata || %{}),
      do: invalid!("metric_metadata must be a map")

    unless is_map(trajectory.metadata), do: invalid!("metadata must be a map")
  end

  defp event_sequence!(%Event{sequence: sequence}), do: sequence
  defp event_sequence!(other), do: invalid!("invalid event #{inspect(other)}")

  defp validate_tool_alignment!(%Event{kind: kind, tool_call_id: id} = event, calls)
       when kind in [:tool_call, "tool_call"] do
    unless is_binary(id) and id != "",
      do: invalid!("tool_call events require a non-empty tool_call_id")

    if Map.has_key?(calls, id), do: invalid!("duplicate tool_call_id #{inspect(id)}")
    Map.put(calls, id, event_tool_name(event))
  end

  defp validate_tool_alignment!(%Event{kind: kind, tool_call_id: id} = event, calls)
       when kind in [:tool_result, "tool_result"] do
    case Map.fetch(calls, id) do
      :error ->
        invalid!("tool_result #{inspect(id)} has no preceding tool_call awaiting a result")

      {:ok, call_name} ->
        result_name = event_tool_name(event)

        if not is_nil(call_name) and not is_nil(result_name) and
             to_string(call_name) != to_string(result_name),
           do: invalid!("tool_result #{inspect(id)} name does not match its tool_call")
    end

    Map.delete(calls, id)
  end

  defp validate_tool_alignment!(%Event{}, calls), do: calls

  defp validate_event_time!(%Event{
         started_at_us: started,
         duration_us: duration,
         kind: kind,
         component: component,
         tool_name: tool_name,
         tool_call_id: tool_call_id,
         metadata: metadata
       }) do
    validate_event_names!(kind, component, tool_name, tool_call_id)
    validate_event_measurements!(started, duration)
    unless is_map(metadata), do: invalid!("event metadata must be a map")
  end

  defp validate_event_names!(kind, component, tool_name, tool_call_id) do
    unless valid_name?(kind), do: invalid!("event kind must be a non-empty atom or string")

    unless is_nil(component) or valid_name?(component),
      do: invalid!("event component must be an atom or string")

    unless is_nil(tool_name) or valid_name?(tool_name),
      do: invalid!("event tool_name must be an atom or string")

    unless is_nil(tool_call_id) or is_binary(tool_call_id),
      do: invalid!("event tool_call_id must be a string")
  end

  defp validate_event_measurements!(started, duration) do
    unless optional_non_negative_integer?(started),
      do: invalid!("event started_at_us must be non-negative")

    unless optional_non_negative_integer?(duration),
      do: invalid!("event duration_us must be non-negative")
  end

  defp validate_usage!(%Usage{} = usage) do
    validate_usage_counts!(usage)
    validate_usage_cost!(usage)

    unless is_map(usage.metadata), do: invalid!("usage metadata must be a map")
  end

  defp validate_usage!(other),
    do: invalid!("usage must be a Usage struct, got: #{inspect(other)}")

  defp validate_usage_counts!(usage) do
    Enum.each(
      [usage.input_tokens, usage.output_tokens, usage.total_tokens, usage.requests],
      fn value ->
        unless is_integer(value) and value >= 0,
          do: invalid!("usage counts must be non-negative integers")
      end
    )

    unless usage.total_tokens == 0 or
             usage.total_tokens == usage.input_tokens + usage.output_tokens,
           do: invalid!("usage total_tokens must equal input_tokens plus output_tokens")
  end

  defp validate_usage_cost!(usage) do
    unless is_nil(usage.cost) or (is_number(usage.cost) and usage.cost >= 0),
      do: invalid!("usage cost must be non-negative")

    unless is_nil(usage.currency) or is_binary(usage.currency),
      do: invalid!("usage currency must be a string")
  end

  defp validate_timing!(%Timing{
         started_at: started,
         finished_at: finished,
         duration_us: duration
       }) do
    unless is_nil(started) or is_binary(started),
      do: invalid!("timing started_at must be a string")

    unless is_nil(finished) or is_binary(finished),
      do: invalid!("timing finished_at must be a string")

    unless optional_non_negative_integer?(duration),
      do: invalid!("timing duration_us must be non-negative")
  end

  defp validate_timing!(other),
    do: invalid!("timing must be a Timing struct, got: #{inspect(other)}")

  defp validate_cache!(nil), do: :ok

  defp validate_cache!(%Cache{key: key, hit: hit, metadata: metadata})
       when is_binary(key) and key != "" and is_boolean(hit) and is_map(metadata), do: :ok

  defp validate_cache!(other),
    do:
      invalid!(
        "cache must have a non-empty string key, boolean hit, and map metadata; got: #{inspect(other)}"
      )

  defp validate_parameters!(parameters) when is_list(parameters) do
    Enum.each(parameters, fn
      %Parameter{name: name, kind: kind, metadata: metadata}
      when (is_atom(name) or (is_binary(name) and name != "")) and
             (is_atom(kind) or (is_binary(kind) and kind != "")) and is_map(metadata) ->
        :ok

      other ->
        invalid!("invalid named parameter #{inspect(other)}")
    end)

    names = Enum.map(parameters, &to_string(&1.name))
    unless Enum.uniq(names) == names, do: invalid!("named parameter names must be unique")
  end

  defp validate_parameters!(other),
    do: invalid!("named_parameters must be a list, got: #{inspect(other)}")

  defp encode_optional_struct(nil), do: nil
  defp encode_optional_struct(value), do: encode_struct(value)

  defp encode_struct(value) when is_struct(value), do: value |> Map.from_struct() |> encode_term()

  defp decode_optional_struct(nil, _module), do: nil
  defp decode_optional_struct(value, module), do: decode_struct(value, module)

  defp decode_structs(values, module) when is_list(values),
    do: Enum.map(values, &decode_struct(&1, module))

  defp decode_structs(_values, module),
    do: decode_error!("expected a list of #{inspect(module)} values")

  defp decode_struct(value, module) when is_map(value) do
    require_struct_keys!(value, module)
    value = decode_term(value)
    value = struct!(module, atomize_known(value, module))
    validate_decoded_struct!(value)
  end

  defp decode_struct(value, module),
    do: decode_error!("expected #{inspect(module)} map, got: #{inspect(value)}")

  defp encode_term(%Imp.Example{} = example) do
    %{
      "__trajectory_type__" => "example",
      "fields" => encode_term(Imp.Example.to_map(example)),
      "input_keys" => encode_term(example.input_keys),
      "demos" => encode_term(example.demos)
    }
  end

  defp encode_term(%Imp.Prediction{} = prediction) do
    %{
      "__trajectory_type__" => "prediction",
      "fields" => encode_term(Imp.Prediction.to_map(prediction)),
      "completions" => encode_term(prediction.completions),
      "score" => prediction.score,
      "metadata" => encode_term(prediction.metadata)
    }
  end

  defp encode_term(%Failure{} = failure) do
    validate_failure!(failure)

    %{
      "__trajectory_type__" => "failure",
      "value" => failure |> Map.from_struct() |> encode_term()
    }
  end

  defp encode_term(%Imp.Adapter.Types.File{path: path}) when is_binary(path) do
    decode_error!(
      "trajectory cannot persist a deferred file path; read the trusted file into " <>
        "%Imp.Adapter.Types.File{data: ...} before serialization"
    )
  end

  defp encode_term(%module{} = value)
       when module in [
              Imp.Adapter.Types.Image,
              Imp.Adapter.Types.Audio,
              Imp.Adapter.Types.File,
              Imp.Adapter.Types.Document,
              Imp.Adapter.Types.Code,
              Imp.Adapter.Types.Reasoning,
              Imp.Adapter.Types.ToolCall,
              Imp.Adapter.Types.ToolResult
            ] do
    %{
      "__trajectory_type__" => module |> Module.split() |> List.last() |> Macro.underscore(),
      "value" => value |> Map.from_struct() |> encode_term()
    }
  end

  defp encode_term(value) when is_struct(value),
    do: decode_error!("trajectory contains an unsupported struct: #{inspect(value.__struct__)}")

  defp encode_term(value) when is_map(value) do
    encoded = encode_map(value)

    if Map.has_key?(encoded, "__trajectory_type__"),
      do: %{"__trajectory_type__" => "map", "value" => encoded},
      else: encoded
  end

  defp encode_term([]), do: []

  defp encode_term([head | tail] = value) do
    if proper_list?(value) do
      Enum.map(value, &encode_term/1)
    else
      %{
        "__trajectory_type__" => "improper_list",
        "head" => encode_term(head),
        "tail" => encode_term(tail)
      }
    end
  end

  defp encode_term(value) when is_tuple(value),
    do: %{"__trajectory_type__" => "tuple", "value" => value |> Tuple.to_list() |> encode_term()}

  defp encode_term(nil), do: nil

  defp encode_term(value) when is_atom(value),
    do: %{"__trajectory_type__" => "atom", "value" => Atom.to_string(value)}

  defp encode_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp encode_term(value),
    do: decode_error!("trajectory contains a non-JSON-safe value: #{inspect(value)}")

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp encode_map(value) do
    Enum.reduce(value, %{}, fn
      {key, nested}, encoded when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(encoded, key),
          do: decode_error!("trajectory map contains colliding key #{inspect(key)}"),
          else: Map.put(encoded, key, encode_term(nested))

      {key, _nested}, _encoded ->
        decode_error!("trajectory map keys must be atoms or strings, got: #{inspect(key)}")
    end)
  end

  defp decode_term(
         %{
           "__trajectory_type__" => "example",
           "fields" => fields,
           "input_keys" => keys,
           "demos" => demos
         } = value
       ) do
    require_typed_keys!(value, ~w(__trajectory_type__ fields input_keys demos))

    fields
    |> decode_term()
    |> Imp.Example.new()
    |> maybe_inputs(decode_term(keys))
    |> maybe_demos(decode_term(demos))
  end

  defp decode_term(
         %{
           "__trajectory_type__" => "prediction",
           "fields" => fields,
           "completions" => completions,
           "score" => score,
           "metadata" => metadata
         } = value
       ) do
    require_typed_keys!(value, ~w(__trajectory_type__ fields completions score metadata))

    Imp.Prediction.new(decode_term(fields),
      completions: decode_term(completions),
      score: score,
      metadata: decode_term(metadata)
    )
  end

  defp decode_term(%{"__trajectory_type__" => "tuple", "value" => value} = tagged)
       when is_list(value) do
    require_typed_keys!(tagged, ~w(__trajectory_type__ value))
    value |> decode_term() |> List.to_tuple()
  end

  defp decode_term(
         %{"__trajectory_type__" => "improper_list", "head" => head, "tail" => tail} = tagged
       ) do
    require_typed_keys!(tagged, ~w(__trajectory_type__ head tail))
    [decode_term(head) | decode_term(tail)]
  end

  defp decode_term(%{"__trajectory_type__" => "atom", "value" => value} = tagged)
       when is_binary(value) do
    require_typed_keys!(tagged, ~w(__trajectory_type__ value))
    existing_atom(value)
  end

  defp decode_term(%{"__trajectory_type__" => "map", "value" => value} = tagged)
       when is_map(value) do
    require_typed_keys!(tagged, ~w(__trajectory_type__ value))
    Map.new(value, fn {key, nested} -> {key, decode_term(nested)} end)
  end

  defp decode_term(%{"__trajectory_type__" => tag, "value" => value} = tagged) do
    require_typed_keys!(tagged, ~w(__trajectory_type__ value))
    module = Map.fetch!(typed_modules(), tag)
    require_struct_keys!(value, module)
    value = decode_term(value)
    value |> atomize_known(module) |> then(&struct!(module, &1)) |> validate_decoded_struct!()
  rescue
    KeyError -> decode_error!("unknown typed trajectory value #{inspect(tag)}")
  end

  defp decode_term(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, decode_term(nested)} end)

  defp decode_term(value) when is_list(value), do: Enum.map(value, &decode_term/1)

  defp decode_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp decode_term(value), do: decode_error!("invalid JSON trajectory value #{inspect(value)}")

  defp typed_modules do
    %{
      "image" => Imp.Adapter.Types.Image,
      "audio" => Imp.Adapter.Types.Audio,
      "file" => Imp.Adapter.Types.File,
      "document" => Imp.Adapter.Types.Document,
      "code" => Imp.Adapter.Types.Code,
      "reasoning" => Imp.Adapter.Types.Reasoning,
      "tool_call" => Imp.Adapter.Types.ToolCall,
      "tool_result" => Imp.Adapter.Types.ToolResult,
      "failure" => Failure
    }
  end

  defp redact_value(%Imp.Adapter.Types.Image{} = value, keys),
    do: redact_attachment(value, [:data], keys)

  defp redact_value(%Imp.Adapter.Types.Audio{} = value, keys),
    do: redact_attachment(value, [:data], keys)

  defp redact_value(%Imp.Adapter.Types.File{} = value, keys),
    do: redact_attachment(value, [:data], keys)

  defp redact_value(value, keys) when is_struct(value) do
    module = value.__struct__
    value |> Map.from_struct() |> redact_value(keys) |> then(&struct!(module, &1))
  end

  defp redact_value(value, keys) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if redacted_entry?(key, nested, keys) and not accounting_value?(key, nested),
        do: {key, "[REDACTED]"},
        else: {key, redact_value(nested, keys)}
    end)
  end

  defp redact_value([key, nested], keys)
       when is_atom(key) or is_binary(key) or is_map(key) do
    if redacted_entry?(key, nested, keys) and not accounting_value?(key, nested),
      do: [key, "[REDACTED]"],
      else: [key, redact_value(nested, keys)]
  end

  defp redact_value([], _keys), do: []

  # Low-level provider failures may contain improper lists. Walk cons cells
  # directly so trajectory persistence remains fail-safe at that boundary.
  defp redact_value([head | tail], keys),
    do: [redact_value(head, keys) | redact_value(tail, keys)]

  defp redact_value({key, nested}, keys) when is_atom(key) or is_binary(key) do
    if redacted_entry?(key, nested, keys) and not accounting_value?(key, nested),
      do: {key, "[REDACTED]"},
      else: {key, redact_value(nested, keys)}
  end

  defp redact_value(value, keys) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&redact_value(&1, keys)) |> List.to_tuple()

  defp redact_value(value, keys), do: Imp.Redaction.redact(value, keys)

  defp accounting_value?(key, value) when is_atom(key) or is_binary(key),
    do:
      to_string(key) in ["input_tokens", "output_tokens", "total_tokens"] and
        is_integer(value) and value >= 0

  defp accounting_value?(_key, _value), do: false

  defp redacted_key?(key, keys) do
    case Imp.Redaction.redact({key, :visible}, keys) do
      {^key, "[REDACTED]"} -> true
      _other -> false
    end
  end

  defp redacted_entry?(key, value, keys) do
    if keys == Imp.Redaction.default_keys(),
      do: Imp.Redaction.credential_entry?(key, value),
      else: redacted_key?(key, keys)
  end

  defp redact_attachment(value, preserved_fields, keys) do
    module = value.__struct__

    value
    |> Map.from_struct()
    |> Map.new(fn {key, nested} ->
      if key in preserved_fields,
        do: {key, nested},
        else: {key, redact_value(nested, keys)}
    end)
    |> then(&struct!(module, &1))
  end

  defp validate_failure!(%Failure{kind: kind, message: message, retryable: retryable}) do
    unless valid_name?(kind) and is_binary(message) and is_boolean(retryable),
      do:
        decode_error!(
          "trajectory failure must have a kind, string message, and boolean retryable"
        )
  end

  defp validate_decoded_struct!(%Failure{} = failure) do
    validate_failure!(failure)
    failure
  end

  defp validate_decoded_struct!(%Imp.Adapter.Types.File{path: path}) when is_binary(path) do
    decode_error!(
      "saved trajectory file values cannot carry deferred host paths; persist file data instead"
    )
  end

  defp validate_decoded_struct!(value), do: value

  defp require_struct_keys!(value, Imp.Adapter.Types.File = module) do
    expected = module.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.map(&to_string/1)

    unless MapSet.subset?(MapSet.new(Map.keys(value)), MapSet.new(expected)),
      do: decode_error!("#{inspect(module)} wire keys do not match its schema")
  end

  defp require_struct_keys!(value, module) do
    expected = module.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.map(&to_string/1)

    unless MapSet.new(Map.keys(value)) == MapSet.new(expected),
      do: decode_error!("#{inspect(module)} wire keys do not match its schema")
  end

  defp require_typed_keys!(value, expected) do
    unless MapSet.new(Map.keys(value)) == MapSet.new(expected),
      do: decode_error!("typed trajectory value keys do not match its schema")
  end

  defp atomize_known(map, module) do
    allowed = module.__struct__() |> Map.keys() |> MapSet.new()

    Map.new(map, fn {key, value} ->
      atom = if is_atom(key), do: key, else: existing_atom(key)

      unless MapSet.member?(allowed, atom),
        do: decode_error!("unknown #{inspect(module)} field #{inspect(key)}")

      {atom, value}
    end)
  end

  defp maybe_inputs(example, nil), do: example
  defp maybe_inputs(example, keys), do: Imp.Example.with_inputs(example, keys)
  defp maybe_demos(example, []), do: example
  defp maybe_demos(example, demos), do: Imp.Example.with_demos(example, demos)

  defp decode_runtime(runtime) when is_binary(runtime) do
    case Enum.find(@runtimes, &(Atom.to_string(&1) == runtime)) do
      nil -> decode_error!("unsupported trajectory runtime #{inspect(runtime)}")
      value -> value
    end
  end

  defp decode_runtime(runtime),
    do: decode_error!("trajectory runtime must be a string, got: #{inspect(runtime)}")

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> decode_error!("unknown atom in trajectory payload: #{inspect(value)}")
  end

  defp wire_keys do
    ~w(type schema_version runtime index example prediction trace score feedback metric_metadata error program_id rollout_id events usage timing cache named_parameters metadata)
  end

  defp event_known_keys do
    [
      :input,
      "input",
      :output,
      "output",
      :action,
      "action",
      :component,
      "component",
      :reasoning,
      "reasoning",
      :error,
      "error",
      :started_at_us,
      "started_at_us",
      :duration_us,
      "duration_us"
    ]
  end

  defp fetch(map, key, default \\ nil) when is_map(map) do
    string_key = to_string(key)

    if not is_binary(key) and Map.has_key?(map, key) and Map.has_key?(map, string_key),
      do: invalid!("map contains both #{inspect(key)} and #{inspect(string_key)}"),
      else: Map.get(map, key, Map.get(map, string_key, default))
  end

  defp has_field?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, to_string(key))

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp valid_name?(value), do: is_atom(value) or (is_binary(value) and value != "")
  defp event_tool_name(%Event{tool_name: name}), do: name
  defp invalid!(message), do: raise(ArgumentError, "invalid optimizer trajectory: #{message}")
  defp decode_error!(message), do: raise(DecodeError, message: message)
end

defmodule Imp.Optimizer.TrajectoryRunner do
  @moduledoc """
  Evaluates examples into ordered, provider-neutral optimizer trajectories.

  Program and metric failures are captured in the returned trajectories so a
  failed example does not discard the rest of a bounded-concurrency batch.
  """

  alias Imp.Optimizer.{Trace, Trajectory}
  alias Imp.Optimizer.GEPA.Coordinator

  require Logger

  @spec run(struct(), Enumerable.t(), function(), keyword()) :: [Trajectory.t()]
  def run(program, examples, metric, opts \\ []) do
    program = annotate_predictors(program)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)
    timeout = Keyword.get(opts, :timeout, 5_000)

    indexed_examples = examples |> Enum.to_list() |> Enum.with_index()

    case Keyword.get(opts, :deadline) do
      nil ->
        run_stream(program, indexed_examples, metric, opts, max_concurrency, timeout)

      :infinity ->
        run_stream(program, indexed_examples, metric, opts, max_concurrency, timeout)

      deadline ->
        run_until_deadline(
          program,
          indexed_examples,
          metric,
          opts,
          max_concurrency,
          deadline,
          timeout
        )
    end
  end

  defp run_stream(program, indexed_examples, metric, opts, max_concurrency, timeout) do
    indexed_examples
    |> Imp.Tasks.async_stream(
      fn {example, index} -> evaluate(program, example, index, metric, opts) end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> to_trajectories(opts, "timeout: #{inspect(timeout)}")
  end

  # Task.async_stream applies its timeout per task. Split a deadline-bound
  # evaluation into effective-concurrency waves so every new wave gets only
  # the time remaining from the original monotonic deadline.
  defp run_until_deadline(
         program,
         indexed_examples,
         metric,
         opts,
         max_concurrency,
         deadline,
         timeout
       ) do
    effective_concurrency =
      min(max_concurrency, Imp.Settings.snapshot() |> Map.fetch!(:async_max_workers))

    indexed_examples
    |> Enum.chunk_every(effective_concurrency)
    |> Enum.flat_map(fn wave ->
      case Coordinator.remaining(deadline) do
        0 ->
          Enum.map(wave, &timed_out_trajectory(&1, opts))

        remaining ->
          run_deadline_wave(
            program,
            wave,
            metric,
            opts,
            effective_concurrency,
            deadline,
            # The per-row timeout still applies under a deadline: one hung
            # row may consume at most min(timeout, remaining), not the whole
            # remaining deadline (which would starve every later wave).
            min_budget(timeout, remaining)
          )
      end
    end)
  end

  defp min_budget(:infinity, remaining), do: remaining
  defp min_budget(timeout, remaining), do: min(timeout, remaining)

  defp run_deadline_wave(program, wave, metric, opts, max_concurrency, deadline, remaining) do
    wave
    |> Imp.Tasks.async_stream(
      fn {example, index} ->
        Coordinator.with_deadline({:deadline, deadline}, fn ->
          evaluate(program, example, index, metric, opts)
        end)
      end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: remaining,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> to_trajectories(opts, "deadline remaining: #{inspect(remaining)}ms")
  end

  defp to_trajectories(results, opts, budget) do
    trajectories =
      Enum.map(results, fn
        {:ok, trajectory} ->
          Imp.OperationalSafetyError.raise_if_present!(trajectory)
          trajectory

        {:exit, {{example, index}, reason}} ->
          Imp.OperationalSafetyError.raise_if_present!(reason)
          warn_killed_row(index, reason, budget)
          failed(index, normalize_example(example), [], {:task_exit, reason}, opts)

        {:exit, reason} ->
          Imp.OperationalSafetyError.raise_if_present!(reason)
          warn_killed_row(-1, reason, budget)
          failed(-1, nil, [], {:task_exit, reason}, opts)
      end)

    warn_killed_summary(trajectories)
    trajectories
  end

  # A killed task is machinery, not model behavior; scoring it 0.0 silently
  # would be indistinguishable from a real miss (mirrors Imp.Evaluate's
  # warning for the identical event).
  defp warn_killed_row(index, reason, budget) do
    Logger.warning(
      "Imp.Optimizer.Trajectory killed row #{index} (#{inspect(reason)}) after exceeding its " <>
        "time budget (#{budget}); recording score 0.0. This is a killed call, not a model " <>
        "miss - raise :timeout or use :infinity if your model calls are legitimately slow."
    )
  end

  defp warn_killed_summary(trajectories) do
    killed = Enum.count(trajectories, &Imp.Optimizer.Trajectory.killed?/1)

    if killed > 0 do
      Logger.warning(
        "Imp.Optimizer.Trajectory: #{killed} of #{length(trajectories)} rows were killed on " <>
          "time budget and scored 0.0; candidate scores from this batch are deflated by " <>
          "machinery, not model behavior."
      )
    end
  end

  defp timed_out_trajectory({example, index}, opts) do
    warn_killed_row(index, :deadline_exhausted, "deadline remaining: 0ms")
    failed(index, normalize_example(example), [], {:task_exit, :timeout}, opts)
  end

  defp evaluate(program, example, index, metric, opts) do
    example = normalize_example(example)
    inputs = example |> Imp.Example.inputs() |> Imp.Example.to_map()
    Trace.start()

    case safe_call(program, inputs) do
      {:ok, %Imp.Prediction{} = prediction} ->
        trace =
          case Trace.finish() do
            [] ->
              prediction.metadata[:optimizer_trace] || prediction.metadata["optimizer_trace"] ||
                []

            captured ->
              captured
          end

        metric_trace = if Keyword.get(opts, :metric_trace, true), do: trace, else: nil
        result = safe_metric(metric, example, prediction, metric_trace)

        %Trajectory{
          index: index,
          example: example,
          prediction: prediction,
          trace: trace,
          score: result.score,
          feedback: result.feedback,
          metric_metadata: result.metadata,
          error: metric_error(result),
          program_id: Keyword.get(opts, :program_id),
          rollout_id: Keyword.get(opts, :rollout_id)
        }
        |> project_runtime(opts)

      {:error, reason} ->
        trace = Trace.finish()
        failed(index, example, trace, reason, opts)
    end
  rescue
    safety in Imp.OperationalSafetyError ->
      failed(index, normalize_example(example), Trace.finish(), safety, opts)

    error ->
      failed(index, normalize_example(example), Trace.finish(), Exception.message(error), opts)
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety ->
          failed(index, normalize_example(example), Trace.finish(), safety, opts)

        nil ->
          failed(index, normalize_example(example), Trace.finish(), {kind, reason}, opts)
      end
  end

  defp annotate_predictors(program) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, program ->
      Imp.ProgramParameters.update_predictor(program, name, fn predictor ->
        %{predictor | metadata: Map.put(predictor.metadata, :optimizer_predictor_name, name)}
      end)
    end)
  end

  defp safe_call(program, inputs) do
    case Imp.Module.call(program, inputs) do
      {:ok, %Imp.Prediction{}} = success -> success
      {:ok, other} -> {:error, {:invalid_prediction, other}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_program_result, other}}
    end
  rescue
    safety in Imp.OperationalSafetyError -> {:error, safety}
    error -> {:error, Exception.message(error)}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety -> {:error, safety}
        nil -> {:error, {kind, reason}}
      end
  end

  defp safe_metric(metric, example, prediction, trace) do
    args =
      if is_function(metric, 3), do: [example, prediction, trace], else: [example, prediction]

    metric |> apply(args) |> Imp.Metrics.normalize_result()
  rescue
    safety in Imp.OperationalSafetyError ->
      Imp.Metrics.normalize_result(%{
        score: 0.0,
        feedback: nil,
        metadata: %{imp_operational_safety: safety}
      })

    error ->
      Imp.Metrics.normalize_result(%{
        score: 0.0,
        feedback: {:metric_error, Exception.message(error)},
        metadata: %{imp_metric_error: Exception.message(error)}
      })
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety ->
          Imp.Metrics.normalize_result(%{
            score: 0.0,
            feedback: nil,
            metadata: %{imp_operational_safety: safety}
          })

        nil ->
          Imp.Metrics.normalize_result(%{
            score: 0.0,
            feedback: {:metric_error, {kind, reason}},
            metadata: %{imp_metric_error: {kind, reason}}
          })
      end
  end

  defp metric_error(%Imp.Metrics.Result{metadata: %{imp_operational_safety: safety}}),
    do: safety

  defp metric_error(%Imp.Metrics.Result{metadata: %{imp_metric_error: reason}}),
    do: {:metric_error, reason}

  defp metric_error(_result), do: nil

  defp failed(index, example, trace, reason, opts) do
    %Trajectory{
      index: index,
      example: example,
      prediction: nil,
      trace: trace,
      score: 0.0,
      feedback: nil,
      metric_metadata: %{},
      error: reason,
      program_id: Keyword.get(opts, :program_id),
      rollout_id: Keyword.get(opts, :rollout_id)
    }
    |> project_runtime(opts)
  end

  defp project_runtime(trajectory, opts) do
    Trajectory.project(Keyword.get(opts, :runtime, :evaluation), trajectory)
  end

  defp normalize_example(%Imp.Example{} = example), do: example
  defp normalize_example(example), do: Imp.Example.new(example)
end

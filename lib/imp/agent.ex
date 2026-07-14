defmodule Imp.Agent do
  @moduledoc """
  Typed agent runtime with tools, child agents, memory/context, policies, and traces.

  Agents are ordinary Elixir structs. A handler can be arity 2:

      fn inputs, runtime -> {:ok, output, runtime} end

  or arity 3 when it needs access to the agent's tools or children:

      fn agent, inputs, runtime -> Imp.Agent.call_tool(agent, :tool, inputs, runtime) end

  Tool execution is policy-gated with `:tool_policy`, and every trace event is
  redacted through `Imp.Agent.Runtime` before it is stored or streamed.

  Agent failure boundaries are explicit:

  - handler exceptions return `{:error, {:handler_error, agent_name, reason}, runtime}`;
  - tool exceptions return `{:error, {:tool_error, tool_name, reason}, runtime}`;
  - tool-policy exceptions return
    `{:error, {:tool_policy_error, tool_name, reason}, runtime}`;
  - schema failures return `{:error, {:missing_required, fields}, runtime}`.

  The returned runtime preserves traces accumulated before the failure.
  """

  alias Imp.Agent.Runtime

  defstruct [
    :name,
    :handler,
    tools: %{},
    children: %{},
    input_schema: %{},
    output_schema: %{},
    tool_policy: :allow
  ]

  @option_schema [
    tools: [type: {:custom, Imp.Tool, :validate_tools, []}, default: []],
    children: [type: {:custom, __MODULE__, :validate_children, []}, default: []],
    input_schema: [type: {:map, :any, :any}, default: %{}],
    output_schema: [type: {:map, :any, :any}, default: %{}],
    tool_policy: [
      type: {:custom, Imp.ToolPolicy, :validate, []},
      default: :allow
    ]
  ]

  @doc """
  Creates an agent.

  Options:

  - `:tools` - list of `Imp.Tool` values.
  - `:children` - list of child agents.
  - `:input_schema` / `:output_schema` - maps with `:required` keys.
  - `:tool_policy` - `:allow`, a list of allowed names, or a predicate function.
  """
  def new(name, handler, opts \\ [])

  def new(name, handler, opts) when is_function(handler, 2) or is_function(handler, 3) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Agent.new/3")

    %__MODULE__{
      name: normalize_name(name),
      handler: handler,
      tools: Imp.Tool.index_tools!(opts[:tools], "Imp.Agent.new/3"),
      children: index_children!(opts[:children]),
      input_schema: opts[:input_schema],
      output_schema: opts[:output_schema],
      tool_policy: opts[:tool_policy]
    }
  end

  def new(_name, handler, _opts) do
    raise ArgumentError,
          "Imp.Agent.new/3 expects an arity-2 or arity-3 handler; got: #{inspect(handler)}"
  end

  def validate_children(children) when is_list(children) do
    case Enum.find(children, &(not match?(%__MODULE__{}, &1))) do
      nil ->
        {:ok, children}

      invalid ->
        {:error, "expected a list of Imp.Agent structs, got invalid entry: #{inspect(invalid)}"}
    end
  end

  def validate_children(children) do
    {:error, "expected a list of Imp.Agent structs, got: #{inspect(children)}"}
  end

  @doc """
  Runs an agent and returns `{:ok, output, runtime}` or `{:error, reason, runtime}`.

  Handler exceptions, policy exceptions, schema failures, and tool failures are
  returned as structured errors with redacted traces instead of escaping the
  agent boundary.
  """
  def run(%__MODULE__{} = agent, inputs, runtime \\ Runtime.new()) do
    with :ok <- validate(inputs, agent.input_schema) do
      inputs = resolve_inputs(inputs, runtime)

      case invoke_handler(agent, inputs, runtime) do
        {:ok, output, runtime} ->
          case validate(output, agent.output_schema) do
            :ok ->
              {:ok, output,
               Runtime.trace(runtime, %{type: :agent, agent: agent.name, output: output})}

            {:error, reason} ->
              {:error, reason,
               Runtime.trace(runtime, %{type: :agent_error, agent: agent.name, error: reason})}
          end

        {:error, reason, runtime} ->
          {:error, reason,
           Runtime.trace(runtime, %{type: :agent_error, agent: agent.name, error: reason})}

        {:error, reason} ->
          {:error, reason,
           Runtime.trace(runtime, %{type: :agent_error, agent: agent.name, error: reason})}

        other ->
          reason = {:invalid_handler_result, agent.name, other}

          {:error, reason,
           Runtime.trace(runtime, %{type: :agent_error, agent: agent.name, error: reason})}
      end
    else
      {:error, reason} ->
        {:error, reason,
         Runtime.trace(runtime, %{type: :agent_error, agent: agent.name, error: reason})}
    end
  end

  @doc "Calls a named tool through the agent's policy and trace boundary."
  def call_tool(%__MODULE__{} = agent, name, input, %Runtime{} = runtime) do
    name = normalize_name(name)

    with :ok <- authorize_tool(agent, name, input) do
      case Map.fetch(agent.tools, name) do
        {:ok, tool} ->
          try do
            output = Imp.Tool.call(tool, input)

            {:ok, output,
             Runtime.trace(runtime, %{type: :tool, tool: name, input: input, output: output})}
          rescue
            exception ->
              reason = {:tool_error, name, Exception.message(exception)}

              {:error, reason,
               Runtime.trace(runtime, %{type: :tool_error, tool: name, error: reason})}
          catch
            kind, reason ->
              reason = {:tool_error, name, {kind, reason}}

              {:error, reason,
               Runtime.trace(runtime, %{type: :tool_error, tool: name, error: reason})}
          end

        :error ->
          {:error, {:unknown_tool, name},
           Runtime.trace(runtime, %{type: :tool_error, tool: name, error: :unknown_tool})}
      end
    else
      {:error, reason} ->
        {:error, reason, Runtime.trace(runtime, %{type: :tool_denied, tool: name, error: reason})}
    end
  end

  defp invoke_handler(%__MODULE__{handler: handler} = agent, inputs, runtime) do
    try do
      case :erlang.fun_info(handler, :arity) do
        {:arity, 2} -> handler.(inputs, runtime)
        {:arity, 3} -> handler.(agent, inputs, runtime)
      end
    rescue
      exception -> {:error, {:handler_error, agent.name, Exception.message(exception)}, runtime}
    catch
      kind, reason -> {:error, {:handler_error, agent.name, {kind, reason}}, runtime}
    end
  end

  defp authorize_tool(%__MODULE__{tool_policy: policy}, name, input),
    do: Imp.ToolPolicy.authorize(policy, name, input)

  @doc "Runs a named child agent with the current runtime."
  def call_child(%__MODULE__{} = agent, name, input, %Runtime{} = runtime) do
    name = normalize_name(name)

    case Map.fetch(agent.children, name) do
      {:ok, child} ->
        run(child, input, runtime)

      :error ->
        {:error, {:unknown_child_agent, name},
         Runtime.trace(runtime, %{type: :child_error, child: name})}
    end
  end

  @doc "Streams final output/error plus the completed trace bundle."
  def stream(%__MODULE__{} = agent, inputs, runtime \\ Runtime.new()) do
    Stream.resource(
      fn -> run(agent, inputs, runtime) end,
      fn
        {:ok, output, runtime} ->
          events = [%{type: :output, output: output}, %{type: :trace, traces: runtime.traces}]
          {events, :halt}

        {:error, reason, runtime} ->
          {[%{type: :error, error: reason}, %{type: :trace, traces: runtime.traces}], :halt}

        :halt ->
          {:halt, :halt}
      end,
      fn _ -> :ok end
    )
  end

  @doc "Streams trace events incrementally, followed by the final output/error event."
  def stream_events(%__MODULE__{} = agent, inputs, runtime \\ Runtime.new()) do
    Stream.resource(
      fn ->
        owner = self()
        ref = make_ref()
        runtime = %{runtime | event_sink: fn event -> send(owner, {:agent_event, ref, event}) end}
        task = Imp.Tasks.async_nolink(fn -> run(agent, inputs, runtime) end)
        %{task: task, ref: ref, done?: false}
      end,
      fn
        %{done?: true} = state ->
          {:halt, state}

        %{task: task, ref: ref} = state ->
          receive do
            {:agent_event, ^ref, event} ->
              {[%{type: :trace, event: event}], state}

            {task_ref, {:ok, output, runtime}} when task_ref == task.ref ->
              Process.demonitor(task.ref, [:flush])
              {[%{type: :output, output: output, traces: runtime.traces}], %{state | done?: true}}

            {task_ref, {:error, reason, runtime}} when task_ref == task.ref ->
              Process.demonitor(task.ref, [:flush])
              {[%{type: :error, error: reason, traces: runtime.traces}], %{state | done?: true}}

            {:DOWN, task_ref, :process, _pid, reason} when task_ref == task.ref ->
              {[%{type: :error, error: reason}], %{state | done?: true}}
          end
      end,
      fn
        %{done?: true} -> :ok
        %{task: task} -> Task.shutdown(task, :brutal_kill)
      end
    )
  end

  defp resolve_inputs(inputs, runtime) do
    Map.new(inputs, fn {key, value} ->
      case Runtime.resolve(runtime, value) do
        {:ok, resolved} -> {key, resolved}
        :error -> {key, value}
      end
    end)
  end

  defp validate(_value, schema) when schema in [%{}, nil], do: :ok

  defp validate(value, _schema) when not is_map(value),
    do: {:error, {:invalid_schema_value, inspect(value)}}

  defp validate(value, schema) do
    missing =
      schema
      |> Map.get(:required, [])
      |> Enum.reject(&Map.has_key?(value, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_required, keys}}
    end
  end

  defp index_children!(children), do: Map.new(children, &{&1.name, &1})

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: existing_atom_or_string(name)

  defp normalize_name(name) do
    raise ArgumentError,
          "Imp.Agent names must be atoms or strings; got: #{inspect(name)}"
  end

  defp existing_atom_or_string(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end
end

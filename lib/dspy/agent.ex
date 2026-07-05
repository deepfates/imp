defmodule DSPy.Agent do
  @moduledoc "Typed agent runtime with tools, child agents, memory/context, and traces."

  alias DSPy.Agent.Runtime

  defstruct [:name, :handler, tools: %{}, children: %{}, input_schema: %{}, output_schema: %{}]

  def new(name, handler, opts \\ []) when is_function(handler, 2) do
    %__MODULE__{
      name: normalize_name(name),
      handler: handler,
      tools: index_by_name(Keyword.get(opts, :tools, [])),
      children: index_by_name(Keyword.get(opts, :children, [])),
      input_schema: Keyword.get(opts, :input_schema, %{}),
      output_schema: Keyword.get(opts, :output_schema, %{})
    }
  end

  def run(%__MODULE__{} = agent, inputs, runtime \\ Runtime.new()) do
    with :ok <- validate(inputs, agent.input_schema),
         {:ok, output, runtime} <- agent.handler.(resolve_inputs(inputs, runtime), runtime),
         :ok <- validate(output, agent.output_schema) do
      {:ok, output, Runtime.trace(runtime, %{type: :agent, agent: agent.name, output: output})}
    else
      {:error, reason, runtime} ->
        {:error, reason,
         Runtime.trace(runtime, %{type: :agent_error, agent: agent.name, error: reason})}

      {:error, reason} ->
        {:error, reason,
         Runtime.trace(runtime, %{type: :agent_error, agent: agent.name, error: reason})}
    end
  end

  def call_tool(%__MODULE__{} = agent, name, input, %Runtime{} = runtime) do
    name = normalize_name(name)

    case Map.fetch(agent.tools, name) do
      {:ok, tool} ->
        try do
          output = DSPy.Tool.call(tool, input)

          {:ok, output,
           Runtime.trace(runtime, %{type: :tool, tool: name, input: input, output: output})}
        rescue
          exception ->
            reason = {:tool_error, name, Exception.message(exception)}

            {:error, reason,
             Runtime.trace(runtime, %{type: :tool_error, tool: name, error: reason})}
        end

      :error ->
        {:error, {:unknown_tool, name},
         Runtime.trace(runtime, %{type: :tool_error, tool: name, error: :unknown_tool})}
    end
  end

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

  defp resolve_inputs(inputs, runtime) do
    Map.new(inputs, fn {key, value} ->
      case Runtime.resolve(runtime, value) do
        {:ok, resolved} -> {key, resolved}
        :error -> {key, value}
      end
    end)
  end

  defp validate(_value, schema) when schema in [%{}, nil], do: :ok

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

  defp index_by_name(values), do: Map.new(values, fn item -> {item.name, item} end)
  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: String.to_atom(name)
end

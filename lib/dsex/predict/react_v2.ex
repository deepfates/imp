defmodule DSEx.Predict.ReActV2 do
  @moduledoc "Iterative tool-calling ReAct variant with a reserved submit step."

  @behaviour DSEx.Module

  defstruct [:signature, :react, tools: %{}, max_iters: 20, tool_policy: :allow]

  def new(signature, tools, opts \\ []) do
    signature = DSEx.Signature.ensure(signature)
    tool_map = tools |> Enum.map(&coerce_tool/1) |> Map.new(&{&1.name, &1})
    submit = DSEx.Tool.new(:submit, "Submit final outputs", fn args -> args end)
    tools = Map.put(tool_map, :submit, submit)

    react_signature = %DSEx.Signature{
      inputs:
        signature.inputs ++
          [
            DSEx.Signature.Field.new(:history, :input),
            DSEx.Signature.Field.new(:tools, :input)
          ],
      outputs: [
        DSEx.Signature.Field.new(
          %{name: :next_thought, metadata: %{optional: true}},
          :output
        ),
        DSEx.Signature.Field.new(%{name: :tool_calls, type: :array}, :output)
      ],
      instructions: signature.instructions
    }

    %__MODULE__{
      signature: signature,
      react: DSEx.Predict.Predict.new(react_signature, opts),
      tools: tools,
      max_iters: Keyword.get(opts, :max_iters, 20),
      tool_policy: Keyword.get(opts, :tool_policy, :allow)
    }
  end

  @impl true
  def call(%__MODULE__{} = agent, inputs) do
    run_loop(agent, Map.new(inputs), [], agent.max_iters)
  end

  defp run_loop(_agent, _inputs, history, 0) do
    {:ok, DSEx.Prediction.new(%{history: history, termination_reason: :max_iters})}
  end

  defp run_loop(agent, inputs, history, remaining) do
    tool_descriptions =
      agent.tools |> Map.values() |> Enum.map(&%{name: &1.name, description: &1.description})

    call_inputs = Map.merge(inputs, %{history: history, tools: tool_descriptions})

    with {:ok, prediction} <- DSEx.Predict.Predict.call(agent.react, call_inputs) do
      case DSEx.Prediction.get(prediction, :tool_calls, []) do
        [] ->
          final = project_outputs(agent.signature, prediction)
          {:ok, %{final | metadata: Map.put(final.metadata, :history, history)}}

        calls ->
          {events, final} = execute_calls(agent, List.wrap(calls))
          history = history ++ events

          denied = Enum.find(events, &match?(%{result: {:error, {:tool_denied, _name}}}, &1))

          cond do
            denied ->
              denied.result

            final ->
              final = Map.merge(final, %{history: history, termination_reason: :submit})

              case DSEx.Adapter.Chat.parse(agent.signature, final, []) do
                {:ok, prediction} ->
                  prediction =
                    prediction
                    |> DSEx.Prediction.put(:history, history)
                    |> DSEx.Prediction.put(:termination_reason, :submit)

                  {:ok, prediction}

                {:error, reason} ->
                  {:error, reason}
              end

            true ->
              run_loop(agent, %{}, history, remaining - 1)
          end
      end
    end
  end

  defp execute_calls(agent, calls) do
    Enum.reduce(calls, {[], nil}, fn call, {events, final} ->
      name = normalize_tool_name(agent.tools, Map.get(call, :name) || Map.get(call, "name"))

      args =
        (Map.get(call, :arguments) || Map.get(call, :args) || Map.get(call, "arguments") ||
           %{})
        |> normalize_args()

      tool = if name, do: Map.get(agent.tools, name)

      result =
        cond do
          is_nil(tool) -> {:error, :unknown_tool}
          not authorized_tool?(agent.tool_policy, name, args) -> {:error, {:tool_denied, name}}
          true -> DSEx.Tool.call(tool, args)
        end

      event = %{tool: name, arguments: args, result: result}
      final = if name == :submit and is_map(result), do: Map.new(result), else: final
      {events ++ [event], final}
    end)
  end

  defp authorized_tool?(:allow, _name, _args), do: true
  defp authorized_tool?(allowed, name, _args) when is_list(allowed), do: name in allowed

  defp authorized_tool?(policy, name, args) when is_function(policy, 2) do
    case policy.(name, args) do
      true -> true
      :ok -> true
      _other -> false
    end
  end

  defp authorized_tool?(policy, name, _args), do: name in List.wrap(policy)

  defp project_outputs(signature, prediction) do
    fields =
      Map.take(
        DSEx.Prediction.to_map(prediction),
        DSEx.Signature.output_names(signature)
      )

    DSEx.Prediction.new(fields, metadata: prediction.metadata)
  end

  defp coerce_tool(%DSEx.Tool{} = tool), do: tool

  defp normalize_tool_name(tools, name) do
    Enum.find_value(Map.keys(tools), fn known ->
      if to_string(known) == to_string(name), do: known
    end)
  end

  defp normalize_args(args) when is_map(args),
    do: Map.new(args, fn {key, value} -> {safe_existing_atom(key), value} end)

  defp normalize_args(args), do: args

  defp safe_existing_atom(key) when is_atom(key), do: key

  defp safe_existing_atom(key) do
    String.to_existing_atom(to_string(key))
  rescue
    ArgumentError -> to_string(key)
  end
end

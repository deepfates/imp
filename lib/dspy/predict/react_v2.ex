defmodule DSPy.Predict.ReActV2 do
  @moduledoc "Iterative tool-calling ReAct variant with a reserved submit step."

  @behaviour DSPy.Module

  defstruct [:signature, :react, tools: %{}, max_iters: 20]

  def new(signature, tools, opts \\ []) do
    signature = DSPy.Signature.ensure(signature)
    tool_map = tools |> Enum.map(&coerce_tool/1) |> Map.new(&{&1.name, &1})
    submit = DSPy.Tool.new(:submit, "Submit final outputs", fn args -> args end)
    tools = Map.put(tool_map, :submit, submit)

    react_signature = %DSPy.Signature{
      inputs:
        signature.inputs ++
          [
            DSPy.Signature.Field.new(:history, :input),
            DSPy.Signature.Field.new(:tools, :input)
          ],
      outputs: [
        DSPy.Signature.Field.new(%{name: :next_thought, metadata: %{optional: true}}, :output),
        DSPy.Signature.Field.new(:tool_calls, :output)
      ],
      instructions: signature.instructions
    }

    %__MODULE__{
      signature: signature,
      react: DSPy.Predict.Predict.new(react_signature, opts),
      tools: tools,
      max_iters: Keyword.get(opts, :max_iters, 20)
    }
  end

  @impl true
  def call(%__MODULE__{} = agent, inputs) do
    run_loop(agent, Map.new(inputs), [], agent.max_iters)
  end

  defp run_loop(_agent, _inputs, history, 0) do
    {:ok, DSPy.Prediction.new(%{history: history, termination_reason: :max_iters})}
  end

  defp run_loop(agent, inputs, history, remaining) do
    tool_descriptions =
      agent.tools |> Map.values() |> Enum.map(&%{name: &1.name, description: &1.description})

    call_inputs = Map.merge(inputs, %{history: history, tools: tool_descriptions})

    with {:ok, prediction} <- DSPy.Predict.Predict.call(agent.react, call_inputs) do
      case DSPy.Prediction.get(prediction, :tool_calls, []) do
        [] ->
          final = project_outputs(agent.signature, prediction)
          {:ok, %{final | metadata: Map.put(final.metadata, :history, history)}}

        calls ->
          {events, final} = execute_calls(agent.tools, List.wrap(calls))
          history = history ++ events

          if final do
            {:ok,
             DSPy.Prediction.new(
               Map.merge(final, %{history: history, termination_reason: :submit})
             )}
          else
            run_loop(agent, %{}, history, remaining - 1)
          end
      end
    end
  end

  defp execute_calls(tools, calls) do
    Enum.reduce(calls, {[], nil}, fn call, {events, final} ->
      name = normalize_name(Map.get(call, :name) || Map.get(call, "name"))

      args =
        Map.get(call, :arguments) || Map.get(call, :args) || Map.get(call, "arguments") || %{}

      tool = Map.get(tools, name)
      result = if tool, do: DSPy.Tool.call(tool, args), else: {:error, :unknown_tool}
      event = %{tool: name, arguments: args, result: result}
      final = if name == :submit and is_map(result), do: Map.new(result), else: final
      {events ++ [event], final}
    end)
  end

  defp project_outputs(signature, prediction) do
    fields = Map.take(DSPy.Prediction.to_map(prediction), DSPy.Signature.output_names(signature))
    DSPy.Prediction.new(fields, metadata: prediction.metadata)
  end

  defp coerce_tool(%DSPy.Tool{} = tool), do: tool
  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name), do: String.to_atom(to_string(name))
end

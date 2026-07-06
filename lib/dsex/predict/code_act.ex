defmodule DSEx.Predict.CodeAct do
  @moduledoc """
  CodeAct-style module backed by `DSEx.Sandbox` and explicit tool iterations.

  Each step asks the underlying ProgramOfThought planner for either a safe
  `program` expression to evaluate or a `tool` plus `arguments` to observe
  before the next step.
  """

  @behaviour DSEx.Module

  defstruct [:program_of_thought, tools: %{}, max_iters: 5]

  def new(signature, tools \\ [], opts \\ []) do
    %__MODULE__{
      program_of_thought: DSEx.Predict.ProgramOfThought.new(signature, opts),
      tools: tools |> Enum.map(&coerce_tool/1) |> Map.new(&{&1.name, &1}),
      max_iters: Keyword.get(opts, :max_iters, 5)
    }
  end

  @impl true
  def call(%__MODULE__{} = code_act, inputs) do
    run_loop(code_act, Map.new(inputs), [], 1)
  end

  defp run_loop(%__MODULE__{} = code_act, _inputs, trace, iteration)
       when iteration > code_act.max_iters do
    {:error, {:code_act_max_iters, code_act.max_iters, Enum.reverse(trace)}}
  end

  defp run_loop(%__MODULE__{} = code_act, inputs, trace, iteration) do
    with {:ok, prediction} <-
           DSEx.Predict.ProgramOfThought.predict_step(code_act.program_of_thought, inputs) do
      tool = DSEx.Prediction.get(prediction, :tool)
      program = DSEx.Prediction.get(prediction, :program)

      cond do
        present?(tool) ->
          arguments = DSEx.Prediction.get(prediction, :arguments, %{})
          {result, trace} = call_tool(code_act, tool, arguments, trace, iteration)

          next_inputs =
            inputs
            |> Map.put(:observation, result)
            |> Map.put(:code_act_history, Enum.reverse(trace))

          run_loop(code_act, next_inputs, trace, iteration + 1)

        is_binary(program) ->
          case DSEx.Sandbox.eval(program, inputs) do
            {:ok, value} ->
              prediction =
                prediction
                |> DSEx.Prediction.put(code_act.program_of_thought.output_field, value)
                |> put_trace(trace_event(trace, iteration, :program, program, {:ok, value}))

              {:ok, prediction}

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          {:error, :missing_program}
      end
    end
  end

  defp call_tool(%__MODULE__{} = code_act, tool_name, arguments, trace, iteration) do
    normalized = normalize_tool_name(code_act.tools, tool_name)
    tool = if normalized, do: Map.get(code_act.tools, normalized)
    result = if tool, do: DSEx.Tool.call(tool, arguments), else: {:error, :unknown_tool}

    {result,
     trace_event(trace, iteration, :tool, %{name: normalized, arguments: arguments}, result)}
  end

  defp trace_event(trace, iteration, action, input, output) do
    [
      DSEx.Redaction.redact(%{iteration: iteration, action: action, input: input, output: output})
      | trace
    ]
  end

  defp put_trace(%DSEx.Prediction{} = prediction, trace) do
    %{prediction | metadata: Map.put(prediction.metadata, :code_act_trace, Enum.reverse(trace))}
  end

  defp present?(value), do: value not in [nil, ""]

  defp coerce_tool(%DSEx.Tool{} = tool), do: tool

  defp normalize_tool_name(tools, name) do
    Enum.find_value(Map.keys(tools), fn known ->
      if to_string(known) == to_string(name), do: known
    end)
  end
end

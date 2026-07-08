defmodule DSEx.Predict.CodeAct do
  @moduledoc """
  CodeAct-style module backed by `DSEx.Sandbox` and explicit tool iterations.

  Each step asks the underlying ProgramOfThought planner for either a safe
  `program` expression to evaluate or a `tool` plus `arguments` to observe
  before the next step.

  Tool execution is policy-gated like ReAct and Agent:

      DSEx.code_act("question -> answer", [lookup],
        tool_policy: [:lookup],
        max_iters: 4
      )

  Unknown, denied, or crashing tools return structured errors with the redacted
  trace accumulated so far.
  """

  @behaviour DSEx.Module

  defstruct [:program_of_thought, tools: %{}, max_iters: 5, tool_policy: :allow]

  @option_schema [
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    output_field: [
      type: {:custom, DSEx.FieldSelector, :validate_name, []},
      default: :answer
    ],
    max_iters: [type: :non_neg_integer, default: 5],
    tool_policy: [
      type: {:custom, DSEx.ToolPolicy, :validate, []},
      default: :allow
    ]
  ]

  def new(signature, tools \\ [], opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.CodeAct.new/3")
    tools = DSEx.Tool.index_tools!(tools, "DSEx.Predict.CodeAct.new/3")
    pot_opts = Keyword.take(opts, [:lm, :adapter, :demos, :config, :metadata, :output_field])

    %__MODULE__{
      program_of_thought: DSEx.Predict.ProgramOfThought.new(signature, pot_opts),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy]
    }
  end

  @impl true
  def call(%__MODULE__{} = code_act, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs) do
      run_loop(code_act, inputs, [], 1)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_code_act_inputs,
        "expected a map or keyword/list of input pairs, got: #{inspect(inputs)}"}}

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_code_act_inputs, "expected inputs as {key, value} pairs"}}
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

          case result do
            {:error, reason} ->
              {:error, {:code_act_tool_error, reason, Enum.reverse(trace)}}

            _value ->
              next_inputs =
                inputs
                |> Map.put(:observation, result)
                |> Map.put(:code_act_history, Enum.reverse(trace))

              run_loop(code_act, next_inputs, trace, iteration + 1)
          end

        is_binary(program) ->
          case DSEx.Sandbox.eval(program, inputs) do
            {:ok, value} ->
              prediction =
                prediction
                |> DSEx.Prediction.put(code_act.program_of_thought.output_field, value)
                |> put_trace(trace_event(trace, iteration, :program, program, {:ok, value}))

              {:ok, prediction}

            {:error, reason} ->
              trace = trace_event(trace, iteration, :program, program, {:error, reason})
              {:error, {:code_act_sandbox_error, reason, Enum.reverse(trace)}}
          end

        true ->
          {:error, :missing_program}
      end
    end
  end

  defp call_tool(%__MODULE__{} = code_act, tool_name, arguments, trace, iteration) do
    normalized = normalize_tool_name(code_act.tools, tool_name)
    arguments = normalize_tool_args(arguments)
    result = execute_tool_call(code_act, normalized, tool_name, arguments)

    {result,
     trace_event(trace, iteration, :tool, %{name: normalized, arguments: arguments}, result)}
  end

  defp execute_tool_call(_code_act, nil, requested_name, _arguments),
    do: {:error, {:unknown_tool, requested_name}}

  defp execute_tool_call(code_act, name, _requested_name, arguments) do
    case authorize_tool(code_act.tool_policy, name, arguments) do
      :ok ->
        call_known_tool(Map.fetch!(code_act.tools, name), arguments)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_known_tool(tool, arguments) do
    DSEx.Tool.call(tool, arguments)
  rescue
    exception ->
      {:error, {:tool_error, tool.name, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:tool_error, tool.name, {kind, reason}}}
  end

  defp authorize_tool(policy, name, arguments),
    do: DSEx.ToolPolicy.authorize(policy, name, arguments)

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

  defp normalize_tool_name(tools, name) do
    Enum.find_value(Map.keys(tools), fn known ->
      if to_string(known) == to_string(name), do: known
    end)
  end

  defp normalize_tool_args(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> arguments
    end
  end

  defp normalize_tool_args(arguments), do: arguments
end

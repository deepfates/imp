defmodule Imp.Predict.CodeAct do
  @moduledoc """
  CodeAct-style module backed by `Imp.Sandbox` and explicit tool iterations.

  Each step asks the underlying ProgramOfThought planner for either a safe
  `program` expression to evaluate or a `tool` plus `arguments` to observe
  before the next step.

  Tool execution is policy-gated like ReAct and Agent:

      Imp.code_act("question -> answer", [lookup],
        tool_policy: [:lookup],
        max_iters: 4
      )

  Unknown, denied, or crashing tools return structured errors with the redacted
  trace accumulated so far.

  A call may override the constructor's iteration budget with `:max_iters` or
  `"max_iters"`. The control value is validated and is never exposed as a task
  input to the planner.
  """

  @behaviour Imp.Module

  alias Imp.Predict.ProgramOfThought
  alias Imp.Prediction

  @type t :: %__MODULE__{
          program_of_thought: ProgramOfThought.t(),
          tools: map(),
          max_iters: non_neg_integer(),
          tool_policy: term()
        }

  defstruct [:program_of_thought, tools: %{}, max_iters: 5, tool_policy: :allow]

  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    output_field: [
      type: {:custom, ProgramOfThought, :validate_output_field, []},
      default: nil
    ],
    max_iters: [type: :non_neg_integer, default: 5],
    tool_policy: [
      type: {:custom, Imp.ToolPolicy, :validate, []},
      default: :allow
    ]
  ]

  @doc "Builds a bounded CodeAct predictor with an allowlisted tool catalog."
  @spec new(term(), [struct()], keyword()) :: t()
  def new(signature, tools \\ [], opts \\ []) do
    opts =
      Imp.Predict.Predict.validate_options!(opts, @option_schema, "Imp.Predict.CodeAct.new/3")

    tools = Imp.Tool.index_tools!(tools, "Imp.Predict.CodeAct.new/3")
    pot_opts = Keyword.take(opts, [:lm, :adapter, :demos, :config, :metadata, :output_field])

    %__MODULE__{
      program_of_thought: ProgramOfThought.new(signature, pot_opts),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy]
    }
  end

  @spec call(t(), map() | [{term(), term()}]) :: {:ok, Prediction.t()} | {:error, term()}
  @impl true
  def call(%__MODULE__{} = code_act, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         {max_iters, inputs} <- pop_max_iters(inputs, code_act.max_iters),
         :ok <- validate_call_max_iters(max_iters) do
      run_loop(%{code_act | max_iters: max_iters}, inputs, [], 1)
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

  defp pop_max_iters(inputs, default) do
    max_iters =
      cond do
        Map.has_key?(inputs, :max_iters) -> Map.fetch!(inputs, :max_iters)
        Map.has_key?(inputs, "max_iters") -> Map.fetch!(inputs, "max_iters")
        true -> default
      end

    {max_iters, Map.drop(inputs, [:max_iters, "max_iters"])}
  end

  defp validate_call_max_iters(max_iters) when is_integer(max_iters) and max_iters >= 0, do: :ok

  defp validate_call_max_iters(max_iters),
    do: {:error, {:invalid_code_act_max_iters, max_iters}}

  defp run_loop(%__MODULE__{} = code_act, _inputs, trace, iteration)
       when iteration > code_act.max_iters do
    {:error, {:code_act_max_iters, code_act.max_iters, Enum.reverse(trace)}}
  end

  defp run_loop(%__MODULE__{} = code_act, inputs, trace, iteration) do
    case ProgramOfThought.code_act_step(code_act.program_of_thought, inputs, Enum.reverse(trace)) do
      {:ok, prediction} -> handle_step(code_act, inputs, trace, iteration, prediction)
      {:error, _reason} = error -> error
    end
  end

  defp handle_step(code_act, inputs, trace, iteration, prediction) do
    tool = Prediction.get(prediction, :tool)
    program = Prediction.get(prediction, :program)

    cond do
      present?(tool) ->
        handle_tool_step(code_act, inputs, trace, iteration, prediction, tool)

      present?(program) ->
        handle_program_step(code_act, inputs, trace, iteration, prediction, program)

      true ->
        retry_program(code_act, inputs, trace, iteration, program, :missing_program)
    end
  end

  defp handle_tool_step(code_act, inputs, trace, iteration, prediction, tool) do
    arguments = Prediction.get(prediction, :arguments, %{})
    {result, trace} = call_tool(code_act, tool, arguments, trace, iteration)

    case result do
      {:error, reason} ->
        {:error, {:code_act_tool_error, reason, Enum.reverse(trace)}}

      value ->
        inputs
        |> next_inputs(value, trace)
        |> then(&run_loop(code_act, &1, trace, iteration + 1))
    end
  end

  defp handle_program_step(code_act, inputs, trace, iteration, prediction, program) do
    case ProgramOfThought.parse_program(program) do
      {:ok, parsed} -> execute_program(code_act, inputs, trace, iteration, prediction, parsed)
      {:error, reason} -> retry_program(code_act, inputs, trace, iteration, program, reason)
    end
  end

  defp execute_program(code_act, inputs, trace, iteration, prediction, program) do
    case ProgramOfThought.eval_program(program, inputs) do
      {:ok, value} ->
        trace = trace_event(trace, iteration, :program, program, {:ok, value})
        handle_program_success(code_act, inputs, trace, iteration, prediction, program, value)

      {:error, reason} ->
        retry_program(code_act, inputs, trace, iteration, program, reason)
    end
  end

  defp handle_program_success(code_act, inputs, trace, iteration, prediction, program, value) do
    case finished_state(prediction) do
      true -> extract_final(code_act, inputs, trace, program, value)
      false -> continue_or_extract(code_act, inputs, trace, iteration, program, value)
      :direct -> project_direct(code_act, inputs, trace, prediction, program, value)
    end
  end

  defp continue_or_extract(code_act, inputs, trace, iteration, program, value) do
    if iteration < code_act.max_iters do
      inputs
      |> next_inputs(value, trace)
      |> then(&run_loop(code_act, &1, trace, iteration + 1))
    else
      extract_final(code_act, inputs, trace, program, value)
    end
  end

  defp project_direct(code_act, inputs, trace, prediction, program, value) do
    case ProgramOfThought.project_outputs(code_act.program_of_thought, prediction, value) do
      {:ok, projected} ->
        {:ok, put_trace(projected, trace)}

      {:error, reason} ->
        extract_on_projection_failure(code_act, inputs, trace, program, value, reason)
    end
  end

  defp extract_on_projection_failure(code_act, inputs, trace, program, value, projection_error) do
    case extract_final(code_act, inputs, trace, program, value) do
      {:ok, _prediction} = ok -> ok
      {:error, _reason} -> {:error, projection_error}
    end
  end

  defp retry_program(code_act, inputs, trace, iteration, program, reason) do
    trace = trace_event(trace, iteration, :program, program, {:error, reason})

    if iteration < code_act.max_iters do
      next_inputs =
        inputs
        |> next_inputs(
          "Failed to execute the generated program: #{ProgramOfThought.error_text(reason)}",
          trace
        )
        |> Map.put(:previous_program, program)
        |> Map.put(:error, ProgramOfThought.error_text(reason))

      run_loop(code_act, next_inputs, trace, iteration + 1)
    else
      {:error, {:code_act_sandbox_error, reason, Enum.reverse(trace)}}
    end
  end

  defp extract_final(code_act, inputs, trace, program, value) do
    trajectory = Enum.reverse(trace)

    with {:ok, prediction} <-
           ProgramOfThought.extract_outputs(
             code_act.program_of_thought,
             inputs,
             program,
             value,
             trajectory
           ) do
      {:ok, put_trace(prediction, trace)}
    end
  end

  defp finished_state(%Prediction{fields: fields}) do
    value =
      cond do
        Map.has_key?(fields, :finished) -> Map.fetch!(fields, :finished)
        Map.has_key?(fields, "finished") -> Map.fetch!(fields, "finished")
        true -> nil
      end

    if is_nil(value), do: :direct, else: value
  end

  defp next_inputs(inputs, observation, trace) do
    inputs
    |> Map.put(:observation, observation)
    |> Map.put(:code_act_history, ProgramOfThought.model_trajectory(Enum.reverse(trace)))
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
    Imp.Tool.call(tool, arguments)
  rescue
    exception ->
      {:error, {:tool_error, tool.name, exception}}
  catch
    kind, reason ->
      {:error, {:tool_error, tool.name, {kind, reason}}}
  end

  defp authorize_tool(policy, name, arguments),
    do: Imp.ToolPolicy.authorize(policy, name, arguments)

  defp trace_event(trace, iteration, action, input, output) do
    [
      Imp.Redaction.redact(%{iteration: iteration, action: action, input: input, output: output})
      | trace
    ]
  end

  defp put_trace(%Prediction{} = prediction, trace) do
    %{prediction | metadata: Map.put(prediction.metadata, :code_act_trace, Enum.reverse(trace))}
  end

  # "None"/"null"/"none" are placeholder spellings of "no tool this step":
  # the tool field is optional in the pinned signature and Python-trained
  # models emit Python's None as its string form. Treating them as present
  # would fail the step as {:unknown_tool, "None"} instead of falling
  # through to the program branch.
  defp present?(value), do: value not in [nil, "", "None", "null", "none"]

  defp normalize_tool_name(tools, name), do: Imp.Tool.resolve_name(tools, name)

  defp normalize_tool_args(arguments), do: Imp.Tool.normalize_arguments(arguments)
end

defmodule DSEx.Predict.ReAct do
  @moduledoc """
  Iterative provider-tool-call ReAct program with a reserved submit step.

  ReAct lets the LM choose from an explicit tool catalog, append observations to
  history, and eventually call the reserved `submit` tool. In provider-native
  mode `submit` carries the required outputs; in DSPy 3.2.1 mode it triggers a
  separate extraction pass.

  Use it when the model must gather information or perform bounded actions
  before answering. Keep the tool policy narrow in production:

      lookup = DSEx.tool(:lookup, "lookup facts", fn %{query: query} -> query end)

      program =
        DSEx.react("question -> answer", [lookup],
          tool_policy: [:lookup, :submit],
          max_iters: 4
        )

  The default `:provider_native` mode preserves the original DSEx contract:

  - unknown model-selected tools return `{:error, {:unknown_tool, name}}`;
  - denied tools return `{:error, {:tool_denied, name}}`;
  - tool crashes return `{:error, {:tool_error, name, reason}}`;
  - tool-policy crashes return `{:error, {:tool_policy_error, name, reason}}`;
  - missing final fields return `{:error, {:missing_output_fields, fields}}`.

  Set `mode: :dspy_3_2_1` for the upstream DSPy 3.2.1 completion contract.
  That mode records unknown-tool and tool-execution failures as observations so
  the model can recover, then runs a separate extraction pass after `submit`,
  action parse failure, empty tool calls, or iteration exhaustion. Tool-policy
  failures and malformed provider calls remain fail-fast in both modes.

  Like upstream ReAct, a call may override the constructor's iteration budget
  with an invocation-local `:max_iters` or `"max_iters"` input. The control
  value is validated and removed before task inputs are sent to the LM.

  Tool call history is redacted before it is attached to the final prediction.
  """

  @behaviour DSEx.Module

  @trajectory_call_attempts 3

  defstruct [
    :signature,
    :react,
    tools: %{},
    max_iters: 20,
    tool_policy: :allow,
    mode: :provider_native
  ]

  @option_schema [
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    max_iters: [type: :non_neg_integer, default: 20],
    mode: [type: {:in, [:provider_native, :dspy_3_2_1]}, default: :provider_native],
    tool_policy: [
      type: {:custom, DSEx.ToolPolicy, :validate, []},
      default: :allow
    ]
  ]

  def new(signature, tools, opts \\ []) do
    signature = DSEx.Signature.ensure(signature)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.ReAct.new/3")
    tool_map = DSEx.Tool.index_tools!(tools, "DSEx.Predict.ReAct.new/3")
    mode = opts[:mode]
    submit = submit_tool(mode)
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
      instructions: react_instructions(signature.instructions, mode)
    }

    react_opts =
      Keyword.update(opts, :config, provider_tool_config(tools, signature, mode), fn config ->
        Keyword.merge(config, provider_tool_config(tools, signature, mode))
      end)

    %__MODULE__{
      signature: signature,
      react: DSEx.Predict.Predict.new(react_signature, react_opts),
      tools: tools,
      max_iters: non_negative_integer(opts[:max_iters]),
      tool_policy: opts[:tool_policy],
      mode: mode
    }
  end

  @doc false
  def with_tools(%__MODULE__{} = agent, tools) when is_map(tools) do
    tools = validate_updated_tools!(agent.tools, tools)

    react = %{
      agent.react
      | config:
          Keyword.merge(
            agent.react.config,
            provider_tool_config(tools, agent.signature, agent.mode)
          )
    }

    %{agent | tools: tools, react: react}
  end

  def with_tools(%__MODULE__{}, tools) do
    raise ArgumentError, "ReAct tools must be a map, got: #{inspect(tools)}"
  end

  defp submit_tool(:provider_native),
    do: DSEx.Tool.new(:submit, "Submit final outputs", fn args -> args end)

  defp submit_tool(:dspy_3_2_1),
    do:
      DSEx.Tool.new(
        :submit,
        "Mark the task complete so the collected information can be extracted",
        fn _args -> "Completed." end
      )

  defp react_instructions(instructions, :provider_native) do
    """
    #{instructions}

    You are running an iterative tool-use loop.
    Use the supplied provider tools when a tool is needed.
    Read the history field before choosing the next action.
    If history already contains the information needed for the final answer,
    call the reserved submit tool with the required output fields.
    Do not repeat a tool call when its result is already present in history.
    """
  end

  defp react_instructions(instructions, :dspy_3_2_1) do
    """
    #{instructions}

    You are running an iterative tool-use loop.
    Use the supplied provider tools to collect the information needed for the final outputs.
    Read the history field before choosing the next action.
    Tool execution failures are observations that may be corrected on a later turn.
    When all necessary information is present in history, call the reserved submit tool.
    Do not include final outputs in submit arguments; a separate step extracts them from history.
    Do not repeat a tool call when its result is already present in history.
    """
  end

  @impl true
  def call(%__MODULE__{} = agent, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         {max_iters, inputs} <- pop_max_iters(inputs, agent.max_iters),
         :ok <- validate_call_max_iters(max_iters) do
      run_loop(agent, inputs, [], max_iters)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_react_inputs,
        "expected a map or keyword/list of input pairs, got: #{inspect(inputs)}"}}

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_react_inputs, "expected inputs as {key, value} pairs"}}
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
    do: {:error, {:invalid_react_max_iters, max_iters}}

  defp run_loop(%{mode: :dspy_3_2_1} = agent, inputs, history, 0) do
    extract_final(agent, inputs, history, :max_iters)
  end

  defp run_loop(_agent, _inputs, history, 0) do
    {:error, {:react_max_iters, history}}
  end

  defp run_loop(agent, inputs, history, remaining) do
    tool_descriptions =
      agent.tools |> Map.values() |> Enum.map(&%{name: &1.name, description: &1.description})

    case call_action(agent, inputs, history, tool_descriptions) do
      {:ok, prediction, effective_history} ->
        handle_action_prediction(agent, inputs, effective_history, remaining, prediction)

      {:error, reason, effective_history} when agent.mode == :dspy_3_2_1 ->
        if action_parse_failure?(reason) do
          extract_final(agent, inputs, effective_history, :parse_failure)
        else
          {:error, reason}
        end

      {:error, reason, _effective_history} ->
        {:error, reason}
    end
  end

  defp call_action(agent, inputs, history, tool_descriptions) do
    call = fn effective_history ->
      call_inputs =
        Map.merge(inputs, %{history: effective_history, tools: tool_descriptions})

      DSEx.Predict.Predict.call(agent.react, call_inputs)
    end

    call_with_trajectory_truncation(agent.mode, call, history)
  end

  defp handle_action_prediction(agent, inputs, history, remaining, prediction) do
    case DSEx.Prediction.get(prediction, :tool_calls, []) do
      [] when agent.mode == :dspy_3_2_1 ->
        extract_final(agent, inputs, history, :empty_tool_calls)

      [] ->
        final = project_outputs(agent.signature, prediction)
        validate_final(agent.signature, final, history, :direct)

      calls ->
        {events, final, failure, submitted?} = execute_calls(agent, List.wrap(calls))
        events = attach_thought(agent.mode, prediction, events)
        history = history ++ events

        cond do
          failure ->
            failure

          submitted? and agent.mode == :dspy_3_2_1 ->
            extract_final(agent, inputs, history, :submit)

          final ->
            prediction = DSEx.Prediction.new(final)
            validate_final(agent.signature, prediction, history, :submit)

          true ->
            run_loop(agent, inputs, history, remaining - 1)
        end
    end
  end

  defp execute_calls(agent, calls) do
    Enum.reduce_while(calls, {[], nil, nil, false}, fn call,
                                                       {events, final, failure, _submitted?} ->
      {name, args, outcome} = prepare_tool_call(agent, call)
      {result, call_failure} = interpret_outcome(agent.mode, name, outcome)

      event = DSEx.Redaction.redact(%{tool: name, arguments: args, result: result})
      submitted? = name == :submit

      final =
        if agent.mode == :provider_native and submitted? and is_map(result),
          do: Map.new(result),
          else: final

      state = {events ++ [event], final, failure || call_failure, submitted?}
      halt_on_submit? = submitted? and agent.mode == :dspy_3_2_1

      if call_failure || final || halt_on_submit?, do: {:halt, state}, else: {:cont, state}
    end)
  end

  defp attach_thought(:dspy_3_2_1, prediction, [event | events]) do
    case DSEx.Prediction.get(prediction, :next_thought) do
      nil -> [event | events]
      thought -> [DSEx.Redaction.redact(Map.put(event, :thought, thought)) | events]
    end
  end

  defp attach_thought(_mode, _prediction, events), do: events

  defp prepare_tool_call(agent, call) when is_map(call) do
    requested_name = tool_call_name(call)
    name = normalize_tool_name(agent.tools, requested_name)

    args = call |> tool_call_arguments() |> DSEx.Tool.normalize_arguments()

    {name, args, execute_tool_call(agent, name, requested_name, args)}
  end

  defp prepare_tool_call(_agent, call),
    do: {nil, %{}, {:error, {:malformed_tool_call, call}}}

  defp tool_call_name(call) do
    function = Map.get(call, :function) || Map.get(call, "function") || %{}

    Map.get(call, :name) || Map.get(call, "name") || Map.get(function, :name) ||
      Map.get(function, "name")
  end

  defp tool_call_arguments(call) do
    function = Map.get(call, :function) || Map.get(call, "function") || %{}

    Map.get(call, :arguments) || Map.get(call, :args) || Map.get(call, "arguments") ||
      Map.get(call, "args") || Map.get(function, :arguments) || Map.get(function, :args) ||
      Map.get(function, "arguments") || Map.get(function, "args") || %{}
  end

  defp execute_tool_call(_agent, nil, requested_name, _args),
    do: {:error, {:unknown_tool, requested_name}}

  defp execute_tool_call(agent, name, _requested_name, args),
    do: execute_tool_call(agent, name, args)

  defp execute_tool_call(agent, name, args) do
    case authorize_tool(agent.tool_policy, name, args) do
      :ok ->
        call_tool(Map.fetch!(agent.tools, name), args)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_tool(tool, args) do
    {:ok, DSEx.Tool.call(tool, args)}
  rescue
    exception ->
      {:error, {:tool_error, tool.name, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:tool_error, tool.name, {kind, reason}}}
  end

  defp authorize_tool(policy, name, args), do: DSEx.ToolPolicy.authorize(policy, name, args)

  defp interpret_outcome(:provider_native, _name, {:ok, {:error, reason}}),
    do: {{:error, reason}, {:error, reason}}

  defp interpret_outcome(:provider_native, _name, {:ok, result}), do: {result, nil}

  defp interpret_outcome(:provider_native, _name, {:error, reason}),
    do: {{:error, reason}, {:error, reason}}

  defp interpret_outcome(:dspy_3_2_1, name, {:ok, {:error, reason}}),
    do: {"Execution error in #{display_tool_name(name)}: #{format_tool_error(reason)}", nil}

  defp interpret_outcome(:dspy_3_2_1, _name, {:ok, result}), do: {result, nil}

  defp interpret_outcome(:dspy_3_2_1, name, {:error, reason}) do
    if observable_tool_failure?(reason) do
      {tool_failure_observation(name, reason), nil}
    else
      {{:error, reason}, {:error, reason}}
    end
  end

  defp observable_tool_failure?({:unknown_tool, _name}), do: true
  defp observable_tool_failure?({:tool_error, _name, _reason}), do: true
  defp observable_tool_failure?(_reason), do: false

  defp tool_failure_observation(name, {:unknown_tool, requested_name}),
    do: "Execution error in #{display_tool_name(name || requested_name)}: unknown tool"

  defp tool_failure_observation(name, {:tool_error, _tool, reason}),
    do: "Execution error in #{display_tool_name(name)}: #{format_tool_error(reason)}"

  defp display_tool_name(nil), do: "unknown"
  defp display_tool_name(name), do: to_string(name)

  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(reason), do: inspect(reason)

  defp action_parse_failure?(%{reason: {:error, %DSEx.AdapterParseError{}}}), do: true
  defp action_parse_failure?(%{reason: {:error, {:missing_output_fields, _fields}}}), do: true
  defp action_parse_failure?(%DSEx.AdapterParseError{}), do: true
  defp action_parse_failure?({:missing_output_fields, _fields}), do: true
  defp action_parse_failure?({:react_context_window_exceeded_after_truncation, _reason}), do: true
  defp action_parse_failure?({:react_trajectory_not_truncatable, _reason}), do: true
  defp action_parse_failure?(_reason), do: false

  defp extract_final(agent, inputs, history, reason) do
    extractor = extraction_program(agent)

    call = fn effective_history ->
      DSEx.Predict.ChainOfThought.call(extractor, Map.put(inputs, :history, effective_history))
    end

    case call_with_trajectory_truncation(agent.mode, call, history) do
      {:ok, prediction, effective_history} ->
        final = project_extraction(agent.signature, prediction)
        validate_final(agent.signature, final, effective_history, reason)

      {:error, error, _effective_history} ->
        {:error, error}
    end
  end

  defp call_with_trajectory_truncation(:dspy_3_2_1, call, history),
    do: retry_trajectory_call(call, history, @trajectory_call_attempts)

  defp call_with_trajectory_truncation(_mode, call, history) do
    case call.(history) do
      {:ok, prediction} -> {:ok, prediction, history}
      {:error, reason} -> {:error, reason, history}
    end
  end

  defp retry_trajectory_call(call, history, attempts_left) do
    case call.(history) do
      {:ok, prediction} ->
        {:ok, prediction, history}

      {:error, reason} when attempts_left > 1 ->
        if context_window_exceeded?(reason) do
          case history do
            [_oldest | rest] ->
              retry_trajectory_call(call, rest, attempts_left - 1)

            [] ->
              {:error, {:react_trajectory_not_truncatable, reason}, history}
          end
        else
          {:error, reason, history}
        end

      {:error, reason} ->
        if context_window_exceeded?(reason) do
          case history do
            [_oldest | rest] ->
              {:error, {:react_context_window_exceeded_after_truncation, reason}, rest}

            [] ->
              {:error, {:react_trajectory_not_truncatable, reason}, history}
          end
        else
          {:error, reason, history}
        end
    end
  end

  defp context_window_exceeded?(%DSEx.ContextWindowExceededError{}), do: true
  defp context_window_exceeded?({:error, reason}), do: context_window_exceeded?(reason)
  defp context_window_exceeded?({:lm_failed, _lm, reason}), do: context_window_exceeded?(reason)
  defp context_window_exceeded?(%{reason: reason}), do: context_window_exceeded?(reason)
  defp context_window_exceeded?(_reason), do: false

  defp project_extraction(signature, prediction) do
    fields =
      prediction
      |> DSEx.Prediction.to_map()
      |> Map.take([:reasoning | DSEx.Signature.output_names(signature)])

    DSEx.Prediction.new(fields, metadata: prediction.metadata)
  end

  defp extraction_program(agent) do
    signature = %DSEx.Signature{
      inputs: agent.signature.inputs ++ [DSEx.Signature.Field.new(:history, :input)],
      outputs: agent.signature.outputs,
      instructions: agent.signature.instructions
    }

    predict = agent.react

    opts = [
      demos: [],
      config: Keyword.drop(predict.config, [:tools, :tool_choice]),
      metadata: predict.metadata
    ]

    opts = if predict.dynamic_lm?, do: opts, else: Keyword.put(opts, :lm, predict.lm)

    opts =
      if predict.dynamic_adapter?, do: opts, else: Keyword.put(opts, :adapter, predict.adapter)

    DSEx.Predict.ChainOfThought.new(signature, opts)
  end

  defp project_outputs(signature, prediction) do
    fields =
      Map.take(
        DSEx.Prediction.to_map(prediction),
        DSEx.Signature.output_names(signature)
      )

    DSEx.Prediction.new(fields, metadata: prediction.metadata)
  end

  defp validate_final(signature, prediction, history, reason) do
    fields = DSEx.Prediction.to_map(prediction)

    case DSEx.Schema.validate_fields(signature.outputs, fields) do
      :ok ->
        prediction =
          prediction
          |> DSEx.Prediction.put(:history, history)
          |> DSEx.Prediction.put(:termination_reason, reason)

        {:ok, prediction}

      {:error, errors} ->
        missing =
          errors
          |> Enum.filter(&(&1.rule == :required))
          |> Enum.map(& &1.field)

        if missing == [] do
          {:error,
           %DSEx.AdapterParseError{message: DSEx.Schema.retry_feedback(errors), reason: fields}}
        else
          {:error, {:missing_output_fields, missing}}
        end
    end
  end

  defp provider_tool_config(tools_map, signature, mode) do
    tools =
      tools_map
      |> Map.values()
      |> Enum.map(fn tool ->
        %{
          type: "function",
          function: %{
            name: to_string(tool.name),
            description: tool.description,
            parameters: tool_parameters(tool, signature, mode)
          }
        }
      end)

    [tools: tools, tool_choice: "auto"]
  end

  defp tool_parameters(%DSEx.Tool{name: :submit}, _signature, :dspy_3_2_1),
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  defp tool_parameters(%DSEx.Tool{name: :submit}, signature, :provider_native),
    do: DSEx.Signature.json_schema(signature)

  defp tool_parameters(%DSEx.Tool{schema: schema}, _signature, _mode) when map_size(schema) > 0,
    do: schema

  defp tool_parameters(_tool, _signature, _mode),
    do: %{"type" => "object", "properties" => %{}}

  defp normalize_tool_name(tools, name), do: DSEx.Tool.resolve_name(tools, name)

  defp validate_updated_tools!(original, updated) do
    unless MapSet.new(Map.keys(original)) == MapSet.new(Map.keys(updated)) do
      raise ArgumentError, "ReAct tool updates cannot add or remove tools"
    end

    Enum.each(original, fn {name, tool} ->
      case Map.fetch(updated, name) do
        {:ok, %DSEx.Tool{} = replacement} ->
          ensure_preserved_tool!(tool, replacement)

        {:ok, replacement} ->
          raise ArgumentError, "ReAct tool update is not a DSEx.Tool: #{inspect(replacement)}"

        :error ->
          raise ArgumentError, "ReAct tool update removed #{inspect(name)}"
      end
    end)

    updated
  end

  defp ensure_preserved_tool!(%DSEx.Tool{name: :submit} = original, replacement) do
    unless replacement.name == original.name and replacement.description == original.description and
             replacement.schema == original.schema and replacement.run === original.run do
      raise ArgumentError, "ReAct submit is reserved and cannot be changed"
    end
  end

  defp ensure_preserved_tool!(original, replacement) do
    unless replacement.name == original.name and replacement.run === original.run do
      raise ArgumentError, "ReAct tool updates must preserve tool names and runners"
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
end

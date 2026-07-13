defmodule DSEx.Predict.ReActV2 do
  @moduledoc """
  Native-tool-aware ReAct loop with structured history and forced submission.

  ReActV2 preserves parallel tool call IDs and results in `DSEx.History`, keeps
  unknown and failed tool calls as observations, and forces one final `submit`
  call when the normal loop ends without final outputs.
  """

  @behaviour DSEx.Module

  alias DSEx.Adapters.Types.{ToolCall, ToolCalls, ToolResult}

  defstruct [:signature, :react, tools: %{}, max_iters: 20, tool_policy: :allow]

  @option_schema [
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    max_iters: [type: :non_neg_integer, default: 20],
    tool_policy: [type: {:custom, DSEx.ToolPolicy, :validate, []}, default: :allow]
  ]

  def new(signature, tools, opts \\ []) do
    signature = DSEx.Signature.ensure(signature)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.ReActV2.new/3")
    tools = DSEx.Tool.index_tools!(tools, "DSEx.Predict.ReActV2.new/3")

    if DSEx.Tool.resolve_name(tools, :submit) do
      raise ArgumentError, "submit is reserved by DSEx.Predict.ReActV2"
    end

    submit = DSEx.Tool.new(:submit, "Submit the final outputs for the task.", & &1)
    tools = Map.put(tools, :submit, submit)

    react_signature =
      %DSEx.Signature{
        inputs:
          Enum.map(signature.inputs, &DSEx.Signature.Field.optional/1) ++
            [
              DSEx.Signature.Field.new(%{name: :history, type: :history}, :input),
              DSEx.Signature.Field.new(%{name: :tools, type: :array}, :input)
            ],
        outputs: [
          DSEx.Signature.Field.new(%{name: :next_thought, metadata: %{optional: true}}, :output),
          DSEx.Signature.Field.new(%{name: :tool_calls, type: :array}, :output)
        ],
        instructions: instructions(signature, tools)
      }

    config = Keyword.merge(opts[:config], provider_tool_config(tools, signature))

    %__MODULE__{
      signature: signature,
      react:
        DSEx.Predict.Predict.new(
          react_signature,
          Keyword.merge(opts, config: config)
        ),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy]
    }
  end

  @impl true
  def call(%__MODULE__{} = react, inputs) when is_map(inputs) or is_list(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         {:ok, history} <- coerce_history(Map.get(inputs, :history, Map.get(inputs, "history"))) do
      pending =
        react.signature
        |> DSEx.Signature.input_names()
        |> Map.new(fn name -> {name, fetch_input(inputs, name)} end)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      run(react, history, pending, 0)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_react_v2_inputs, "expected a map or field pairs, got: #{inspect(inputs)}"}}

  defp run(react, history, pending, turn) when turn >= react.max_iters,
    do: forced_submit(react, history, pending, :max_iters, turn, nil)

  defp run(react, history, pending, turn) do
    case predict(react.react, react, history, pending) do
      {:ok, prediction} ->
        calls = prediction |> DSEx.get(:tool_calls, []) |> normalize_calls(turn)

        if calls.tool_calls == [] do
          forced_submit(react, history, pending, :empty_tool_calls, turn, nil)
        else
          {results, final} = execute_calls(react, calls)
          event = history_event(pending, prediction, calls, results, final)
          history = DSEx.History.append(history, event)

          if final,
            do: final_prediction(final, history, :submit),
            else: run(react, history, %{}, turn + 1)
        end

      {:error, reason} ->
        forced_submit(react, history, pending, termination_reason(reason), turn, reason)
    end
  end

  defp forced_submit(react, history, pending, reason, turn, initial_error) do
    forced = %{
      react.react
      | config:
          Keyword.merge(react.react.config,
            tool_choice: %{type: "function", function: %{name: "submit"}}
          )
    }

    with {:ok, prediction} <- predict(forced, react, history, pending) do
      calls = prediction |> DSEx.get(:tool_calls, []) |> normalize_calls(turn)
      submit_calls = %ToolCalls{tool_calls: Enum.filter(calls.tool_calls, &submit?/1)}

      if submit_calls.tool_calls == [] do
        incomplete_prediction(history, reason, initial_error)
      else
        {results, final} = execute_calls(react, submit_calls)
        event = history_event(pending, prediction, submit_calls, results, final)
        history = DSEx.History.append(history, event)

        if final,
          do: final_prediction(final, history, :forced_submit),
          else: incomplete_prediction(history, reason, initial_error)
      end
    else
      {:error, forced_error} ->
        incomplete_prediction(history, reason, %{
          initial: initial_error,
          forced_submit: forced_error
        })
    end
  end

  defp predict(program, react, history, pending) do
    tools = Enum.map(Map.values(react.tools), &tool_description(&1, react.signature))
    DSEx.Predict.Predict.call(program, Map.merge(pending, %{history: history, tools: tools}))
  end

  defp normalize_calls(%ToolCalls{} = calls, turn), do: ensure_ids(calls, turn)

  defp normalize_calls(calls, turn),
    do: calls |> List.wrap() |> ToolCalls.new() |> ensure_ids(turn)

  defp ensure_ids(%ToolCalls{tool_calls: calls}, turn) do
    calls =
      calls
      |> Enum.with_index()
      |> Enum.map(fn
        {%ToolCall{id: nil} = call, index} -> %{call | id: "call_#{turn}_#{index}"}
        {%ToolCall{} = call, _index} -> call
      end)

    %ToolCalls{tool_calls: calls}
  end

  defp execute_calls(react, %ToolCalls{tool_calls: calls}) do
    Enum.reduce(calls, {[], nil}, fn call, {results, final} ->
      {result, error?} = execute_call(react, call)
      result = %ToolResult{name: call.name, result: result, id: call.id}

      final =
        if submit?(call) and not error? and is_map(result.result), do: result.result, else: final

      {results ++ [Map.put(Map.from_struct(result), :error, error?)], final}
    end)
  end

  defp execute_call(react, %ToolCall{name: requested, arguments: arguments}) do
    name = DSEx.Tool.resolve_name(react.tools, requested)
    arguments = DSEx.Tool.normalize_arguments(arguments)

    cond do
      is_nil(name) ->
        {{:error, {:unknown_tool, requested}}, true}

      true ->
        case DSEx.ToolPolicy.authorize(react.tool_policy, name, arguments) do
          :ok when name == :submit -> validate_submit(react.signature, arguments)
          :ok -> safe_tool_call(Map.fetch!(react.tools, name), arguments)
          {:error, reason} -> {{:error, reason}, true}
        end
    end
  end

  defp safe_tool_call(tool, arguments) do
    {DSEx.Tool.call(tool, arguments), false}
  rescue
    error -> {{:error, {:tool_error, tool.name, Exception.message(error)}}, true}
  catch
    kind, reason -> {{:error, {:tool_error, tool.name, {kind, reason}}}, true}
  end

  defp validate_submit(signature, arguments) when is_map(arguments) do
    names = DSEx.Signature.output_names(signature)

    {outputs, missing} =
      Enum.reduce(names, {%{}, []}, fn name, {outputs, missing} ->
        value = Map.get(arguments, name, Map.get(arguments, to_string(name), :__missing__))

        if value == :__missing__,
          do: {outputs, missing ++ [name]},
          else: {Map.put(outputs, name, value), missing}
      end)

    if missing == [],
      do: {outputs, false},
      else: {{:error, {:missing_output_fields, missing}}, true}
  end

  defp validate_submit(_signature, arguments),
    do: {{:error, {:invalid_submit_arguments, arguments}}, true}

  defp history_event(pending, prediction, calls, results, final) do
    pending
    |> maybe_put(:next_thought, DSEx.get(prediction, :next_thought))
    |> Map.put(:tool_calls, calls)
    |> Map.put(:tool_call_results, results)
    |> then(fn event -> if final, do: Map.merge(event, final), else: event end)
    |> DSEx.Redaction.redact()
  end

  defp final_prediction(final, history, reason) do
    {:ok,
     final
     |> Map.put(:history, history)
     |> Map.put(:termination_reason, reason)
     |> DSEx.Prediction.new()}
  end

  defp incomplete_prediction(history, reason, error) do
    fields = %{history: history, termination_reason: reason}

    fields =
      if error,
        do: Map.put(fields, :termination_error, DSEx.Redaction.redact(error)),
        else: fields

    {:ok, DSEx.Prediction.new(fields)}
  end

  defp submit?(%ToolCall{name: name}), do: to_string(name) == "submit"

  defp termination_reason(%DSEx.ContextWindowExceededError{}), do: :context_window_exceeded
  defp termination_reason(%DSEx.AdapterParseError{}), do: :parse_error
  defp termination_reason(_reason), do: :prediction_error

  defp coerce_history(nil), do: {:ok, DSEx.History.new()}
  defp coerce_history(%DSEx.History{} = history), do: {:ok, history}

  defp coerce_history(%{"messages" => messages}) when is_list(messages),
    do: {:ok, DSEx.History.new(messages)}

  defp coerce_history(%{messages: messages}) when is_list(messages),
    do: {:ok, DSEx.History.new(messages)}

  defp coerce_history(messages) when is_list(messages), do: {:ok, DSEx.History.new(messages)}
  defp coerce_history(history), do: {:error, {:invalid_react_v2_history, history}}

  defp normalize_inputs(inputs), do: {:ok, Map.new(inputs)}

  defp fetch_input(inputs, name), do: Map.get(inputs, name, Map.get(inputs, to_string(name)))
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp instructions(signature, tools) do
    inputs = signature |> DSEx.Signature.input_names() |> Enum.map_join(", ", &"`#{&1}`")
    outputs = signature |> DSEx.Signature.output_names() |> Enum.map_join(", ", &"`#{&1}`")
    names = tools |> Map.keys() |> Enum.map_join(", ", &"`#{&1}`")

    """
    #{signature.instructions}
    You are an Agent. Use the supplied tools to produce #{outputs} from #{inputs}.
    Call tools when more information is needed.
    When the final answer is ready, call `submit` with #{outputs}.
    The available tools are: #{names}.
    """
    |> String.trim()
  end

  defp provider_tool_config(tools, signature) do
    [
      tools: Enum.map(Map.values(tools), &tool_description(&1, signature)),
      tool_choice: "auto",
      provider_options: [openai_parallel_tool_calls: true]
    ]
  end

  defp tool_description(%DSEx.Tool{name: :submit} = tool, signature),
    do: provider_tool(tool, DSEx.Signature.json_schema(signature))

  defp tool_description(%DSEx.Tool{schema: schema} = tool, _signature) when map_size(schema) > 0,
    do: provider_tool(tool, schema)

  defp tool_description(tool, _signature),
    do: provider_tool(tool, %{"type" => "object", "properties" => %{}})

  defp provider_tool(tool, parameters) do
    %{
      type: "function",
      function: %{
        name: to_string(tool.name),
        description: tool.description,
        parameters: parameters
      }
    }
  end
end

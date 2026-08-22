defmodule Imp.Predict.ReActV2 do
  @moduledoc """
  Native-tool-aware ReAct loop with structured history and forced submission.

  ReActV2 preserves parallel tool call IDs and results in `Imp.History`, keeps
  unknown and failed tool calls as observations, and forces one final `submit`
  call when the normal loop ends without final outputs.
  """

  @behaviour Imp.Module

  alias Imp.Adapter.Types.{ToolCall, ToolCalls, ToolResult}

  defstruct [:signature, :react, tools: %{}, max_iters: 20, tool_policy: :allow]

  @type t :: %__MODULE__{}

  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    max_iters: [type: :non_neg_integer, default: 20],
    tool_policy: [type: {:custom, Imp.ToolPolicy, :validate, []}, default: :allow]
  ]

  def new(signature, tools, opts \\ []) do
    signature = Imp.Signature.ensure(signature)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.ReActV2.new/3")
    tools = Imp.Tool.index_tools!(tools, "Imp.Predict.ReActV2.new/3")

    if Imp.Tool.resolve_name(tools, :submit) do
      raise ArgumentError, "submit is reserved by Imp.Predict.ReActV2"
    end

    submit = Imp.Tool.new(:submit, "Submit the final outputs for the task.", & &1)
    tools = Map.put(tools, :submit, submit)

    react_signature =
      %Imp.Signature{
        inputs:
          Enum.map(signature.inputs, &Imp.Signature.Field.optional/1) ++
            [
              Imp.Signature.Field.new(%{name: :history, type: :history}, :input),
              Imp.Signature.Field.new(%{name: :tools, type: :array}, :input)
            ],
        outputs: [
          Imp.Signature.Field.new(%{name: :next_thought, metadata: %{optional: true}}, :output),
          Imp.Signature.Field.new(%{name: :tool_calls, type: :array}, :output)
        ],
        instructions: instructions(signature, tools)
      }

    config = Keyword.merge(opts[:config], provider_tool_config(tools, signature))

    %__MODULE__{
      signature: signature,
      react:
        Imp.Predict.Predict.new(
          react_signature,
          Keyword.merge(opts, config: config)
        ),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy]
    }
  end

  @doc false
  def with_tools(%__MODULE__{} = agent, tools) when is_map(tools) do
    tools = validate_updated_tools!(agent.tools, tools)

    react = %{
      agent.react
      | config: Keyword.merge(agent.react.config, provider_tool_config(tools, agent.signature))
    }

    %{agent | tools: tools, react: react}
  end

  def with_tools(%__MODULE__{}, tools) do
    raise ArgumentError, "ReActV2 tools must be a map, got: #{inspect(tools)}"
  end

  @impl true
  def call(%__MODULE__{} = react, inputs) when is_map(inputs) or is_list(inputs) do
    do_call(react, inputs, Imp.Execution.unrestricted())
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_react_v2_inputs, "expected a map or field pairs, got: #{inspect(inputs)}"}}

  @impl true
  def execute(%__MODULE__{} = react, inputs, %Imp.Execution{} = execution)
      when is_map(inputs) or is_list(inputs) do
    do_call(react, inputs, execution)
  end

  def execute(%__MODULE__{}, inputs, %Imp.Execution{}),
    do:
      {:error,
       {:invalid_react_v2_inputs, "expected a map or field pairs, got: #{inspect(inputs)}"}}

  defp do_call(%__MODULE__{} = react, inputs, execution) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         {max_iters, inputs} <- pop_max_iters(inputs, react.max_iters),
         :ok <- validate_call_max_iters(max_iters),
         {:ok, history} <- coerce_history(Map.get(inputs, :history, Map.get(inputs, "history"))) do
      # ReActV2 filters inputs down to signature names before any Predict call,
      # so extra keys would vanish silently here; warn at this boundary the same
      # way Imp.Predict.Predict does (:history is a documented call-time key).
      :ok = Imp.Predict.Predict.warn_extra_inputs(react.signature, inputs, [:history])

      pending =
        react.signature
        |> Imp.Signature.input_names()
        |> Map.new(fn name -> {name, fetch_input(inputs, name)} end)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      run(react, history, pending, 0, max_iters, execution)
    end
  end

  defp run(react, history, pending, turn, max_iters, execution) when turn >= max_iters,
    do: forced_submit(react, history, pending, :max_iters, turn, nil, execution)

  defp run(react, history, pending, turn, max_iters, execution) do
    case predict(react.react, react, history, pending) do
      {:ok, prediction} ->
        calls = prediction |> Imp.get(:tool_calls, []) |> normalize_calls(turn)
        emit_reasoning(prediction, turn)

        if calls.tool_calls == [] do
          forced_submit(react, history, pending, :empty_tool_calls, turn, nil, execution)
        else
          case execute_calls(react, calls, execution) do
            {:cancel, reason} ->
              {:error, {:execution_cancelled, reason}}

            {results, final} ->
              event = history_event(pending, prediction, calls, results, final)
              history = Imp.History.append(history, event)

              if final,
                do: final_prediction(final, history, :submit),
                else: run(react, history, %{}, turn + 1, max_iters, execution)
          end
        end

      {:error, reason} ->
        forced_submit(
          react,
          history,
          pending,
          termination_reason(reason),
          turn,
          reason,
          execution
        )
    end
  end

  defp forced_submit(react, history, pending, reason, turn, initial_error, execution) do
    forced = %{
      react.react
      | config:
          Keyword.merge(react.react.config,
            # ReqLLM's provider-neutral form. OpenAI-compatible providers translate
            # this to their nested `function` shape while Anthropic keeps the
            # canonical `tool`/`name` pair.
            tool_choice: %{type: "tool", name: "submit"},
            reasoning_effort: nil
          )
    }

    with {:ok, prediction} <- predict(forced, react, history, pending) do
      calls = prediction |> Imp.get(:tool_calls, []) |> normalize_calls(turn)
      emit_reasoning(prediction, turn, forced?: true)
      submit_calls = %ToolCalls{tool_calls: Enum.filter(calls.tool_calls, &submit?/1)}

      if submit_calls.tool_calls == [] do
        incomplete_prediction(history, reason, initial_error)
      else
        case execute_calls(react, submit_calls, execution) do
          {:cancel, cancel_reason} ->
            {:error, {:execution_cancelled, cancel_reason}}

          {results, final} ->
            event = history_event(pending, prediction, submit_calls, results, final)
            history = Imp.History.append(history, event)

            if final,
              do: final_prediction(final, history, :forced_submit),
              else: incomplete_prediction(history, reason, initial_error)
        end
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
    Imp.Predict.Predict.call(program, Map.merge(pending, %{history: history, tools: tools}))
  end

  defp normalize_calls(%ToolCalls{} = calls, turn), do: ensure_ids(calls, turn)

  # `ToolCalls.format/1` and provider adapters may retain the collection wrapper
  # around an otherwise normalized list. Accept either key vocabulary rather
  # than treating that wrapper as one tool call.
  defp normalize_calls(%{tool_calls: calls}, turn), do: normalize_calls(calls, turn)
  defp normalize_calls(%{"tool_calls" => calls}, turn), do: normalize_calls(calls, turn)

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

  defp execute_calls(react, %ToolCalls{tool_calls: calls}, execution) do
    Enum.reduce_while(calls, {[], nil}, fn call, {results, final} ->
      :ok =
        Imp.Run.emit(:tool_call,
          component: __MODULE__,
          tool_call_id: call.id,
          tool_name: call.name,
          input: Imp.Tool.normalize_arguments(call.arguments)
        )

      case execute_call(react, call, execution) do
        {:cancel, reason} ->
          {:halt, {:cancel, reason}}

        {result, error?} ->
          :ok =
            Imp.Run.emit(:tool_result,
              component: __MODULE__,
              tool_call_id: call.id,
              tool_name: call.name,
              output: if(error?, do: nil, else: result),
              error: if(error?, do: result, else: nil)
            )

          result = %ToolResult{name: call.name, result: result, id: call.id}

          final =
            if submit?(call) and not error? and is_map(result.result),
              do: result.result,
              else: final

          {:cont, {results ++ [Map.put(Map.from_struct(result), :error, error?)], final}}
      end
    end)
  end

  defp execute_call(react, %ToolCall{name: requested, arguments: arguments} = call, execution) do
    name = Imp.Tool.resolve_name(react.tools, requested)
    arguments = Imp.Tool.normalize_arguments(arguments)

    cond do
      is_nil(name) ->
        {{:error, {:unknown_tool, requested}}, true}

      true ->
        tool = Map.fetch!(react.tools, name)

        with :ok <- Imp.ToolPolicy.authorize(react.tool_policy, name, arguments),
             :ok <- Imp.Tool.validate_input(tool, arguments) do
          authorize_and_call(react, tool, call, arguments, execution)
        else
          {:error, reason} -> {{:error, reason}, true}
        end
    end
  end

  defp authorize_and_call(react, %{name: :submit}, _call, arguments, _execution),
    do: validate_submit(react.signature, arguments)

  defp authorize_and_call(_react, tool, call, arguments, execution) do
    request = %Imp.Execution.Authorization{
      run_id: execution.run_id,
      tool_call_id: call.id,
      tool_name: tool.name,
      arguments: arguments,
      description: Imp.Execution.bounded_description(tool.description),
      metadata: %{runtime: __MODULE__}
    }

    case Imp.Execution.authorize(execution, request) do
      :allow ->
        safe_tool_call(tool, arguments)

      {:deny, reason} ->
        {{:error, {:tool_authorization_denied, tool.name, Imp.Redaction.redact(reason)}}, true}

      {:cancel, reason} ->
        {:cancel, reason}
    end
  end

  defp safe_tool_call(tool, arguments) do
    case Imp.Tool.call(tool, arguments) do
      {:error, reason} -> {{:error, reason}, true}
      result -> {result, false}
    end
  rescue
    error -> {{:error, {:tool_error, tool.name, Exception.message(error)}}, true}
  catch
    kind, reason -> {{:error, {:tool_error, tool.name, {kind, reason}}}, true}
  end

  defp validate_submit(signature, arguments) when is_map(arguments) do
    names = Imp.Signature.output_names(signature)

    {outputs, missing} =
      Enum.reduce(names, {%{}, []}, fn name, {outputs, missing} ->
        value = Map.get(arguments, name, Map.get(arguments, to_string(name), :__missing__))

        if value == :__missing__,
          do: {outputs, missing ++ [name]},
          else: {Map.put(outputs, name, value), missing}
      end)

    cond do
      missing != [] ->
        {{:error, {:missing_output_fields, missing}}, true}

      true ->
        case Imp.Adapter.Chat.parse(signature, outputs, []) do
          {:ok, prediction} -> {Imp.Prediction.to_map(prediction), false}
          {:error, reason} -> {{:error, {:invalid_submit_outputs, reason}}, true}
        end
    end
  end

  defp validate_submit(_signature, arguments),
    do: {{:error, {:invalid_submit_arguments, arguments}}, true}

  defp history_event(pending, prediction, calls, results, final) do
    pending
    |> maybe_put(:next_thought, Imp.get(prediction, :next_thought))
    |> Map.put(:tool_calls, calls)
    |> Map.put(:tool_call_results, results)
    |> then(fn event -> if final, do: Map.merge(event, final), else: event end)
    |> Imp.Redaction.redact()
  end

  defp final_prediction(final, history, reason) do
    prediction =
      final
      |> Map.put(:history, history)
      |> Map.put(:termination_reason, reason)
      |> Imp.Prediction.new()

    :ok = Imp.Run.emit(:final, component: __MODULE__, output: prediction)
    {:ok, prediction}
  end

  defp incomplete_prediction(history, reason, error) do
    fields = %{history: history, termination_reason: reason}

    fields =
      if error,
        do: Map.put(fields, :termination_error, Imp.Redaction.redact(error)),
        else: fields

    prediction = Imp.Prediction.new(fields)
    :ok = Imp.Run.emit(:final, component: __MODULE__, output: prediction)
    {:ok, prediction}
  end

  defp emit_reasoning(prediction, turn, metadata \\ []) do
    case Imp.get(prediction, :next_thought) do
      nil ->
        :ok

      "" ->
        :ok

      reasoning ->
        Imp.Run.emit(:reasoning,
          component: __MODULE__,
          reasoning: reasoning,
          metadata: Map.merge(%{turn: turn}, Map.new(metadata))
        )
    end
  end

  defp submit?(%ToolCall{name: name}), do: to_string(name) == "submit"

  defp termination_reason(%Imp.ContextWindowExceededError{}), do: :context_window_exceeded
  defp termination_reason(%Imp.AdapterParseError{}), do: :parse_error
  defp termination_reason(_reason), do: :prediction_error

  defp coerce_history(nil), do: {:ok, Imp.History.new()}
  defp coerce_history(%Imp.History{} = history), do: {:ok, history}

  defp coerce_history(%{"messages" => messages}) when is_list(messages),
    do: {:ok, Imp.History.new(messages)}

  defp coerce_history(%{messages: messages}) when is_list(messages),
    do: {:ok, Imp.History.new(messages)}

  defp coerce_history(messages) when is_list(messages), do: {:ok, Imp.History.new(messages)}
  defp coerce_history(history), do: {:error, {:invalid_react_v2_history, history}}

  defp normalize_inputs(inputs), do: {:ok, Map.new(inputs)}

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
    do: {:error, {:invalid_react_v2_max_iters, max_iters}}

  defp fetch_input(inputs, name), do: Map.get(inputs, name, Map.get(inputs, to_string(name)))
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp instructions(signature, tools) do
    inputs = signature |> Imp.Signature.input_names() |> Enum.map_join(", ", &"`#{&1}`")
    outputs = signature |> Imp.Signature.output_names() |> Enum.map_join(", ", &"`#{&1}`")
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
      tool_choice: "auto"
    ]
  end

  defp tool_description(%Imp.Tool{name: :submit} = tool, signature),
    do:
      provider_tool(
        tool,
        signature
        |> Imp.Signature.json_schema()
        |> Map.put("required", Enum.map(signature.outputs, &to_string(&1.name)))
      )

  defp tool_description(%Imp.Tool{schema: schema} = tool, _signature) when map_size(schema) > 0,
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

  defp validate_updated_tools!(original, updated) do
    unless MapSet.new(Map.keys(original)) == MapSet.new(Map.keys(updated)) do
      raise ArgumentError, "ReActV2 tool updates cannot add or remove tools"
    end

    Enum.each(original, fn {name, tool} ->
      case Map.fetch(updated, name) do
        {:ok, %Imp.Tool{} = replacement} ->
          ensure_preserved_tool!(tool, replacement)

        {:ok, replacement} ->
          raise ArgumentError, "ReActV2 tool update is not an Imp.Tool: #{inspect(replacement)}"

        :error ->
          raise ArgumentError, "ReActV2 tool update removed #{inspect(name)}"
      end
    end)

    updated
  end

  defp ensure_preserved_tool!(%Imp.Tool{name: :submit} = original, replacement) do
    unless replacement.name == original.name and replacement.description == original.description and
             replacement.schema == original.schema and replacement.run === original.run do
      raise ArgumentError, "ReActV2 submit is reserved and cannot be changed"
    end
  end

  defp ensure_preserved_tool!(original, replacement) do
    unless replacement.name == original.name and replacement.run === original.run do
      raise ArgumentError, "ReActV2 tool updates must preserve tool names and runners"
    end
  end
end

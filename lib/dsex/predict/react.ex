defmodule DSEx.Predict.ReAct do
  @moduledoc """
  Iterative provider-tool-call ReAct program with a reserved submit step.

  ReAct lets the LM choose from an explicit tool catalog, append observations to
  history, and eventually call the reserved `submit` tool with the signature's
  required output fields.

  Use it when the model must gather information or perform bounded actions
  before answering. Keep the tool policy narrow in production:

      lookup = DSEx.tool(:lookup, "lookup facts", fn %{query: query} -> query end)

      program =
        DSEx.react("question -> answer", [lookup],
          tool_policy: [:lookup, :submit],
          max_iters: 4
        )

  Failure semantics are explicit:

  - unknown model-selected tools return `{:error, {:unknown_tool, name}}`;
  - denied tools return `{:error, {:tool_denied, name}}`;
  - tool crashes return `{:error, {:tool_error, name, reason}}`;
  - tool-policy crashes return `{:error, {:tool_policy_error, name, reason}}`;
  - missing final fields return `{:error, {:missing_output_fields, fields}}`.

  Tool call history is redacted before it is attached to the final prediction.
  """

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
      instructions: react_instructions(signature.instructions)
    }

    react_opts =
      Keyword.update(opts, :config, provider_tool_config(tools, signature), fn config ->
        Keyword.merge(config, provider_tool_config(tools, signature))
      end)

    %__MODULE__{
      signature: signature,
      react: DSEx.Predict.Predict.new(react_signature, react_opts),
      tools: tools,
      max_iters: non_negative_integer(Keyword.get(opts, :max_iters, 20)),
      tool_policy: Keyword.get(opts, :tool_policy, :allow)
    }
  end

  defp react_instructions(instructions) do
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

  @impl true
  def call(%__MODULE__{} = agent, inputs) do
    run_loop(agent, Map.new(inputs), [], agent.max_iters)
  end

  defp run_loop(_agent, _inputs, history, 0) do
    {:error, {:react_max_iters, history}}
  end

  defp run_loop(agent, inputs, history, remaining) do
    tool_descriptions =
      agent.tools |> Map.values() |> Enum.map(&%{name: &1.name, description: &1.description})

    call_inputs = Map.merge(inputs, %{history: history, tools: tool_descriptions})

    with {:ok, prediction} <- DSEx.Predict.Predict.call(agent.react, call_inputs) do
      case DSEx.Prediction.get(prediction, :tool_calls, []) do
        [] ->
          final = project_outputs(agent.signature, prediction)
          validate_final(agent.signature, final, history, :direct)

        calls ->
          {events, final} = execute_calls(agent, List.wrap(calls))
          history = history ++ events

          error = Enum.find(events, &match?(%{result: {:error, _reason}}, &1))

          cond do
            error ->
              error.result

            final ->
              final = Map.merge(final, %{history: history, termination_reason: :submit})
              prediction = DSEx.Prediction.new(final)
              validate_final(agent.signature, prediction, history, :submit)

            true ->
              run_loop(agent, inputs, history, remaining - 1)
          end
      end
    end
  end

  defp execute_calls(agent, calls) do
    Enum.reduce_while(calls, {[], nil}, fn call, {events, final} ->
      {name, args, result} = prepare_tool_call(agent, call)

      event = DSEx.Redaction.redact(%{tool: name, arguments: args, result: result})
      final = if name == :submit and is_map(result), do: Map.new(result), else: final

      if final do
        {:halt, {events ++ [event], final}}
      else
        {:cont, {events ++ [event], final}}
      end
    end)
  end

  defp prepare_tool_call(agent, call) when is_map(call) do
    requested_name = Map.get(call, :name) || Map.get(call, "name")
    name = normalize_tool_name(agent.tools, requested_name)

    args =
      (Map.get(call, :arguments) || Map.get(call, :args) || Map.get(call, "arguments") ||
         %{})
      |> normalize_args()

    {name, args, execute_tool_call(agent, name, requested_name, args)}
  end

  defp prepare_tool_call(_agent, call), do: {nil, %{}, {:error, {:malformed_tool_call, call}}}

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
    DSEx.Tool.call(tool, args)
  rescue
    exception ->
      {:error, {:tool_error, tool.name, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:tool_error, tool.name, {kind, reason}}}
  end

  defp authorize_tool(:allow, _name, _args), do: :ok

  defp authorize_tool(allowed, name, _args) when is_list(allowed) do
    if name in allowed, do: :ok, else: {:error, {:tool_denied, name}}
  end

  defp authorize_tool(policy, name, args) when is_function(policy, 2) do
    try do
      case policy.(name, args) do
        true -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, {:tool_denied, name}}
      end
    rescue
      exception -> {:error, {:tool_policy_error, name, Exception.message(exception)}}
    catch
      kind, reason -> {:error, {:tool_policy_error, name, {kind, reason}}}
    end
  end

  defp authorize_tool(policy, name, _args) do
    if name in List.wrap(policy), do: :ok, else: {:error, {:tool_denied, name}}
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

  defp provider_tool_config(tools_map, signature) do
    tools =
      tools_map
      |> Map.values()
      |> Enum.map(fn tool ->
        %{
          type: "function",
          function: %{
            name: to_string(tool.name),
            description: tool.description,
            parameters: tool_parameters(tool, signature)
          }
        }
      end)

    [tools: tools, tool_choice: "auto"]
  end

  defp tool_parameters(%DSEx.Tool{name: :submit}, signature),
    do: DSEx.Signature.json_schema(signature)

  defp tool_parameters(%DSEx.Tool{schema: schema}, _signature) when map_size(schema) > 0,
    do: schema

  defp tool_parameters(_tool, _signature), do: %{"type" => "object", "properties" => %{}}

  defp coerce_tool(%DSEx.Tool{} = tool), do: tool

  defp normalize_tool_name(tools, name) do
    Enum.find_value(Map.keys(tools), fn known ->
      if to_string(known) == to_string(name), do: known
    end)
  end

  defp normalize_args(args) when is_map(args),
    do: Map.new(args, fn {key, value} -> {safe_existing_atom(key), value} end)

  defp normalize_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> normalize_args(decoded)
      {:error, _reason} -> args
    end
  end

  defp normalize_args(args), do: args

  defp safe_existing_atom(key) when is_atom(key), do: key

  defp safe_existing_atom(key) do
    String.to_existing_atom(to_string(key))
  rescue
    ArgumentError -> to_string(key)
  end

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0
end

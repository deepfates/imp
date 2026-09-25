defmodule Imp.Predict.ReAct do
  @moduledoc """
  ReAct agent with two distinct contracts, selected by `:mode`.

  ReAct lets the LM reason about the current situation and choose an action each
  turn, appending observations to a growing trajectory until the task is done.

  ## `:provider_native` (default) — Imp's provider-tool-calling ReAct

  The LM chooses from an explicit tool catalog via provider function calls,
  appends observations to `history`, and eventually calls the reserved `submit`
  tool. Keep the tool policy narrow in production:

      lookup = Imp.tool(:lookup, "lookup facts", fn %{query: query} -> query end)

      program =
        Imp.react("question -> answer", [lookup],
          tool_policy: [:lookup, :submit],
          max_iters: 4
        )

  This mode preserves the original Imp contract:

  - unknown model-selected tools return `{:error, {:unknown_tool, name}}`;
  - denied tools return `{:error, {:tool_authorization_denied, name, :tool_policy}}`;
  - tool crashes return `{:error, {:tool_error, name, reason}}`, where `reason`
    is the exception raised or `{kind, value}` for a throw or an exit;
  - tool-policy crashes return `{:error, {:tool_policy_error, name, reason}}`;
  - final outputs that are missing or do not fit the signature return
    `{:error, %Imp.AdapterParseError{kind: :missing_fields | :invalid_fields}}`.

  ## `:dspy_3_2_1` — a port of DSPy 3.2.1 `dspy.ReAct`

  This mode reproduces upstream `dspy/predict/react.py`, not a
  provider-tool-calling loop. It builds the same reasoning signature DSPy
  builds, with types and tool arguments named in Imp's neutral words rather
  than Python's:

  - inputs: the original inputs plus a `trajectory` string input;
  - outputs: `next_thought` (a string), `next_tool_name` (one of the tool
    names or `finish`), and `next_tool_args` (an object);
  - instructions: DSPy's "You are an Agent..." block, listing each tool
    textually (name, `<desc>`, and `It takes arguments {...}`), the reserved
    `finish` tool, and the JSON-format reminder.

  Each turn the model emits the three fields as ordinary chat output (no
  provider tool calls). After every tool call the observation is appended to the
  trajectory as text (`[[ ## thought_N ## ]]`, `[[ ## tool_name_N ## ]]`,
  `[[ ## tool_args_N ## ]]`, `[[ ## observation_N ## ]]`). The `finish` tool
  terminates the loop; a separate `dspy.ChainOfThought` extraction pass then maps
  `(inputs + trajectory)` to the original output fields.

  DSPy control flow reproduced here: `finish` terminates, iteration exhaustion
  falls through to extraction, and a reasoning-signature parse failure (an
  invalid/missing action, mirroring DSPy's `ValueError` break) also falls
  through to extraction. Tool exceptions become recoverable `Execution error in
  <tool>: ...` observations so the model can recover on a later turn (the
  message text is Imp's, not Python's traceback — see the release note). Tool
  policy is an Imp safety extension with no DSPy analogue: a denied or crashing
  policy stays fail-fast.

  Like upstream ReAct, a call may override the constructor's iteration budget
  with an invocation-local `:max_iters` or `"max_iters"` input. The control
  value is validated and removed before task inputs are sent to the LM.

  ## The prediction

  The prediction's fields are the signature's outputs (and, from an extraction
  pass, its `reasoning`). Its metadata carries the redacted tool call
  `:history`, `:termination_reason`, how the turn ended, and, when something
  interrupted it, `:termination_cause`:

    * `:submit`, `:finish` — the model called the reserved tool.
    * `:forced_submit` — a `:provider_native` step called no tool
      (`termination_cause: :empty_tool_calls`) and the forced `submit` that
      followed answered.
    * `:answered` — as above, but the forced `submit` did not answer, so the
      step's own text is projected onto the outputs.
    * `:extracted` — a `:dspy_3_2_1` turn that ended at `max_iters`, on a step
      that could not be parsed, or on a step with no tool call, answered by
      DSPy's extraction pass; `termination_cause` is `:max_iters`,
      `:parse_error` or `:empty_tool_calls`.
  """

  require Logger

  @behaviour Imp.Module

  @trajectory_call_attempts 3
  # One DSPy trajectory tool call is four keys: thought, tool_name, tool_args,
  # observation (see dspy/predict/react.py `truncate_trajectory`).
  @trajectory_keys_per_call 4

  defstruct [
    :signature,
    :react,
    tools: %{},
    max_iters: 20,
    tool_policy: :allow,
    mode: :provider_native
  ]

  @type t :: %__MODULE__{}

  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    max_iters: [type: :non_neg_integer, default: 20],
    mode: [type: {:in, [:provider_native, :dspy_3_2_1]}, default: :provider_native],
    tool_policy: [
      type: {:custom, Imp.ToolPolicy, :validate, []},
      default: :allow
    ]
  ]

  def new(signature, tools, opts \\ []) do
    signature = Imp.Signature.ensure(signature)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.ReAct.new/3")
    # index_tools!/2 validates the list and raises on invalid entries; keep the
    # original `tools` list because DSPy tool order is load-bearing for the
    # `next_tool_name` Literal and the instruction listing (:dspy_3_2_1).
    _tool_map = Imp.Tool.index_tools!(tools, "Imp.Predict.ReAct.new/3")
    build_agent(opts[:mode], signature, tools, opts)
  end

  # ------------------------------------------------------------------
  # :provider_native construction (unchanged behavior)
  # ------------------------------------------------------------------

  defp build_agent(:provider_native = mode, signature, tools_list, opts) do
    tool_map = Map.new(tools_list, &{&1.name, &1})
    submit = submit_tool(mode)
    tools = Map.put(tool_map, :submit, submit)

    react_signature = %Imp.Signature{
      inputs:
        signature.inputs ++
          [
            Imp.Signature.Field.new(:history, :input),
            Imp.Signature.Field.new(:tools, :input)
          ],
      outputs: [
        Imp.Signature.Field.new(
          %{name: :next_thought, metadata: %{optional: true}},
          :output
        ),
        Imp.Signature.Field.new(%{name: :tool_calls, type: :array}, :output)
      ],
      instructions: react_instructions(signature.instructions, mode)
    }

    react_opts =
      opts
      |> Imp.Predict.Predict.take_options()
      |> Keyword.update(:config, provider_tool_config(tools, signature, mode), fn config ->
        Keyword.merge(config, provider_tool_config(tools, signature, mode))
      end)

    %__MODULE__{
      signature: signature,
      react: Imp.Predict.Predict.new(react_signature, react_opts),
      tools: tools,
      max_iters: non_negative_integer(opts[:max_iters]),
      tool_policy: opts[:tool_policy],
      mode: mode
    }
  end

  # ------------------------------------------------------------------
  # :dspy_3_2_1 construction — the reasoning signature and instructions built
  # by dspy/predict/react.py ReAct.__init__.
  # ------------------------------------------------------------------

  defp build_agent(:dspy_3_2_1 = mode, signature, tools_list, opts) do
    finish = finish_tool(signature)
    ordered = tools_list ++ [finish]
    tools = Map.new(ordered, &{&1.name, &1})
    tool_names = Enum.map(ordered, &to_string(&1.name))

    react_signature = %Imp.Signature{
      inputs:
        signature.inputs ++ [Imp.Signature.Field.new(%{name: :trajectory, type: :string}, :input)],
      outputs: [
        Imp.Signature.Field.new(%{name: :next_thought, type: :string}, :output),
        Imp.Signature.Field.new(
          %{name: :next_tool_name, type: :string, constraints: %{enum: tool_names}},
          :output
        ),
        Imp.Signature.Field.new(%{name: :next_tool_args, type: :object}, :output)
      ],
      instructions: dspy_react_instructions(signature, ordered)
    }

    # No provider tool config: the model produces next_tool_name/next_tool_args
    # as ordinary chat output fields, exactly as DSPy's dspy.Predict does.
    react_opts =
      opts
      |> Imp.Predict.Predict.take_options()
      |> Keyword.delete(:adapter_opts)

    %__MODULE__{
      signature: signature,
      react: Imp.Predict.Predict.new(react_signature, react_opts),
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

  @doc false
  # The reserved control tool name for a mode: `:submit` (provider-native) or
  # `:finish` (dspy_3_2_1). Used by Imp.Saving to strip/rebuild it on dump/load.
  def reserved_tool_name(:provider_native), do: :submit
  def reserved_tool_name(:dspy_3_2_1), do: :finish

  @doc false
  # Rebuild the reserved control tool for a mode + signature (the dspy_3_2_1
  # `finish` description references the signature's output fields).
  def reserved_tool(:provider_native, _signature), do: submit_tool(:provider_native)
  def reserved_tool(:dspy_3_2_1, signature), do: finish_tool(signature)

  defp submit_tool(:provider_native),
    do: Imp.Tool.new(:submit, "Submit final outputs", fn args -> args end)

  # The reserved DSPy `finish` tool (dspy/predict/react.py). Its description
  # references the original output field names and it takes no arguments.
  defp finish_tool(signature) do
    outputs = backtick_names(signature.outputs)

    desc =
      "Marks the task as complete. That is, signals that all information for producing the outputs, i.e. #{outputs}, are now available to be extracted."

    Imp.Tool.new(:finish, desc, fn _args -> "Completed." end, schema: %{})
  end

  # The instruction block built by
  # dspy/predict/react.py ReAct.__init__ (`instr` list joined by "\n").
  defp dspy_react_instructions(signature, ordered_tools) do
    inputs = backtick_names(signature.inputs)
    outputs = backtick_names(signature.outputs)

    head =
      case to_string(signature.instructions || "") do
        "" -> []
        instructions -> ["#{instructions}\n"]
      end

    body = [
      "You are an Agent. In each episode, you will be given the fields #{inputs} as input. And you can see your past trajectory so far.",
      "Your goal is to use one or more of the supplied tools to collect any necessary information for producing #{outputs}.\n",
      "To do this, you will interleave next_thought, next_tool_name, and next_tool_args in each turn, and also when finishing the task.",
      "After each tool call, you receive a resulting observation, which gets appended to your trajectory.\n",
      "When writing next_thought, you may reason about the current situation and plan for future steps.",
      "When selecting the next_tool_name and its next_tool_args, the tool must be one of:\n"
    ]

    tool_lines =
      ordered_tools
      |> Enum.with_index(1)
      |> Enum.map(fn {tool, idx} -> "(#{idx}) #{tool_instruction(tool)}" end)

    tail = ["When providing `next_tool_args`, the value inside the field must be in JSON format"]

    Enum.join(head ++ body ++ tool_lines ++ tail, "\n")
  end

  defp backtick_names(fields),
    do: fields |> Enum.map_join(", ", fn field -> "`#{field.name}`" end)

  # dspy.adapters.types.tool.Tool.__str__:
  #   "{name}, whose description is <desc>{desc}</desc>. It takes arguments {args}."
  # where the description segment collapses newlines to two spaces, and `args`
  # is the tool's argument schema as JSON.
  defp tool_instruction(%Imp.Tool{} = tool) do
    desc_segment =
      case to_string(tool.description || "") do
        "" ->
          "."

        desc ->
          String.replace(", whose description is <desc>#{desc}</desc>.", "\n", "  ")
      end

    "#{tool.name}#{desc_segment} It takes arguments #{Imp.Adapter.Chat.format_value(tool_args_schema(tool))}."
  end

  # DSPy's Tool.args for these tools is `schema["properties"]` (see the golden
  # trace harness `build_tool`). The reserved finish tool takes no arguments.
  defp tool_args_schema(%Imp.Tool{name: :finish}), do: %{}

  defp tool_args_schema(%Imp.Tool{schema: schema}) when is_map(schema),
    do: Map.get(schema, "properties", Map.get(schema, :properties, %{}))

  defp tool_args_schema(_tool), do: %{}

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

  @impl true
  def call(%__MODULE__{mode: :dspy_3_2_1} = agent, inputs)
      when is_list(inputs) or is_map(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         {max_iters, inputs} <- pop_max_iters(inputs, agent.max_iters),
         :ok <- validate_call_max_iters(max_iters) do
      run_faithful_loop(agent, inputs, 0, [], max_iters)
    end
  end

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
          extract_final(agent, inputs, effective_history, :parse_error)
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

      Imp.Predict.Predict.call(agent.react, call_inputs)
    end

    call_with_trajectory_truncation(agent.mode, call, history)
  end

  defp handle_action_prediction(agent, inputs, history, remaining, prediction) do
    case Imp.Prediction.get(prediction, :tool_calls, []) do
      [] when agent.mode == :dspy_3_2_1 ->
        extract_final(agent, inputs, history, :empty_tool_calls)

      [] ->
        force_provider_submit(agent, inputs, history, prediction)

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
            prediction = Imp.Prediction.new(final)
            validate_final(agent.signature, prediction, history, :submit)

          true ->
            run_loop(agent, inputs, history, remaining - 1)
        end
    end
  end

  # Provider-native ReAct has an explicit completion protocol: the model must
  # call the reserved submit tool. Models occasionally emit ordinary assistant
  # text after observing a tool result even when the prompt asks them to submit.
  # Give that boundary one provider-neutral forced-tool turn instead of treating
  # the absent structured outputs as the final result. This mirrors ReActV2's
  # terminal behavior and does not spend another ordinary loop iteration.
  defp force_provider_submit(agent, inputs, history, direct_prediction) do
    forced = %{
      agent
      | react: %{
          agent.react
          | config:
              Keyword.merge(agent.react.config,
                tool_choice: %{type: "tool", name: "submit"},
                reasoning_effort: nil
              )
        }
    }

    tool_descriptions =
      forced.tools |> Map.values() |> Enum.map(&%{name: &1.name, description: &1.description})

    case call_action(forced, inputs, history, tool_descriptions) do
      {:ok, prediction, effective_history} ->
        submit_calls =
          prediction
          |> Imp.Prediction.get(:tool_calls, [])
          |> List.wrap()
          |> Enum.filter(&(normalize_tool_name(forced.tools, tool_call_name(&1)) == :submit))

        case execute_calls(forced, submit_calls) do
          {events, final, failure, true} when not is_nil(final) ->
            history = effective_history ++ events

            if failure do
              failure
            else
              prediction = Imp.Prediction.new(final)
              validate_final(agent.signature, prediction, history, :forced_submit)
            end

          _other ->
            direct = project_outputs(agent.signature, direct_prediction)
            validate_final(agent.signature, direct, history, :answered)
        end

      {:error, _reason, _effective_history} ->
        direct = project_outputs(agent.signature, direct_prediction)
        validate_final(agent.signature, direct, history, :answered)
    end
  end

  defp execute_calls(agent, calls) do
    Enum.reduce_while(calls, {[], nil, nil, false}, fn call,
                                                       {events, final, failure, _submitted?} ->
      {name, args, outcome} = prepare_tool_call(agent, call)
      {result, call_failure} = interpret_outcome(agent.mode, name, outcome)

      event = Imp.Redaction.redact(%{tool: name, arguments: args, result: result})
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
    case Imp.Prediction.get(prediction, :next_thought) do
      nil -> [event | events]
      thought -> [Imp.Redaction.redact(Map.put(event, :thought, thought)) | events]
    end
  end

  defp attach_thought(_mode, _prediction, events), do: events

  defp prepare_tool_call(agent, call) when is_map(call) do
    requested_name = tool_call_name(call)
    name = normalize_tool_name(agent.tools, requested_name)

    if is_nil(name) do
      Logger.warning(
        "ReAct could not resolve a tool from call: #{inspect(Imp.Redaction.redact(call), limit: 20, printable_limit: 500)}"
      )
    end

    args = call |> tool_call_arguments() |> Imp.Tool.normalize_arguments()

    {name, args, execute_tool_call(agent, name, requested_name, args)}
  end

  defp prepare_tool_call(_agent, call),
    do: {nil, %{}, {:error, {:malformed_tool_call, call}}}

  defp tool_call_name(call) do
    function = Map.get(call, :function) || Map.get(call, "function") || %{}

    name =
      Map.get(call, :name) || Map.get(call, "name") || Map.get(function, :name) ||
        Map.get(function, "name") || Map.get(call, :tool) || Map.get(call, "tool") ||
        Map.get(call, :recipient_name) || Map.get(call, "recipient_name")

    # OpenAI's multi_tool_use wire shape namespaces the tool as
    # "functions.<name>" under recipient_name; LiteLLM (DSPy's client)
    # normalizes it away, so models emit it expecting the strip.
    case name do
      "functions." <> bare -> bare
      other -> other
    end
  end

  defp tool_call_arguments(call) do
    function = Map.get(call, :function) || Map.get(call, "function") || %{}

    Map.get(call, :arguments) || Map.get(call, :args) || Map.get(call, "arguments") ||
      Map.get(call, "args") || Map.get(function, :arguments) || Map.get(function, :args) ||
      Map.get(function, "arguments") || Map.get(function, "args") ||
      Map.get(call, :parameters) || Map.get(call, "parameters") || %{}
  end

  defp execute_tool_call(_agent, nil, requested_name, _args) do
    if requested_name in [nil, "", "None", "null"] do
      # A missing/placeholder tool name usually means the completion was
      # truncated before the model finished emitting a tool call (reasoning
      # models burn completion budget on reasoning first) or the model
      # emitted a no-tool placeholder. Say so instead of leaving the caller
      # to debug {:unknown_tool, nil}.
      Logger.warning(
        "ReAct received a tool call with missing/placeholder name " <>
          "#{inspect(requested_name)}. This usually means the completion was " <>
          "truncated before a tool call was emitted - check finish_reason and " <>
          "raise max_completion_tokens (reasoning models need budget for " <>
          "reasoning before the call)."
      )
    end

    {:error, {:unknown_tool, requested_name}}
  end

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
    {:ok, Imp.Tool.call(tool, args)}
  rescue
    exception ->
      {:error, {:tool_error, tool.name, exception}}
  catch
    kind, reason ->
      {:error, {:tool_error, tool.name, {kind, reason}}}
  end

  defp authorize_tool(policy, name, args), do: Imp.ToolPolicy.authorize(policy, name, args)

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

  # DSPy formats the raised exception; Imp's failures are terms, so the model
  # reads the words `Imp.Adapter.Chat` renders for them rather than the term.
  defp format_tool_error(reason), do: Imp.Adapter.Chat.tool_error_text(reason)

  defp action_parse_failure?(%Imp.AdapterParseError{}), do: true
  defp action_parse_failure?({:missing_output_fields, _fields}), do: true
  defp action_parse_failure?({:react_context_window_exceeded_after_truncation, _reason}), do: true
  defp action_parse_failure?({:react_trajectory_not_truncatable, _reason}), do: true
  defp action_parse_failure?(_reason), do: false

  # ------------------------------------------------------------------
  # :dspy_3_2_1 loop — faithful reproduction of ReAct.forward.
  #
  # `trajectory` is an ORDERED list of {key, value} pairs (Elixir maps do not
  # preserve insertion order, and DSPy's trajectory keys must render in
  # thought/tool_name/tool_args/observation order). Like DSPy, the trajectory IS
  # the record: the attached `history` is derived from the final (possibly
  # truncated) trajectory, so truncated-away tool calls disappear from both the
  # extraction prompt and the recorded history exactly as they do upstream.
  # ------------------------------------------------------------------

  defp run_faithful_loop(agent, inputs, idx, trajectory, max_iters)
       when idx >= max_iters do
    faithful_extract(agent, inputs, trajectory, :max_iters)
  end

  defp run_faithful_loop(agent, inputs, idx, trajectory, max_iters) do
    reason_call = fn trajectory_text ->
      Imp.Predict.Predict.call(agent.react, Map.put(inputs, :trajectory, trajectory_text))
    end

    case faithful_trajectory_call(reason_call, trajectory) do
      {:ok, prediction, trajectory} ->
        handle_faithful_action(agent, inputs, idx, trajectory, max_iters, prediction)

      {:error, reason, trajectory} ->
        # DSPy breaks the loop on a reasoning-signature ValueError (an invalid or
        # missing action) and proceeds to extraction. Mirror that for parse
        # failures; surface anything else (LM/input errors) as-is.
        if action_parse_failure?(reason) do
          faithful_extract(agent, inputs, trajectory, :parse_error)
        else
          {:error, reason}
        end
    end
  end

  defp handle_faithful_action(agent, inputs, idx, trajectory, max_iters, prediction) do
    thought = Imp.Prediction.get(prediction, :next_thought)
    requested_name = Imp.Prediction.get(prediction, :next_tool_name)

    args =
      prediction |> Imp.Prediction.get(:next_tool_args, %{}) |> Imp.Tool.normalize_arguments()

    resolved = normalize_tool_name(agent.tools, requested_name)
    finish? = to_string(requested_name) == "finish"

    {observation, failure} = run_faithful_tool(agent, finish?, resolved, requested_name, args)

    case failure do
      nil ->
        trajectory =
          trajectory ++
            [
              {"thought_#{idx}", thought},
              {"tool_name_#{idx}", to_string(requested_name)},
              {"tool_args_#{idx}", args},
              {"observation_#{idx}", observation}
            ]

        if finish? do
          faithful_extract(agent, inputs, trajectory, :finish)
        else
          run_faithful_loop(agent, inputs, idx + 1, trajectory, max_iters)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The reserved `finish` tool always runs (no side effects, no tool policy),
  # exactly as `self.tools["finish"]()` in DSPy. Real tools go through policy and
  # the DSPy-mode outcome interpreter, so exceptions become recoverable
  # observations while policy failures stay fail-fast.
  defp run_faithful_tool(_agent, true, _resolved, _requested_name, _args), do: {"Completed.", nil}

  defp run_faithful_tool(agent, false, resolved, requested_name, args) do
    outcome = execute_tool_call(agent, resolved, requested_name, args)
    interpret_outcome(:dspy_3_2_1, resolved || requested_name, outcome)
  end

  defp faithful_extract(agent, inputs, trajectory, reason) do
    extractor = faithful_extraction_program(agent)

    extract_call = fn trajectory_text ->
      Imp.Predict.ChainOfThought.call(extractor, Map.put(inputs, :trajectory, trajectory_text))
    end

    case faithful_trajectory_call(extract_call, trajectory) do
      {:ok, prediction, trajectory} ->
        final = project_extraction(agent.signature, prediction)
        validate_final(agent.signature, final, faithful_history(agent, trajectory), reason)

      {:error, error, _trajectory} ->
        {:error, error}
    end
  end

  # Build the redacted tool-event history from the final trajectory pairs. Each
  # tool call is four consecutive keys (thought/tool_name/tool_args/observation);
  # tool names resolve back to the catalog atom for stable event identity.
  defp faithful_history(agent, trajectory) do
    trajectory
    |> Enum.chunk_every(@trajectory_keys_per_call)
    |> Enum.map(fn chunk ->
      fields = Map.new(chunk, fn {key, value} -> {trajectory_key_kind(key), value} end)

      Imp.Redaction.redact(%{
        thought: fields[:thought],
        tool: normalize_tool_name(agent.tools, fields[:tool_name]) || fields[:tool_name],
        arguments: fields[:tool_args] || %{},
        result: fields[:observation]
      })
    end)
  end

  defp trajectory_key_kind("thought_" <> _), do: :thought
  defp trajectory_key_kind("tool_name_" <> _), do: :tool_name
  defp trajectory_key_kind("tool_args_" <> _), do: :tool_args
  defp trajectory_key_kind("observation_" <> _), do: :observation

  defp faithful_extraction_program(agent) do
    signature = %Imp.Signature{
      inputs:
        agent.signature.inputs ++
          [Imp.Signature.Field.new(%{name: :trajectory, type: :string}, :input)],
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

    Imp.Predict.ChainOfThought.new(signature, opts)
  end

  # DSPy's `_call_with_potential_trajectory_truncation`: retry up to three times,
  # dropping the oldest tool call (four keys) each time the context window is
  # exceeded. The truncated trajectory propagates to the caller (DSPy mutates the
  # dict in place).
  defp faithful_trajectory_call(module_call, trajectory),
    do: faithful_trajectory_call(module_call, trajectory, @trajectory_call_attempts)

  defp faithful_trajectory_call(module_call, trajectory, attempts_left) do
    case module_call.(format_trajectory(trajectory)) do
      {:ok, prediction} ->
        {:ok, prediction, trajectory}

      {:error, reason} ->
        cond do
          not Imp.Errors.context_window_exceeded?(reason) ->
            {:error, reason, trajectory}

          attempts_left > 1 ->
            case truncate_trajectory_pairs(trajectory) do
              {:ok, truncated} ->
                faithful_trajectory_call(module_call, truncated, attempts_left - 1)

              :error ->
                {:error, {:react_trajectory_not_truncatable, reason}, trajectory}
            end

          true ->
            case truncate_trajectory_pairs(trajectory) do
              {:ok, truncated} ->
                {:error, {:react_context_window_exceeded_after_truncation, reason}, truncated}

              :error ->
                {:error, {:react_trajectory_not_truncatable, reason}, trajectory}
            end
        end
    end
  end

  defp truncate_trajectory_pairs(trajectory) when length(trajectory) <= @trajectory_keys_per_call,
    do: :error

  defp truncate_trajectory_pairs(trajectory),
    do: {:ok, Enum.drop(trajectory, @trajectory_keys_per_call)}

  # Byte-faithful reproduction of ReAct._format_trajectory, which calls the
  # ChatAdapter's format_user_message_content over a `{keys...} -> x` signature:
  # every trajectory key is a str input field joined by "\n\n" then stripped.
  defp format_trajectory([]), do: ""

  defp format_trajectory(pairs) do
    pairs
    |> Enum.map(fn {key, value} -> "[[ ## #{key} ## ]]\n#{format_trajectory_value(value)}" end)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  # Mirrors dspy.adapters.utils.format_field_value under a str-annotated field:
  # a list becomes a numbered blob list; a dict/list JSON value is dumped with
  # Python's json.dumps spacing; everything else is stringified.
  defp format_trajectory_value(value) when is_list(value), do: format_input_list(value)
  defp format_trajectory_value(value) when is_map(value), do: python_json(value)
  defp format_trajectory_value(value) when is_binary(value), do: value
  # A bare scalar observation takes its JSON spelling (`true`, `false`,
  # `null`), and a float its shortest fixed-or-exponent form (1000000.0, not
  # Elixir's 1.0e6).
  defp format_trajectory_value(true), do: "true"
  defp format_trajectory_value(false), do: "false"
  defp format_trajectory_value(nil), do: "null"
  defp format_trajectory_value(value) when is_float(value), do: Imp.PyFloat.repr(value)
  defp format_trajectory_value(value), do: to_string(value)

  defp format_input_list([]), do: "N/A"
  defp format_input_list([single]), do: format_blob(single)

  defp format_input_list(values) do
    values
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {value, idx} -> "[#{idx}] #{format_blob(value)}" end)
  end

  defp format_blob(blob) when is_binary(blob) do
    if String.contains?(blob, "\n") or String.contains?(blob, "«") or String.contains?(blob, "»") do
      "«««\n    " <> String.replace(blob, "\n", "\n    ") <> "\n»»»"
    else
      "«" <> blob <> "»"
    end
  end

  defp format_blob(blob), do: format_blob(to_string(blob))

  # Python json.dumps(..., ensure_ascii=False) with default separators (", " and
  # ": "). Only maps/lists get the spacing; scalars defer to Jason.
  defp python_json(value) when is_map(value) do
    "{" <>
      Enum.map_join(value, ", ", fn {key, value} ->
        "#{Jason.encode!(to_string(key))}: #{python_json(value)}"
      end) <> "}"
  end

  defp python_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &python_json/1) <> "]"

  # Python json.dumps renders floats with the same repr algorithm str() uses
  # (`{"p": 1000000.0}`, not Jason's `1.0e6`); scalars otherwise defer to Jason,
  # whose bool/null/int/string output already matches json.dumps (dee-h7nw).
  defp python_json(value) when is_float(value), do: Imp.PyFloat.repr(value)
  defp python_json(value), do: Jason.encode!(value)

  defp extract_final(agent, inputs, history, reason) do
    extractor = extraction_program(agent)

    call = fn effective_history ->
      Imp.Predict.ChainOfThought.call(extractor, Map.put(inputs, :history, effective_history))
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
        if Imp.Errors.context_window_exceeded?(reason) do
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
        if Imp.Errors.context_window_exceeded?(reason) do
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

  defp project_extraction(signature, prediction) do
    fields =
      prediction
      |> Imp.Prediction.to_map()
      |> Map.take([:reasoning | Imp.Signature.output_names(signature)])

    Imp.Prediction.new(fields, metadata: prediction.metadata)
  end

  defp extraction_program(agent) do
    signature = %Imp.Signature{
      inputs: agent.signature.inputs ++ [Imp.Signature.Field.new(:history, :input)],
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

    Imp.Predict.ChainOfThought.new(signature, opts)
  end

  defp project_outputs(signature, prediction) do
    fields =
      Map.take(
        Imp.Prediction.to_map(prediction),
        Imp.Signature.output_names(signature)
      )

    Imp.Prediction.new(fields, metadata: prediction.metadata)
  end

  # How the turn ended, and what interrupted it when something did. The model
  # calling `submit` or `finish` ends a turn on its own terms. In
  # `:provider_native` mode a step that calls no tool is answered by a forced
  # `submit`, or failing that by its own text (`:answered`); in `:dspy_3_2_1`
  # mode every other ending is DSPy's extraction pass (`:extracted`).
  defp termination(reason) when reason in [:submit, :finish],
    do: %{termination_reason: reason}

  defp termination(reason) when reason in [:forced_submit, :answered],
    do: %{termination_reason: reason, termination_cause: :empty_tool_calls}

  defp termination(cause), do: %{termination_reason: :extracted, termination_cause: cause}

  defp validate_final(signature, prediction, history, ending) do
    fields = Imp.Prediction.to_map(prediction)

    case Imp.Schema.validate_fields(signature.outputs, fields) do
      :ok ->
        metadata =
          prediction.metadata
          |> Map.put(:history, history)
          |> Map.merge(termination(ending))

        {:ok, %{prediction | metadata: metadata}}

      {:error, errors} ->
        missing =
          errors
          |> Enum.filter(&(&1.rule == :required))
          |> Enum.map(& &1.field)

        if missing == [] do
          {:error,
           %Imp.AdapterParseError{
             kind: :invalid_fields,
             message: Imp.Schema.retry_feedback(errors),
             reason: fields
           }}
        else
          {:error, Imp.AdapterParseError.missing_fields(missing)}
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

  defp tool_parameters(%Imp.Tool{name: :submit}, _signature, :dspy_3_2_1),
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  defp tool_parameters(%Imp.Tool{name: :submit}, signature, :provider_native),
    do: Imp.Signature.json_schema(signature)

  defp tool_parameters(%Imp.Tool{schema: schema}, _signature, _mode) when map_size(schema) > 0,
    do: schema

  defp tool_parameters(_tool, _signature, _mode),
    do: %{"type" => "object", "properties" => %{}}

  defp normalize_tool_name(tools, name), do: Imp.Tool.resolve_name(tools, name)

  defp validate_updated_tools!(original, updated) do
    unless MapSet.new(Map.keys(original)) == MapSet.new(Map.keys(updated)) do
      raise ArgumentError, "ReAct tool updates cannot add or remove tools"
    end

    Enum.each(original, fn {name, tool} ->
      case Map.fetch(updated, name) do
        {:ok, %Imp.Tool{} = replacement} ->
          ensure_preserved_tool!(tool, replacement)

        {:ok, replacement} ->
          raise ArgumentError, "ReAct tool update is not an Imp.Tool: #{inspect(replacement)}"

        :error ->
          raise ArgumentError, "ReAct tool update removed #{inspect(name)}"
      end
    end)

    updated
  end

  defp ensure_preserved_tool!(%Imp.Tool{name: :submit} = original, replacement) do
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

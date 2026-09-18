defmodule Imp.Predict.ReActV2 do
  @moduledoc """
  Native-tool-aware ReAct loop with structured history and typed completion.

  ReActV2 preserves parallel tool call IDs and results in `Imp.History`, keeps
  unknown and failed tool calls as observations, and forces a final `submit`
  call when the loop ends without outputs.

  A step's outputs are `next_thought` and `tool_calls`. The provider holds the
  tool roster natively, so a step normally comes back as native tool calls. A
  step that comes back as plain prose with no tool call is read as that prose
  being `next_thought` and no tool calls, by the `:prose_step` metadata on the
  internal step signature that `Imp.Adapter.Chat` honors: it is a thought that
  called nothing, not a parse failure, so it costs one LM call rather than two
  and keeps the provider's prefix cache. That thought is appended to the
  history as its own turn, and an empty tool-call list then ends the step at
  the forced `submit` with `:empty_tool_calls`. A tool call the model writes as
  JSON rather than calling natively is accepted with `tool` for `name` and
  `args` or `parameters` for `arguments` (`Imp.Adapter.Types.ToolCall`); a map
  that names no tool at all is kept as a malformed-call observation. That
  forced request says nothing
  about why by default; `:forced_submit_notice`, a string or a 1-arity function
  of the termination reason, adds one user-visible turn saying so, which is kept
  in the returned history like any other turn. If a provider cannot
  honor that tool contract, a tools-disabled typed extractor derives the task
  outputs from the original inputs and accumulated history.

  On a recognized context-window refusal, up to eight smaller requests omit
  oldest prior episodes from the prompt, preserving their full durable history.
  Completed signature outputs delimit episodes; a trailing unfinished prior
  group is kept together. Current-call tool observations are never omitted or
  replayed. Omission counts appear in `:context_projection` and native
  `:context_projected` events. If the current call and instructions alone exceed
  the window, an incomplete prediction retains history and context diagnostics.
  This is lossy prompt selection, not summarization or deletion of memory.
  """

  @behaviour Imp.Module

  alias Imp.Adapter.Types.{ToolCall, ToolCalls, ToolResult}

  @malformed_tool_call "__imp_malformed_tool_call__"

  defstruct [
    :signature,
    :react,
    :forced_submit_notice,
    tools: %{},
    max_iters: 20,
    tool_policy: :allow
  ]

  @type t :: %__MODULE__{}

  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    # Handed to the adapter beside the loop's own guidance; a host injects its
    # renderers here (`Imp.Adapter.Chat` `:system_renderer`).
    adapter_opts: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    max_iters: [type: :non_neg_integer, default: 20],
    tool_policy: [type: {:custom, Imp.ToolPolicy, :validate, []}, default: :allow],
    # What to tell the model when the loop makes it submit. A 1-arity function
    # of the termination reason, or a plain string; nil says nothing, which is
    # what the loop did before this option existed.
    forced_submit_notice: [type: {:or, [{:fun, 1}, :string, nil]}, default: nil]
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
            [Imp.Signature.Field.new(%{name: :history, type: :history}, :input)],
        outputs: [
          Imp.Signature.Field.new(%{name: :next_thought, metadata: %{optional: true}}, :output),
          Imp.Signature.Field.new(
            %{name: :tool_calls, type: :array, metadata: %{default: []}},
            :output
          )
        ],
        instructions: signature.instructions,
        # A step answered in plain prose, with no native tool call, is a
        # thought that called nothing. `Imp.Adapter.Chat` reads a marker-free
        # completion as `next_thought`, and `tool_calls` takes its declared
        # default of none, which ends the step at `forced_submit`.
        metadata: %{prose_step: :next_thought}
      }

    config = Keyword.merge(opts[:config], provider_tool_config(tools, signature))

    # The roster goes to the provider once, natively, in `config`. The loop's
    # guidance goes to the adapter as data. Nothing about tools is written into
    # the signature or rendered into a user message, so a step's request is the
    # previous step's request plus the newest exchange, which is what a
    # provider's prompt cache is keyed on.
    adapter_opts =
      Keyword.merge(Keyword.get(opts, :adapter_opts, []),
        guidance: guidance(signature, tools),
        response_instruction: false,
        omit_empty_request: true
      )

    %__MODULE__{
      signature: signature,
      react:
        Imp.Predict.Predict.new(
          react_signature,
          Keyword.merge(opts, config: config, adapter_opts: adapter_opts)
        ),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy],
      forced_submit_notice: opts[:forced_submit_notice]
    }
  end

  @doc false
  def with_tools(%__MODULE__{} = agent, tools) when is_map(tools) do
    tools = validate_updated_tools!(agent.tools, tools)

    react = %{
      agent.react
      | config: Keyword.merge(agent.react.config, provider_tool_config(tools, agent.signature)),
        adapter_opts:
          Keyword.put(agent.react.adapter_opts, :guidance, guidance(agent.signature, tools))
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

      run(
        react,
        history_context(history, react.signature),
        pending,
        pending,
        0,
        max_iters,
        execution
      )
    end
  end

  defp run(react, history, inputs, pending, turn, max_iters, execution) when turn >= max_iters,
    do: forced_submit(react, history, inputs, pending, :max_iters, turn, nil, execution)

  defp run(react, history, inputs, pending, turn, max_iters, execution) do
    case predict(react.react, react, history, pending) do
      {:ok, prediction, history} ->
        calls = prediction |> Imp.get(:tool_calls, []) |> normalize_calls(turn)
        emit_reasoning(prediction, turn)

        if calls.tool_calls == [] do
          # The step said something and called nothing. What it said is part of
          # the run, so it is appended as this turn's history event before the
          # forced request; the pending inputs it carries are then spent.
          {history, pending} = append_thought_only_step(history, pending, prediction, calls)

          forced_submit(
            react,
            history,
            inputs,
            pending,
            :empty_tool_calls,
            turn,
            nil,
            execution
          )
        else
          case execute_calls(react, calls, execution) do
            {:cancel, reason} ->
              {:error, {:execution_cancelled, reason}}

            {results, final} ->
              event = history_event(pending, prediction, calls, results, final)
              history = append_history(history, event)

              if final,
                do: final_prediction(final, history, :submit),
                else: run(react, history, inputs, %{}, turn + 1, max_iters, execution)
          end
        end

      {:error, reason, history} ->
        if context_window_exceeded?(reason) do
          incomplete_prediction(history, :context_window_exceeded, reason)
        else
          forced_submit(
            react,
            history,
            inputs,
            pending,
            termination_reason(reason),
            turn,
            reason,
            execution
          )
        end
    end
  end

  defp forced_submit(
         react,
         history,
         inputs,
         pending,
         reason,
         turn,
         initial_error,
         execution
       ) do
    history = append_forced_submit_notice(react, history, reason)

    case forced_submit_prediction(react, history, pending) do
      {:ok, prediction, history} ->
        calls = prediction |> Imp.get(:tool_calls, []) |> normalize_calls(turn)
        emit_reasoning(prediction, turn, forced?: true)

        finish_forced_submit(
          react,
          prediction,
          calls,
          history,
          inputs,
          pending,
          reason,
          initial_error,
          execution
        )

      {:extract, forced_error, history} ->
        extract_final(react, inputs, history, reason, %{
          initial: initial_error,
          forced_submit: forced_error
        })

      {:error, forced_error, history} ->
        reason =
          if context_window_exceeded?(forced_error), do: :context_window_exceeded, else: reason

        incomplete_prediction(history, reason, %{
          initial: initial_error,
          forced_submit: forced_error
        })
    end
  end

  # The notice is what the model is told, so it goes into the durable history
  # rather than into one request: the record of the run carries it, and the
  # prompt renders it as the last user message before the forced request.
  defp append_forced_submit_notice(react, history, reason) do
    case notice_text(react.forced_submit_notice, reason) do
      text when is_binary(text) and text != "" ->
        case Imp.Signature.input_names(react.signature) do
          [first | _rest] -> append_history(history, %{first => text})
          [] -> history
        end

      _none ->
        history
    end
  end

  defp notice_text(nil, _reason), do: nil
  defp notice_text(text, _reason) when is_binary(text), do: text
  defp notice_text(fun, reason) when is_function(fun, 1), do: fun.(reason)

  defp forced_submit_prediction(react, history, pending) do
    forced = forced_submit_program(react, %{type: "tool", name: "submit"})

    case predict(forced, react, history, pending) do
      {:error, reason, history} = error ->
        if named_tool_choice_unsupported?(reason) do
          # Some OpenAI-compatible endpoints implement only the string
          # none/auto/required subset. Restrict both the provider tools and the
          # rendered tool inventory to submit before requiring a call; using
          # "required" while other tools remain visible would not force final
          # submission.
          submit = Map.fetch!(react.tools, :submit)
          submit_only = %{react | tools: %{submit: submit}}
          fallback = forced_submit_program(submit_only, "required")

          case predict(fallback, submit_only, history, pending) do
            {:ok, prediction, history} ->
              {:ok, prediction, history}

            {:error, fallback_error, history} ->
              if context_window_exceeded?(fallback_error),
                do: {:error, fallback_error, history},
                else: {:extract, fallback_error, history}
          end
        else
          error
        end

      {:ok, prediction, history} ->
        {:ok, prediction, history}
    end
  end

  defp finish_forced_submit(
         react,
         prediction,
         calls,
         history,
         inputs,
         pending,
         reason,
         initial_error,
         execution
       ) do
    submit_calls = %ToolCalls{tool_calls: Enum.filter(calls.tool_calls, &submit?/1)}

    if submit_calls.tool_calls == [] do
      history = maybe_append_forced_observation(history, pending, prediction, calls)
      extract_final(react, inputs, history, reason, initial_error)
    else
      case execute_calls(react, submit_calls, execution) do
        {:cancel, cancel_reason} ->
          {:error, {:execution_cancelled, cancel_reason}}

        {results, final} ->
          event = history_event(pending, prediction, submit_calls, results, final)
          history = append_history(history, event)

          if final,
            do: final_prediction(final, history, :forced_submit),
            else: incomplete_prediction(history, reason, initial_error)
      end
    end
  end

  defp append_thought_only_step(history, pending, prediction, calls) do
    case Imp.get(prediction, :next_thought) do
      thought when thought in [nil, ""] ->
        {history, pending}

      _thought ->
        {append_history(history, history_event(pending, prediction, calls, [], nil)), %{}}
    end
  end

  defp maybe_append_forced_observation(history, pending, prediction, calls) do
    thought = Imp.get(prediction, :next_thought)

    if thought in [nil, ""] and calls.tool_calls == [] do
      history
    else
      event = history_event(pending, prediction, calls, [], nil)
      append_history(history, event)
    end
  end

  defp forced_submit_program(react, tool_choice) do
    %{
      react.react
      | config:
          Keyword.merge(react.react.config,
            tools: Enum.map(Map.values(react.tools), &tool_description(&1, react.signature)),
            tool_choice: tool_choice,
            reasoning_effort: nil
          )
    }
  end

  defp extract_final(react, inputs, history, reason, initial_error) do
    extractor = extraction_program(react)

    case context_call(history, fn projected ->
           Imp.Predict.ChainOfThought.call(extractor, Map.put(inputs, :history, projected))
         end) do
      {:ok, prediction, history} ->
        final =
          prediction
          |> Imp.Prediction.to_map()
          |> Map.take(Imp.Signature.output_names(react.signature))

        case Imp.Schema.validate_fields(react.signature.outputs, final) do
          :ok ->
            final =
              final
              |> Map.put(:completion_mode, :typed_extraction)
              |> Map.put(:termination_cause, reason)

            final_prediction(final, history, :forced_submit)

          {:error, errors} ->
            incomplete_prediction(history, reason, %{
              initial: initial_error,
              extraction: Imp.Schema.retry_feedback(errors)
            })
        end

      {:error, extraction_error, history} ->
        reason =
          if context_window_exceeded?(extraction_error),
            do: :context_window_exceeded,
            else: reason

        incomplete_prediction(history, reason, %{
          initial: initial_error,
          extraction: extraction_error
        })
    end
  end

  defp extraction_program(react) do
    signature = %Imp.Signature{
      inputs: react.signature.inputs ++ [Imp.Signature.Field.new(:history, :input)],
      outputs: react.signature.outputs,
      instructions: extraction_instructions(react.signature.instructions)
    }

    predict = react.react

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

  defp extraction_instructions(task_instructions) do
    """
    #{task_instructions}

    Produce the final outputs only from the original inputs and successful tool
    results recorded in `history`. A proposed tool call, model reasoning, a
    malformed call, or an error result is not evidence that an action happened.
    Never claim that an action or verification succeeded unless `history`
    contains its successful result. If the requested outcome is not established,
    report that limitation honestly in the declared output fields. No tools are
    available during this extraction step.
    """
    |> String.trim()
  end

  defp named_tool_choice_unsupported?(reason) do
    text = reason |> error_text() |> String.downcase()

    String.contains?(text, "tool_choice") and
      (String.contains?(text, "invalid") or String.contains?(text, "unsupported")) and
      (String.contains?(text, "required") or String.contains?(text, "supported string"))
  end

  defp error_text(value) when is_binary(value), do: value

  defp error_text(value) when is_exception(value), do: Exception.message(value)

  defp error_text(value) when is_map(value) do
    [
      :reason,
      "reason",
      :message,
      "message",
      :response_body,
      "response_body",
      :error,
      "error",
      :errors,
      "errors"
    ]
    |> Enum.flat_map(fn key ->
      case Map.fetch(value, key) do
        {:ok, nested} -> [nested]
        :error -> []
      end
    end)
    |> Enum.map_join(" ", &error_text/1)
  end

  defp error_text(value) when is_list(value), do: Enum.map_join(value, " ", &error_text/1)

  defp error_text(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map_join(" ", &error_text/1)
  end

  defp error_text(value), do: inspect(value)

  defp predict(program, _react, history, pending) do
    context_call(history, fn projected ->
      Imp.Predict.Predict.call(program, Map.put(pending, :history, projected))
    end)
  end

  defp normalize_calls(%ToolCalls{} = calls, turn), do: ensure_ids(calls, turn)

  # `ToolCalls.format/1` and provider adapters may retain the collection wrapper
  # around an otherwise normalized list. Accept either key vocabulary rather
  # than treating that wrapper as one tool call.
  defp normalize_calls(%{tool_calls: calls}, turn), do: normalize_calls(calls, turn)
  defp normalize_calls(%{"tool_calls" => calls}, turn), do: normalize_calls(calls, turn)

  defp normalize_calls(calls, turn) do
    calls = Enum.map(List.wrap(calls), &normalize_call/1)
    ensure_ids(%ToolCalls{tool_calls: calls}, turn)
  end

  defp normalize_call(%ToolCall{} = call), do: call

  defp normalize_call(call) do
    ToolCall.from_map(call)
  rescue
    ArgumentError ->
      %ToolCall{
        name: @malformed_tool_call,
        arguments: %{received: call}
      }
  end

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
      unless malformed_call?(call) do
        :ok =
          Imp.Run.emit(:tool_call,
            component: __MODULE__,
            tool_call_id: call.id,
            tool_name: call.name,
            input: Imp.Tool.normalize_arguments(call.arguments)
          )
      end

      case execute_call(react, call, execution) do
        {:cancel, reason} ->
          {:halt, {:cancel, reason}}

        {result, error?} ->
          unless malformed_call?(call) do
            :ok =
              Imp.Run.emit(:tool_result,
                component: __MODULE__,
                tool_call_id: call.id,
                tool_name: call.name,
                output: if(error?, do: nil, else: result),
                error: if(error?, do: result, else: nil)
              )
          end

          result = %ToolResult{name: call.name, result: result, id: call.id}

          final =
            if submit?(call) and not error? and is_map(result.result),
              do: result.result,
              else: final

          {:cont, {results ++ [Map.put(Map.from_struct(result), :error, error?)], final}}
      end
    end)
  end

  defp execute_call(
         _react,
         %ToolCall{name: @malformed_tool_call, arguments: %{received: received}},
         _execution
       ),
       do: {{:error, {:malformed_tool_call, received}}, true}

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

  defp malformed_call?(%ToolCall{name: @malformed_tool_call}), do: true
  defp malformed_call?(%ToolCall{}), do: false

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
      |> Map.put(:history, history.full)
      |> projection_metadata(history)
      |> Map.put(:termination_reason, reason)
      |> Imp.Prediction.new()

    :ok = Imp.Run.emit(:final, component: __MODULE__, output: prediction)
    {:ok, prediction}
  end

  defp incomplete_prediction(history, reason, error) do
    fields = projection_metadata(%{history: history.full, termination_reason: reason}, history)

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

  # Full history remains the durable result. Only whole prior episode groups are
  # eligible for prompt projection; tool observations appended in this call are
  # protected even if they alone exceed the model window.
  defp history_context(history, signature) do
    outputs = Imp.Signature.output_names(signature)
    size = length(history.messages)

    boundaries =
      history.messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {entry, _} ->
        outputs != [] and
          Enum.all?(outputs, fn name ->
            Map.has_key?(entry, name) or Map.has_key?(entry, to_string(name))
          end)
      end)
      |> Enum.map(&elem(&1, 1))

    boundaries =
      if size > 0 and List.last(boundaries) != size, do: boundaries ++ [size], else: boundaries

    %{full: history, boundaries: boundaries, omitted: 0, omitted_groups: 0, retries: 0}
  end

  defp append_history(context, event),
    do: %{context | full: Imp.History.append(context.full, event)}

  defp context_call(context, call) do
    projected = %{context.full | messages: Enum.drop(context.full.messages, context.omitted)}

    case call.(projected) do
      {:ok, prediction} ->
        {:ok, prediction, context}

      {:error, reason} ->
        if context_window_exceeded?(reason) do
          remaining = Enum.drop_while(context.boundaries, &(&1 <= context.omitted))

          if remaining != [] and context.retries < 8 do
            drop =
              if context.retries == 7,
                do: length(remaining),
                else: max(div(length(remaining) + 1, 2), 1)

            cutoff = Enum.at(remaining, drop - 1)

            context = %{
              context
              | omitted: cutoff,
                omitted_groups: context.omitted_groups + drop,
                retries: context.retries + 1
            }

            :ok =
              Imp.Run.emit(:context_projected,
                component: __MODULE__,
                metadata: projection(context)
              )

            context_call(context, call)
          else
            diagnostic =
              if remaining == [], do: :history_not_reducible, else: :recovery_budget_exhausted

            {:error,
             %Imp.ContextWindowExceededError{
               message: "ReActV2 context cannot be reduced safely",
               reason: %{diagnostic: diagnostic, cause: reason, projection: projection(context)}
             }, context}
          end
        else
          {:error, reason, context}
        end
    end
  end

  defp projection(context),
    do: %{
      reason: :context_window_exceeded,
      omitted_prior_entries: context.omitted,
      omitted_prior_groups: context.omitted_groups,
      recovery_requests: context.retries
    }

  defp projection_metadata(fields, %{omitted: 0}), do: fields

  defp projection_metadata(fields, context),
    do: Map.put(fields, :context_projection, projection(context))

  defp context_window_exceeded?(%Imp.ContextWindowExceededError{}), do: true
  defp context_window_exceeded?({:lm_failed, _, reason}), do: context_window_exceeded?(reason)
  defp context_window_exceeded?({:error, reason}), do: context_window_exceeded?(reason)
  defp context_window_exceeded?(%{reason: reason}), do: context_window_exceeded?(reason)
  defp context_window_exceeded?(_), do: false

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

  # What the adapter needs to say about the loop, as data. `finish_tool` is the
  # tool that ends the turn, so a renderer never has to know its name.
  defp guidance(signature, tools) do
    %{
      finish_tool: :submit,
      input_names: Imp.Signature.input_names(signature),
      output_names: Imp.Signature.output_names(signature),
      tool_names: tools |> Map.keys() |> Enum.sort()
    }
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

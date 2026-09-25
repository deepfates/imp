defmodule Imp.Predict.ReActV2 do
  @moduledoc """
  Native-tool-aware ReAct loop with structured history and typed completion.

  ReActV2 preserves parallel tool call IDs and results in `Imp.History` and
  keeps unknown and failed tool calls as observations.

  ## Which signatures get `submit`

  A task signature with exactly one output of type `:string` has an answer
  that the model can write as plain text, so its loop offers no `submit` tool.
  Every other signature (several outputs, or one output that is not text) gets
  the reserved `submit` tool, whose parameters are the signature's outputs,
  exactly as DSPy's ReActV2 has it. The name `submit` is reserved for every
  signature, so a user tool cannot take it.

  ## The prediction

  The prediction's fields are the signature's outputs and nothing else, so an
  output may be called anything, `history` included. How the turn went is in
  its metadata:

    * `:history` — the turn's full `Imp.History`, to pass back as the
      `:history` input of the next call.
    * `:termination_reason` — how the turn ended (below).
    * `:termination_cause` — present whenever the turn was interrupted: for
      `:last_text`, `:forced_submit` and `:extracted`, the interruption that led
      to the last request. For `:incomplete`, the same interruption, unless
      the turn's context window was full or its `Imp.Deadline` had passed,
      which would refuse any further request too and so are named instead;
      `termination_error` holds the errors of the requests that failed. One of `:max_iters`, `:parse_error`, `:prediction_error`,
      `:invalid_answer`, `:empty_tool_calls`, `:context_window_exceeded` and
      `:deadline_exceeded`.
    * `:termination_error` — for `:incomplete`, the redacted errors of the
      requests that failed.
    * `:finished_by_tool` — the terminal tool that ended the turn.
    * `:unexecuted_tool_calls` — tool calls the last request made that were
      not run.
    * `:context_projection` — how many prior episodes were left out of a
      request (see below).

  `Imp.Prediction.complete?/1` is false exactly when the reason is
  `:incomplete`.

  ## How a turn ends

    * `:answered` (one text output). A step that says something and calls no
      tool is the answer, in that one request.
    * `:submit` (every other signature). The model calls `submit` with the
      signature's outputs.
    * `:finished_by_tool`. `finish_on` maps a tool name to
      `fn arguments, result, inputs -> {:finish, outputs} | :continue end`. It
      runs after that tool's call executes; `{:finish, outputs}` validates
      `outputs` against the signature exactly as a `submit` would and ends the
      turn, with `finished_by_tool` naming the tool. `:continue` leaves the
      loop running. When one step calls several terminal tools, the first in
      call order finishes the run; the rest still execute and are recorded,
      and a `submit` in the same step still wins. Outputs that fail validation
      are recorded as that call's result, the same error a bad `submit`
      records, and the loop continues.
    * `:last_text`, `:forced_submit`, `:extracted`. The turn was interrupted
      and its last request answered (below).
    * `:incomplete`. The turn was interrupted and has no answer.

  ## When a turn is interrupted

  A turn is interrupted when it reaches `max_iters`, when a step's request
  fails (`:prediction_error`, `:parse_error`), or when a step calls no tool and
  gives no answer (`:invalid_answer` for text the output does not
  accept, and `:empty_tool_calls` for a signature with `submit`).

  With one text output, a step that calls no tool and says nothing is not an
  interruption: it is an empty answer, and the turn ends there
  (`:answered`). Saying nothing is how a model declines to answer, and asking
  it again would make declining cost a second request.

  With one text output, every interruption takes the same path: one more
  request, and its text is the answer (`:last_text`).
  The request is a step like any other: the same tools and the same
  `tool_choice: "auto"`. A provider may refuse a history of tool calls when no
  tools are declared (Anthropic does), and a changed roster changes the prompt
  prefix a provider caches. It does not say `tool_choice: "none"`: a model told
  that while it wants a tool can write the call as text in its own tool markup
  (seen from inkling through OpenRouter, and through DeepInfra),
  and that text would become the answer. If the model calls a tool, the call
  is not run; the completion's text, if any, is the answer, and the calls are
  kept in `unexecuted_tool_calls`. A completion that says nothing is an empty
  answer rather than an error. If the process's `Imp.Deadline` has already
  passed, no request is made and the turn is `:incomplete` with
  `termination_cause: :deadline_exceeded`.

  With `submit`, an interruption forces one more request with `tool_choice`
  naming `submit` (`:forced_submit`), as DSPy does. If a provider cannot honor
  that tool contract, a tools-disabled typed extractor derives the task
  outputs from the original inputs and accumulated history (`:extracted`).

  The last request says nothing about why it is being made unless
  `:last_request_note` is given: one line of host text put in front of it as a
  user message and kept in the returned history like any other turn. Imp
  writes no sentence of its own.

  A request refused because the context window is full is not an
  interruption of this kind: a further request would be refused the same way,
  so the turn ends at once as `:incomplete` with `termination_cause:
  :context_window_exceeded` (see below).

  A step's outputs are `next_thought` and `tool_calls`. The provider holds the
  tool roster natively, so a step normally comes back as native tool calls. A
  step that comes back as plain text with no tool call is read as that text
  being `next_thought` and no tool calls, by the `:text_step` metadata on the
  internal step signature that `Imp.Adapter.Chat` honors: it is a thought that
  called nothing, not a parse failure, so it costs one LM call rather than two
  and keeps the provider's prefix cache. That thought is appended to the
  history as its own turn. A tool call the model writes as
  JSON rather than calling natively is accepted with `tool` for `name` and
  `args` or `parameters` for `arguments` (`Imp.Adapter.Types.ToolCall`); a map
  that names no tool at all is kept as a malformed-call observation.

  On a recognized context-window refusal, up to eight smaller requests omit
  oldest prior episodes from the prompt, preserving their full durable history.
  Completed signature outputs delimit episodes; a trailing unfinished prior
  group is kept together. Current-call tool observations are never omitted or
  replayed. Omission counts appear in `:context_projection` and native
  `:context_projected` events. If the current call and instructions alone exceed
  the window, an incomplete prediction retains history and context diagnostics.
  This is lossy prompt selection, not summarization or deletion of memory.

  Tool history retains provider-native reasoning text and opaque reasoning
  details for continuation, including after `Imp.History.dump/1` and `Imp.History.load/1`.
  These are operational protocol data and must remain unmodified. Store history
  privately; use redacted events or `Imp.History.redact/1` for diagnostic copies.
  """

  @behaviour Imp.Module

  alias Imp.Adapter.Types.{ToolCall, ToolCalls, ToolResult}

  @malformed_tool_call "__imp_malformed_tool_call__"

  defstruct [
    :signature,
    :react,
    :last_request_note,
    tools: %{},
    max_iters: 20,
    tool_policy: :allow,
    finish_on: %{}
  ]

  @type t :: %__MODULE__{}

  @option_schema [
    lm: [
      type: {:custom, Imp.LM, :validate_lm, []},
      doc: "The model each step calls. When absent, each call uses `Imp.Settings`' `:lm`."
    ],
    adapter: [
      type: {:custom, Imp.Adapter, :validate_adapter, []},
      doc:
        "The adapter that renders each step's request and parses its reply. When " <>
          "absent, each call uses `Imp.Settings`' `:adapter`."
    ],
    demos: [
      type: {:list, :any},
      default: [],
      doc: "Worked examples for the step predictor, as for `Imp.Predict.Predict`."
    ],
    config: [
      type: :keyword_list,
      default: [],
      doc:
        "Request options for every step (temperature, max tokens, ...). The tool " <>
          "roster is added here, so do not pass `:tools`."
    ],
    adapter_opts: [
      type: :keyword_list,
      default: [],
      doc:
        "Options handed to the adapter beside the loop's own guidance; a host " <>
          "injects its renderers here, such as `Imp.Adapter.Chat`'s `:system_renderer`."
    ],
    metadata: [
      type: {:map, :any, :any},
      default: %{},
      doc: "Free-form metadata kept on the step predictor."
    ],
    max_iters: [
      type: :non_neg_integer,
      default: 20,
      doc:
        "Steps before the turn is interrupted. An interrupted turn ends with the " <>
          "forced `submit`, or, for a signature with one text output, one last " <>
          "text-only request."
    ],
    tool_policy: [
      type: {:custom, Imp.ToolPolicy, :validate, []},
      default: :allow,
      doc: "Which tool calls may run; see `Imp.ToolPolicy`."
    ],
    last_request_note: [
      type: {:or, [:string, nil]},
      default: nil,
      doc:
        "One line of host text put in front of the last request of an interrupted " <>
          "turn, as a user message, and kept in the history: the last text-only " <>
          "request for a signature with one text output, the forced `submit` for " <>
          "every other. `nil` says nothing; Imp writes no sentence of its own."
    ],
    finish_on: [
      type: {:custom, __MODULE__, :validate_finish_on, []},
      default: %{},
      doc:
        "Tools whose call ends the turn: a map from tool name to " <>
          "`fn arguments, result, inputs -> {:finish, outputs} | :continue end`. " <>
          "See \"How a turn ends\" above."
    ]
  ]

  @doc """
  Builds a ReAct loop over `tools` for `signature`.

  `tools` is a list of `Imp.Tool` values; the name `submit` is reserved. The
  signature decides whether the loop has a `submit` tool (see the module
  documentation).

  ## Options

  #{NimbleOptions.docs(@option_schema)}
  """
  @spec new(Imp.Signature.t() | String.t(), [Imp.Tool.t()], keyword()) :: t()
  def new(signature, tools, opts \\ []) do
    signature = Imp.Signature.ensure(signature)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.ReActV2.new/3")
    tools = Imp.Tool.index_tools!(tools, "Imp.Predict.ReActV2.new/3")

    if Imp.Tool.resolve_name(tools, :submit) do
      raise ArgumentError, "submit is reserved by Imp.Predict.ReActV2"
    end

    tools = put_submit(tools, signature)

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
        # A step answered in plain text, with no native tool call, is a
        # thought that called nothing. `Imp.Adapter.Chat` reads a marker-free
        # completion as `next_thought`, and `tool_calls` takes its declared
        # default of none, which ends the turn: as the answer when the
        # signature has one text output, and at the forced submit otherwise.
        metadata: %{text_step: :next_thought}
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
          opts
          |> Imp.Predict.Predict.take_options()
          |> Keyword.merge(config: config, adapter_opts: adapter_opts)
        ),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy],
      last_request_note: opts[:last_request_note],
      finish_on: resolve_finish_on!(opts[:finish_on], tools)
    }
  end

  @doc false
  # Adds the reserved `submit` tool when the signature has one. Loading a saved
  # program goes through here too, so the rule lives in one place.
  #
  # Divergence from DSPy's ReActV2, which offers `submit` for every signature:
  # a signature with one text output gets none. Its answer is the text the
  # model writes when it stops calling tools, which is how every other
  # mainstream tool loop ends a turn, and a `submit` beside that would be a
  # second way to say the same thing. DSPy needs `submit` because a signature
  # can have several typed outputs, and those signatures still get it.
  def put_submit(tools, signature) do
    if single_text_output?(signature),
      do: tools,
      else:
        Map.put(
          tools,
          :submit,
          Imp.Tool.new(:submit, "Submit the final outputs for the task.", & &1)
        )
  end

  @doc false
  def validate_finish_on(finish_on) when is_map(finish_on) do
    invalid =
      Enum.find(finish_on, fn {name, fun} ->
        not ((is_atom(name) or is_binary(name)) and is_function(fun, 3))
      end)

    case invalid do
      nil -> {:ok, finish_on}
      {name, _fun} -> {:error, "expected #{inspect(name)} to name a 3-arity function"}
    end
  end

  def validate_finish_on(other),
    do: {:error, "expected a map of tool name to 3-arity function, got: #{inspect(other)}"}

  # A `finish_on` key is normalized to the tool's own name the same way a model's
  # spelling of a call is, so the loop looks it up by one key. An unknown name is
  # a typo the caller should hear about at construction, not a tool that silently
  # never finishes.
  defp resolve_finish_on!(finish_on, tools) do
    Map.new(finish_on, fn {name, fun} ->
      case Imp.Tool.resolve_name(tools, name) do
        nil ->
          raise ArgumentError, "Imp.Predict.ReActV2.new/3: :finish_on names no tool: #{name}"

        :submit ->
          raise ArgumentError, "Imp.Predict.ReActV2.new/3: submit already ends the turn"

        resolved ->
          {to_string(resolved), fun}
      end
    end)
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
    do: interrupted(react, history, inputs, pending, :max_iters, turn, nil, execution)

  defp run(react, history, inputs, pending, turn, max_iters, execution) do
    case predict(react.react, react, history, pending) do
      {:ok, prediction, history} ->
        calls = prediction |> Imp.get(:tool_calls, []) |> normalize_calls(turn)

        # Text that is the answer is not a thought: the prediction carries
        # it, and a `:reasoning` event would say it a second time.
        if calls.tool_calls == [] do
          # The step called nothing. What it said is part of the run, so it is
          # appended as this turn's history event, with the outputs when it is
          # the answer, as a `submit`'s event carries them; the pending inputs
          # it carries are then spent.
          case parse_text(react.signature, prediction) do
            {:ok, outputs} ->
              # The model stopped calling tools and said its answer. That is the
              # end of the turn, and it costs no further request.
              history =
                append_history(history, history_event(pending, prediction, calls, [], outputs))

              final_prediction(outputs, history, :answered)

            {:none, cause} ->
              emit_reasoning(prediction, turn)
              {history, pending} = append_thought_only_step(history, pending, prediction, calls)
              interrupted(react, history, inputs, pending, cause, turn, nil, execution)
          end
        else
          emit_reasoning(prediction, turn)

          case execute_calls(react, calls, execution, inputs) do
            {:cancel, reason} ->
              {:error, {:execution_cancelled, reason}}

            {results, final, finished_by} ->
              event = history_event(pending, prediction, calls, results, final)
              history = append_history(history, event)

              cond do
                final ->
                  final_prediction(final, history, :submit)

                finished_by ->
                  {tool_name, outputs} = finished_by

                  final_prediction(outputs, history, :finished_by_tool, %{
                    finished_by_tool: tool_name
                  })

                true ->
                  run(react, history, inputs, %{}, turn + 1, max_iters, execution)
              end
          end
        end

      {:error, reason, history} ->
        if Imp.Errors.context_window_exceeded?(reason) do
          incomplete_prediction(history, :context_window_exceeded, reason)
        else
          interrupted(
            react,
            history,
            inputs,
            pending,
            interruption(reason),
            turn,
            reason,
            execution
          )
        end
    end
  end

  # The one place an interrupted turn goes: the last request for a signature
  # with one text output, the forced submit for every other.
  defp interrupted(react, history, inputs, pending, cause, turn, error, execution) do
    if single_text_output?(react.signature),
      do: last_text(react, history, pending, cause, turn, error),
      else: forced_submit(react, history, inputs, pending, cause, turn, error, execution)
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
    {history, pending} = note_after_inputs(history, pending, react)

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
        incomplete_prediction(history, failed_last_request_cause(reason, forced_error), %{
          initial: initial_error,
          forced_submit: forced_error
        })
    end
  end

  # An interrupted turn of a signature with one text output. The last request
  # is an ordinary step, and its text is the single text output. A tool call
  # in it is not run, and is kept out of the history, where it would replay as
  # a call with no result; the prediction names it in `unexecuted_tool_calls`
  # instead. A completion that says nothing is an empty answer: the run is
  # over either way, and there is nothing to force.
  # A deadline that has already passed leaves no time for that request, so
  # none is made.
  defp last_text(react, history, pending, cause, turn, initial_error) do
    if deadline_passed?() do
      incomplete_prediction(history, :deadline_exceeded, initial_error)
    else
      {history, pending} = note_after_inputs(history, pending, react)

      case predict(react.react, react, history, pending) do
        {:ok, prediction, history} ->
          calls = prediction |> Imp.get(:tool_calls, []) |> normalize_calls(turn)
          outputs = last_text_outputs(react.signature, prediction)
          no_calls = %ToolCalls{tool_calls: []}
          history = append_last_step(history, pending, prediction, no_calls, outputs)

          final_prediction(
            outputs,
            history,
            :last_text,
            put_unexecuted(%{termination_cause: cause}, calls)
          )

        {:error, reason, history} ->
          incomplete_prediction(history, failed_last_request_cause(cause, reason), %{
            initial: initial_error,
            last_text: reason
          })
      end
    end
  end

  # The note is the last thing the model reads. Inputs no step has spent yet
  # (the first step failed) would otherwise render after it, so they go into
  # the history first, as the user turn they are.
  defp note_after_inputs(history, pending, %{last_request_note: note} = react)
       when is_binary(note) and note != "" and map_size(pending) > 0 do
    history = history |> append_history(pending) |> append_note(react.signature, note)
    {history, %{}}
  end

  defp note_after_inputs(history, pending, react),
    do: {append_note(history, react.signature, react.last_request_note), pending}

  defp deadline_passed?, do: Imp.Deadline.expired?(Imp.Deadline.current())

  # The cause of a turn whose last request failed: the interruption that led to
  # that request, unless the request failed because the turn is out of time or
  # its context window is full. Those two would refuse any further request the
  # same way, so they are what the caller has to change.
  defp failed_last_request_cause(interruption, error) do
    cond do
      deadline_passed?() -> :deadline_exceeded
      Imp.Errors.context_window_exceeded?(error) -> :context_window_exceeded
      true -> interruption
    end
  end

  defp put_unexecuted(metadata, %ToolCalls{tool_calls: []}), do: metadata

  defp put_unexecuted(metadata, %ToolCalls{tool_calls: calls}) do
    unexecuted =
      Enum.map(calls, fn call ->
        %{id: call.id, name: call.name, arguments: Imp.Tool.normalize_arguments(call.arguments)}
      end)

    Map.put(metadata, :unexecuted_tool_calls, Imp.Redaction.redact(unexecuted))
  end

  defp last_text_outputs(signature, prediction) do
    case parse_text(signature, prediction) do
      {:ok, outputs} ->
        outputs

      {:none, _cause} ->
        [%Imp.Signature.Field{name: name}] = signature.outputs
        %{name => nil}
    end
  end

  # The note is what the model is told, so it goes into the durable history
  # rather than into one request: the record of the run carries it, and the
  # prompt renders it as the last user message before the last request.
  defp append_note(history, signature, text) when is_binary(text) and text != "" do
    case Imp.Signature.input_names(signature) do
      [first | _rest] -> append_history(history, %{first => text})
      [] -> history
    end
  end

  defp append_note(history, _signature, _none), do: history

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
              if Imp.Errors.context_window_exceeded?(fallback_error),
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
      history = append_last_step(history, pending, prediction, calls, nil)
      extract_final(react, inputs, history, reason, initial_error)
    else
      case execute_calls(react, submit_calls, execution, inputs) do
        {:cancel, cancel_reason} ->
          {:error, {:execution_cancelled, cancel_reason}}

        {results, final, _finished_by} ->
          event = history_event(pending, prediction, submit_calls, results, final)
          history = append_history(history, event)

          if final,
            do: final_prediction(final, history, :forced_submit, %{termination_cause: reason}),
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

  # The completion of the run's last request, thought and any calls, as this
  # turn's history event, with the outputs when they are the answer. A
  # completion that said nothing and called nothing adds no turn.
  defp append_last_step(history, pending, prediction, calls, outputs) do
    thought = Imp.get(prediction, :next_thought)

    if thought in [nil, ""] and calls.tool_calls == [] do
      history
    else
      event = history_event(pending, prediction, calls, [], outputs)
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
            final_prediction(final, history, :extracted, %{termination_cause: reason})

          {:error, errors} ->
            incomplete_prediction(history, reason, %{
              initial: initial_error,
              extraction: Imp.Schema.retry_feedback(errors)
            })
        end

      {:error, extraction_error, history} ->
        incomplete_prediction(history, failed_last_request_cause(reason, extraction_error), %{
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

  defp execute_calls(react, %ToolCalls{tool_calls: calls}, execution, inputs) do
    Enum.reduce_while(calls, {[], nil, nil}, fn call, {results, final, finished_by} ->
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

        # The outcome is decided where the call was refused or dispatched: a
        # tool can return any term, so its value alone cannot say it was
        # refused. A terminal tool has already run and the hook only reads
        # what it did, so outputs the hook cannot fit make the result an
        # error, not the call a refusal.
        {result, error?, outcome} ->
          {result, error?, finished_by} =
            finish_on_result(react, call, result, error?, inputs, finished_by)

          unless malformed_call?(call) do
            :ok =
              Imp.Run.emit(:tool_result,
                component: __MODULE__,
                tool_call_id: call.id,
                tool_name: call.name,
                output: if(error?, do: nil, else: result),
                error: if(error?, do: result, else: nil),
                metadata: %{outcome: outcome}
              )
          end

          result = %ToolResult{name: call.name, result: result, id: call.id}

          final =
            if submit?(call) and not error? and is_map(result.result),
              do: result.result,
              else: final

          {:cont,
           {results ++ [Map.put(Map.from_struct(result), :error, error?)], final, finished_by}}
      end
    end)
  end

  # `finish_on` is consulted for every successful call to a terminal tool, but
  # only the first one that finishes ends the run: the rest of the step's calls
  # still execute and are recorded, as they would be in any other step. Outputs
  # that do not satisfy the signature are that call's recorded result, which is
  # the error an invalid `submit` records, and the loop keeps going.
  defp finish_on_result(react, call, result, error?, inputs, finished_by) do
    with false <- error?,
         false <- malformed_call?(call),
         {:ok, fun} <- fetch_finish_on(react, call),
         {:finish, outputs} <- fun.(Imp.Tool.normalize_arguments(call.arguments), result, inputs) do
      case validate_submit(react.signature, outputs) do
        {validated, false} when finished_by == nil ->
          {result, false, {to_string(Imp.Tool.resolve_name(react.tools, call.name)), validated}}

        {_validated, false} ->
          {result, false, finished_by}

        {error, true} ->
          {error, true, finished_by}
      end
    else
      _continue -> {result, error?, finished_by}
    end
  end

  defp fetch_finish_on(%{finish_on: finish_on}, _call) when map_size(finish_on) == 0, do: :error

  defp fetch_finish_on(react, call) do
    case Imp.Tool.resolve_name(react.tools, call.name) do
      nil -> :error
      name -> Map.fetch(react.finish_on, to_string(name))
    end
  end

  # A step that stops calling tools and says something has answered, when the
  # task declares exactly one text output for that text to be. Several outputs,
  # or one that is not text, cannot be filled from text alone and take the
  # forced submit. The text is validated through the same parse a `submit`'s
  # arguments go through, so a constrained output is not quietly filled with
  # something it excludes. What is not an answer carries the interruption it
  # is.
  defp parse_text(signature, prediction) do
    with {:text, [%Imp.Signature.Field{name: name}]} <- text_output(signature),
         {:written, text} when is_binary(text) and text != "" <-
           {:written, Imp.get(prediction, :next_thought)},
         {:ok, parsed} <- Imp.Adapter.Chat.parse(signature, %{name => text}, []) do
      {:ok, Imp.Prediction.to_map(parsed)}
    else
      :submit -> {:none, :empty_tool_calls}
      {:written, _nothing} -> {:ok, %{hd(signature.outputs).name => nil}}
      {:error, _reason} -> {:none, :invalid_answer}
    end
  end

  defp text_output(signature),
    do: if(single_text_output?(signature), do: {:text, signature.outputs}, else: :submit)

  defp single_text_output?(%Imp.Signature{outputs: [%Imp.Signature.Field{type: type}]}),
    do: type in [:string, "string"]

  defp single_text_output?(_signature), do: false

  defp execute_call(
         _react,
         %ToolCall{name: @malformed_tool_call, arguments: %{received: received}},
         _execution
       ),
       do: {{:error, {:malformed_tool_call, received}}, true, :refused}

  defp execute_call(react, %ToolCall{name: requested, arguments: arguments} = call, execution) do
    name = Imp.Tool.resolve_name(react.tools, requested)
    arguments = Imp.Tool.normalize_arguments(arguments)

    cond do
      is_nil(name) ->
        {{:error, {:unknown_tool, requested}}, true, :refused}

      true ->
        tool = Map.fetch!(react.tools, name)

        with :ok <- Imp.ToolPolicy.authorize(react.tool_policy, name, arguments),
             :ok <- Imp.Tool.validate_input(tool, arguments) do
          authorize_and_call(react, tool, call, arguments, execution)
        else
          {:error, reason} -> {{:error, reason}, true, :refused}
        end
    end
  end

  defp malformed_call?(%ToolCall{name: @malformed_tool_call}), do: true
  defp malformed_call?(%ToolCall{}), do: false

  defp authorize_and_call(react, %{name: :submit}, _call, arguments, _execution) do
    {result, error?} = validate_submit(react.signature, arguments)
    {result, error?, if(error?, do: :refused, else: :result)}
  end

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
        {{:error, {:tool_authorization_denied, tool.name, Imp.Redaction.redact(reason)}}, true,
         :refused}

      {:cancel, reason} ->
        {:cancel, reason}
    end
  end

  defp safe_tool_call(tool, arguments) do
    case Imp.Tool.call(tool, arguments) do
      {:error, _reason} = error -> {error, true, Imp.Tool.outcome(error)}
      result -> {result, false, :result}
    end
  rescue
    error -> {{:error, {:tool_error, tool.name, error}}, true, :unknown}
  catch
    kind, reason -> {{:error, {:tool_error, tool.name, {kind, reason}}}, true, :unknown}
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
    # Opaque signatures and reasoning blocks may resemble credentials. Preserve
    # the provider's continuation state exactly; Run events redact their copies.
    |> maybe_put(:reasoning_content, Map.get(prediction.metadata, :native_reasoning))
    |> maybe_put(:reasoning_details, Map.get(prediction.metadata, :reasoning_details))
  end

  # The prediction's fields are the signature's outputs and nothing else, so
  # an output may take any name; how the turn went is metadata.
  defp final_prediction(outputs, history, reason, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.merge(%{history: history.full, termination_reason: reason})
      |> projection_metadata(history)

    {:ok, Imp.Prediction.new(outputs, metadata: metadata)}
  end

  defp incomplete_prediction(history, cause, error) do
    metadata = %{termination_cause: cause}

    metadata =
      if error,
        do: Map.put(metadata, :termination_error, Imp.Redaction.redact(error)),
        else: metadata

    final_prediction(%{}, history, :incomplete, metadata)
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

  defp interruption(%Imp.LMError{context_window_exceeded: true}), do: :context_window_exceeded
  defp interruption(%Imp.AdapterParseError{}), do: :parse_error
  defp interruption(_reason), do: :prediction_error

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
        if Imp.Errors.context_window_exceeded?(reason) do
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

            # Still the provider's refusal, so it keeps the provider's status;
            # the reason says why no shorter history could be sent.
            {:error,
             %Imp.LMError{
               message: "ReActV2 context cannot be reduced safely",
               status: context_status(reason),
               context_window_exceeded: true,
               reason: %{diagnostic: diagnostic, cause: reason, projection: projection(context)}
             }, context}
          end
        else
          {:error, reason, context}
        end
    end
  end

  defp context_status({:error, reason}), do: context_status(reason)
  defp context_status({:lm_failed, _client, reason}), do: context_status(reason)
  defp context_status(%Imp.LMError{status: status}), do: status
  defp context_status(_reason), do: nil

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
  # tool that ends the turn, so a renderer never has to know its name, and nil
  # when the signature has no `submit` and the answer is plain text. `outputs`
  # are the task's output fields, so each step says what every output means;
  # otherwise their descriptions reach the model only inside `submit`'s schema.
  defp guidance(signature, tools) do
    %{
      finish_tool: if(single_text_output?(signature), do: nil, else: :submit),
      input_names: Imp.Signature.input_names(signature),
      output_names: Imp.Signature.output_names(signature),
      outputs: signature.outputs,
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

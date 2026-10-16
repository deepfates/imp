defmodule Imp.Predict.ReActV2 do
  @moduledoc """
  Native-tool-aware ReAct loop with structured history and typed completion.

  ReActV2 preserves parallel tool call IDs and results in `Imp.History` and
  keeps unknown and failed tool calls as observations. Each recorded result
  carries `returned_at`, when it came back (ISO 8601, UTC), which the Chat
  adapter passes to a `:tool_result_renderer` with the call. Nothing shows it
  by default; a host that wants the model to know the time during a turn
  renders it there.

  ## Which signatures get `submit`

  A task signature with exactly one output of type `:string` and no
  constraints has an answer that the model can write as text, so its loop
  offers no `submit` tool. Every other signature (several outputs, one
  output that is not text, or one text output with constraints such as an
  `enum`, whose allowed values reach the model in `submit`'s schema) gets
  the reserved `submit` tool, whose parameters are the signature's outputs,
  exactly as DSPy's ReActV2 has it. The name `submit` is reserved for every
  signature, so a user tool cannot take it.

  `finish: :submit` gives the one-text-output signature `submit` too, and its
  turn then ends only through `submit`: a step that writes text and calls no
  tool is a thought, not the answer. It is for a program whose model writes
  text it does not mean as the answer, such as a sentence about what it will
  do next, or a report of what it did. Under `finish: :submit` a thought-only
  step is followed by an ordinary step (every tool, `tool_choice: "auto"`),
  in which the thought stays the model's own message and a user message
  after it says "Your message above was not sent. To reply, call `submit`
  with `answer`; to keep working, call a tool." (naming the signature's
  outputs), so the model can do what it announced or submit what it wrote; a second thought-only step in a row,
  or a step that says nothing, is the `:empty_tool_calls` interruption and
  the forced `submit` follows. Every other signature with `submit` keeps
  DSPy's ending: its first thought-only step is that interruption. The
  default, `finish: :auto`, leaves the choice to the signature.

  `finish: :tools` is for a program that acts only through tools: its turn
  ends only through a `finish_on` tool. There is no `submit`, and the outputs
  come from the `finish_on` functions. A thought-only step is followed by one
  ordinary step, as under `:submit`, with a line naming the ending tools
  (`unsent_note:` replaces it). Nothing is forced and no last request is
  made. A step whose request fails gets one more ordinary step, once per turn
  (there is no last request to absorb a transient failure). A second
  thought-only step in a row, a step that says nothing, the step limit or a
  second failure ends the turn `:incomplete` with that cause, or
  `:deadline_exceeded` when the deadline has passed. A program with
  `finish: :tools` needs a `finish_on` tool, and refuses `last_request_note`
  and `last_request_tools`, which it would never use. Its context recovery
  (a full window) has no answer steps to mark episodes, so it can only drop
  the whole history.

  `history_replay: :actions` shows the steps of earlier turns without the
  text and reasoning written beside their calls, and leaves out steps that
  only wrote text; a step that carries the task's outputs (an answer) is shown
  whole. The current turn is shown whole: it starts with the call's new
  inputs, or, on a call without them, at the last step that carries inputs.
  DeepSeek accepts earlier turns without `reasoning_content`; Anthropic and
  Gemini do not validate reasoning on earlier turns. Some thinking APIs reject
  an earlier tool-call message without its reasoning content (Kimi-style
  thinking modes); Kimi K3 through OpenRouter accepted one in a probe
  (2026-10-17), but check the provider before relying on it.

  ## The prediction

  The prediction's fields are the signature's outputs and nothing else, so an
  output may be called anything, `history` included. How the turn went is in
  its metadata:

    * `:history` — the turn's full `Imp.History`, to pass back as the
      `:history` input of the next call.
    * `:termination_reason` — how the turn ended (below).
    * `:termination_cause` — present whenever the turn was interrupted: for
      `:last_text`, `:forced_submit` and `:extracted`, and for
      `:finished_by_tool` when a `finish_on` hook ended the turn in the last
      request, the interruption that led to the last request. For `:incomplete`, the same interruption, unless
      the turn's context window was full or its `Imp.Deadline` had passed,
      which would refuse any further request too and so are named instead;
      `termination_error` holds the errors of the requests that failed. One of `:max_iters`, `:parse_error`, `:prediction_error`,
      `:empty_tool_calls`, `:context_window_exceeded` and `:deadline_exceeded`.
    * `:termination_error` — for `:incomplete`, the redacted errors of the
      requests that failed.
    * `:finished_by_tool` — the terminal tool that ended the turn.
    * `:unexecuted_tool_calls` — tool calls the last request made that were
      not run.
    * `:context_projection` — how many prior episodes were left out of a
      request (see below).
    * `:finish_reason` — for a turn whose answer is a reply's text
      (`:answered`, `:last_text`), why the provider stopped that reply, as
      the LM client reports it in the result's provider metadata
      (`Imp.Clients.ReqLLM`: `:stop`, `:length`, ...). `:length` means the
      provider's output limit cut the answer short: the text is what was
      written before it. Absent when the client reports none.

  `Imp.Prediction.complete?/1` is false exactly when the reason is
  `:incomplete`.

  ## How a turn ends

    * `:answered` (one unconstrained text output, without `finish: :submit`).
      A step that says something and calls no tool is the answer, in that one
      request.
    * `:submit` (every other signature, and every program with
      `finish: :submit`). The model calls `submit` with the signature's
      outputs.
    * `:finished_by_tool`. `finish_on` maps a tool name to
      `fn arguments, result, inputs -> {:finish, outputs} | :continue end`. It
      runs after that tool's call executes, with the string-keyed arguments
      the tool received; `{:finish, outputs}` validates
      `outputs` against the signature exactly as a `submit` would and ends the
      turn, with `finished_by_tool` naming the tool. `:continue` leaves the
      loop running. When one step calls several terminal tools, the first in
      call order finishes the run; the rest still execute and are recorded,
      and a `submit` in the same step still wins. Outputs that fail validation
      are recorded as that call's result, the same error a bad `submit`
      records, and the loop continues.
    * `:last_text`, `:forced_submit`, `:extracted`. The turn was interrupted
      and its last request answered (below).
    * `:incomplete`. The turn was interrupted and has no answer: its last
      request was answered with no valid answer in it, or the turn ran out of
      time or context window, or, under `finish: :tools`, it ended without a
      `finish_on` tool.

  A turn that could not get a model response returns
  `{:error, %Imp.Predict.ReActV2.StepError{}}` rather than a prediction: its
  last request failed with an `Imp.LMError`, a step's request was stopped by
  the provider's content filter (`Imp.LMError` with `content_filtered: true`;
  sending it again would be filtered and billed again, so no last request is
  made, as DSPy makes none after a step's LM error), its LM client raised
  (`{:lm_failed, client, exception}`), or a renderer raised
  (`{:adapter_format_failed, adapter, exception}`). The error's `:reason` is
  that request's error as `Imp.Predict` returns it, which `Imp.Errors`
  classifies through the struct, and its `:history` is the turn's history as
  far as it got, with every tool call that ran and its result. A step that
  fails with an `Imp.OperationalSafetyError` (a route, cost, transport or
  budget guard) ends the turn the same way at once, with no last request. A
  tool call whose outcome is unknown is not such a failure: it is an
  observation, and the turn goes on.

  ## When a turn is interrupted

  A turn is interrupted when it reaches `max_iters`, when a step's request
  fails (`:prediction_error`, `:parse_error`) other than by the content
  filter, or when a step of a signature
  with `submit` calls no tool (`:empty_tool_calls`; under `finish: :submit`,
  the second such step in a row, see above). An `enum` output is such a
  signature: text that is not a `submit` call is `:empty_tool_calls`, never
  an answer, and a turn with no valid `submit`, the forced one included, ends
  `:incomplete`.

  With one unconstrained text output, a step that calls no tool and says nothing is not an
  interruption: it is an empty answer, and the turn ends there
  (`:answered`). Saying nothing is how a model declines to answer, and asking
  it again would make declining cost a second request.

  With one unconstrained text output, every interruption takes the same path: one more
  request, and its text is the answer (`:last_text`).
  The request is a step like any other: the same tools and the same
  `tool_choice: "auto"`. A provider may refuse a history of tool calls when no
  tools are declared (Anthropic does), and a changed roster changes the prompt
  prefix a provider caches. It does not say `tool_choice: "none"`: a model told
  that while it wants a tool can write the call as text in its own tool markup
  (seen from inkling through OpenRouter, and through DeepInfra),
  and that text would become the answer. If the model calls a tool, the call
  is not run unless `:last_request_tools` names that tool (below); the
  completion's text, if any, is the answer, and the calls not run are kept in
  `unexecuted_tool_calls`. A completion that says nothing is an empty
  answer rather than an error. If the process's `Imp.Deadline` has already
  passed, no request is made and the turn is `:incomplete` with
  `termination_cause: :deadline_exceeded`.

  `:last_request_tools` names tools whose calls that request does run. It is
  for a program that acts through a tool (it publishes, sends or records
  something) and whose text only reports what it did: an interruption, a
  single provider error among them, would otherwise cost it the action it was
  about to take. Calls to those tools run as a step's calls do, under the
  same tool policy and run authorization, with the same `:tool_call` and
  `:tool_result` events, and the request is recorded in the history with
  their results. The turn then ends with the request's text as the answer
  (`:last_text`); calls to any other tool are not run and are listed in
  `unexecuted_tool_calls`. If a listed call meets a `finish_on` hook that
  returns `{:finish, outputs}`, the turn ends with those outputs
  (`:finished_by_tool`), as it would after any step. DSPy's ReActV2 makes
  the same allowance for its terminal tool: the forced last request may call
  `submit`, and that call runs. The default, `[]`, runs nothing.

  With `submit`, an interruption forces one more request with `tool_choice`
  naming `submit` (`:forced_submit`), as DSPy does, unless the process's
  `Imp.Deadline` has already passed (`:incomplete`, `:deadline_exceeded`).
  If a provider cannot honor that tool contract, a tools-disabled typed
  extractor derives the task outputs from the original inputs and
  accumulated history (`:extracted`), and the outputs are appended to the
  history as a step that called no tool.

  The last request says nothing about why it is being made unless
  `:last_request_note` is given: one line of host text put in front of it as a
  user message and kept in the returned history like any other turn. It is
  recorded as a step that said nothing and called nothing, so it renders as
  that user message alone, with no assistant reply after it, in the request and
  whenever the history is passed back. Imp writes no sentence of its own
  there, except that under `finish: :submit` each earlier thought-only step
  in the history keeps the unsent note after it (see "Which signatures get
  `submit`").

  ## Per-call options

  A call may give `max_iters`, `last_request_note`, `last_request_tools`,
  `config` and `tools` beside its inputs, under atom or string keys. Each
  applies to that call only and is not an input field. `max_iters`,
  `last_request_note` and `last_request_tools` replace the program's own;
  `max_iters` is a non-negative integer, `last_request_note` a string or
  `nil`, and `last_request_tools` a list of tools the program holds, checked
  as the program's own list is. `config` is a keyword list of
  request options merged over the program's `:config` for every request of
  the call, such as `max_tokens: 4_000`; it may not name `:tools` or
  `:tool_choice`, which the loop chooses on each step. `tools` is a list of
  `Imp.Tool`s that the program holds, each the program's own in name,
  description and schema, whose runners the call uses in place of the
  program's: the request is unchanged, and only what a call to those tools
  does is the call's. `finish` (`:auto`, `:submit` or `:tools`) replaces the
  program's ending for the call, as `new/3` would build it; it is an option
  only when the task has no input named `finish`, which is then that input.
  Any other value is refused before a model is called.

  Together they continue a conversation the caller holds. A call with a
  `:history`, `max_iters: 0` and a note makes one request, the last request:
  the loop's own system message, tools and history, then the note, with
  `tool_choice: "auto"`. No tool runs, except one named in
  `:last_request_tools`, and the reply's text is the answer
  (`termination_reason: :last_text`). This is how a host asks a model about
  a conversation it has had, as that model saw it, for instance for a summary
  of it before the history is shortened. Codex CLI and Anthropic's SDK
  compaction build that request the same way: the conversation's own
  messages, then one instruction. The call's `config` gives that request
  its own options, an output budget for instance, and the prediction's
  `:finish_reason` says whether the reply was cut short by it.

  That request is a last request, so a program's `last_request_tools` run in
  it. A summary is not the place for a program's actions: a host asking for
  one gives `last_request_tools: []` with the call, and a call to such a tool
  in that request is not run but listed in `unexecuted_tool_calls`.

  A request refused because the context window is full is not an
  interruption of this kind: a further request would be refused the same way,
  so the turn ends at once as `:incomplete` with `termination_cause:
  :context_window_exceeded` (see below).

  For a single unconstrained text output, a step describes that task field
  directly, including its description. Other signatures use `next_thought`
  alongside the typed `submit` tool. The other step output is `tool_calls`
  (`agent_tool_calls` when the task text output itself is named `tool_calls`).
  The provider holds the tool roster natively. Plain text with no tool call
  fills the declared text field through the step signature's `:text_field`
  metadata. It completes the text task in one LM call and is appended to the
  history as its own step. A tool call the model writes as
  JSON rather than calling natively is accepted with `tool` for `name` and
  `args` or `parameters` for `arguments` (`Imp.Adapter.Types.ToolCall`); a map
  that names no tool at all is kept as a malformed-call observation.

  So a step asks for one thing, whichever adapter formats it. The step has a
  `tools` input, the roster as text in DSPy's shape ("name, whose description
  is <desc>...</desc>. It takes arguments {...}.", the arguments being the
  schema's properties, `required` and `$defs` as JSON, the properties in the
  schema's order when it keeps one and by name otherwise), and a `tool_calls`
  output whose description shows how to write a call.
  When the LM calls tools natively (every LM unless its client says
  otherwise; `Imp.Clients.ReqLLM` asks the model registry), the tools are sent
  natively and `Imp.Predict` formats the step without both fields, in every
  adapter and in the JSON fallback: the model answers with tool calls or with
  text. When the LM cannot (the registry says the model has no tool calling,
  or the LM is `Imp.Clients.TRLLM`), no tools are sent: the step lists them in
  `tools`, the model writes its calls in `tool_calls`, and earlier steps are
  replayed as text (the step's fields, then the results), never as native
  tool messages. This is DSPy's structure. The guidance says where a text
  answer goes: in the task text field, with `tool_calls` left empty when that
  field is described. With native tool calls the Chat adapter asks for no
  field markers at all: its system message lays out the inputs alone and says
  the message without a tool call is the answer. A reply in plain text, or in
  markers, is read as that field by `Imp.Adapter.Chat`. Durable step history keeps
  `next_thought` and `tool_calls` for compatibility with saved conversations;
  adapters project them into the declared fields when rendering. A stored turn that
  carries a one-text-output task's answer and no step outputs is replayed as
  a step that answered in text. The name `tools` is reserved: a task
  signature cannot have a field of that name.

  On a recognized context-window refusal, up to eight smaller requests omit
  oldest prior episodes from the prompt, preserving their full durable history.
  Completed signature outputs delimit episodes; a trailing unfinished prior
  group is kept together. Current-call tool observations are never omitted or
  replayed. Omission counts appear in `:context_projection` and native
  `:context_projected` events. If the current call and instructions alone exceed
  the window, an incomplete prediction retains history and context diagnostics.
  This is lossy prompt selection, not summarization or deletion of memory.

  Tool history is the conversation the model reads: it keeps each input, tool
  call and tool result as it was, and provider-native reasoning text and opaque
  reasoning details for continuation, including after `Imp.History.dump/1` and
  `Imp.History.load!/1`. Store history privately; use redacted events or
  `Imp.History.redact/1` for diagnostic copies.
  """

  @behaviour Imp.Module

  alias Imp.Adapter.Types.{ToolCall, ToolCalls, ToolResult}
  alias Imp.Predict.ReActV2.StepError

  @malformed_tool_call "__imp_malformed_tool_call__"

  defstruct [
    :signature,
    :react,
    :last_request_note,
    tools: %{},
    tool_order: [],
    max_iters: 20,
    tool_policy: :allow,
    finish_on: %{},
    finish: :auto,
    unsent_note: nil,
    history_replay: :trajectory,
    last_request_tools: []
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
      doc: "Worked examples for the step predictor, as for `Imp.Predict`."
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
          "injects its renderers here, such as `Imp.Adapter.Chat`'s `:system_renderer`, " <>
          "and its own `:agent_line` (the guidance's \"You are an Agent...\" line; a " <>
          "string replaces it, nil leaves it out)."
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
          "forced `submit`, or, for a signature with one unconstrained text output, one last " <>
          "request whose text is the answer."
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
          "turn, as a user message, and kept in the history: the last " <>
          "request for a signature with one unconstrained text output, the forced `submit` for " <>
          "every other. `nil` says nothing; Imp writes no sentence of its own, " <>
          "except the unsent note after earlier thought-only steps under `finish: :submit`."
    ],
    finish_on: [
      type: {:custom, __MODULE__, :validate_finish_on, []},
      default: %{},
      doc:
        "Tools whose call ends the turn: a map from tool name to " <>
          "`fn arguments, result, inputs -> {:finish, outputs} | :continue end`. " <>
          "See \"How a turn ends\" above."
    ],
    finish: [
      type: {:in, [:auto, :submit, :tools]},
      default: :auto,
      doc:
        "How the model ends its turn. `:auto` lets the signature decide: one " <>
          "unconstrained text output ends on plain text, every other signature through " <>
          "`submit`. `:submit` ends every turn through `submit`, as DSPy's ReActV2 does, " <>
          "so a step that writes text and calls no tool is a thought, not the answer; " <>
          "the next step continues with every tool, and a second such step in a row " <>
          "forces `submit`. `:tools` ends a turn only through a `finish_on` tool: text " <>
          "without a tool call is a thought as under `:submit`, there is no `submit`, and " <>
          "a second such step in a row, the step limit or a failed step ends the turn " <>
          "`:incomplete`, with no further request. " <>
          "See \"Which signatures get `submit`\" above."
    ],
    unsent_note: [
      type: {:or, [:string, nil]},
      default: nil,
      doc:
        "The line shown after each thought-only step, in place of Imp's: under " <>
          "`finish: :submit` and `:tools`, and on a plain-text loop's replay of a history " <>
          "written under `:submit`. A blank line is refused."
    ],
    history_replay: [
      type: {:in, [:trajectory, :actions]},
      default: :trajectory,
      doc:
        "How the steps of earlier turns in a `history` are shown to the model. " <>
          "`:trajectory` shows them whole, as DSPy's ReActV2 does. `:actions` leaves out " <>
          "the text and reasoning each earlier step wrote beside its calls, and drops a " <>
          "step that only wrote text: earlier turns read as their inputs, the calls made " <>
          "with their results, and the outputs. The current turn is always whole, and the " <>
          "history the prediction returns keeps everything."
    ],
    last_request_tools: [
      type: {:list, {:or, [:atom, :string]}},
      default: [],
      doc:
        "Tools whose calls run in the last request of an interrupted turn, for a " <>
          "signature with one unconstrained text output (`:last_text`). Calls to them " <>
          "are executed and recorded as any step's calls are, and the turn then ends " <>
          "with that request's text as the answer; calls to any other tool are not run " <>
          "and are listed in `unexecuted_tool_calls`. For a program that acts through " <>
          "a tool and whose text only reports what it did. Each name must be a tool " <>
          "the program holds. See \"When a turn is interrupted\" above."
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

    opts =
      Imp.Predict.Options.validate!(opts, @option_schema, "Imp.Predict.ReActV2.new/3")

    tool_order = declared_order(tools)
    tools = Imp.Tool.index_tools!(tools, "Imp.Predict.ReActV2.new/3")

    if Imp.Tool.resolve_name(tools, :submit) do
      raise ArgumentError, "submit is reserved by Imp.Predict.ReActV2"
    end

    reject_reserved_tools!(signature, "Imp.Predict.ReActV2.new/3")
    validate_tools_finish!(opts[:finish], opts[:finish_on], "Imp.Predict.ReActV2.new/3")
    validate_tools_last_request!(opts, "Imp.Predict.ReActV2.new/3")
    validate_unsent_note!(opts[:unsent_note], "Imp.Predict.ReActV2.new/3")

    tools = put_submit(tools, signature, opts[:finish])

    react_signature =
      %Imp.Signature{
        inputs:
          Enum.map(signature.inputs, &Imp.Signature.Field.optional/1) ++
            [Imp.Signature.Field.new(%{name: :history, type: :history}, :input), tools_field()],
        outputs: step_outputs(signature, opts[:finish]),
        instructions: signature.instructions,
        # A step answered in plain text, with no native tool call, is a
        # thought that called nothing. `Imp.Adapter.Chat` reads a marker-free
        # completion as the declared text field, and the calls field takes its declared
        # default of none, which ends the turn: as the answer when the
        # signature has one text output, and at the forced submit otherwise.
        metadata: step_metadata(signature, opts[:finish])
      }

    config = Keyword.merge(opts[:config], provider_tool_config(tools, tool_order, signature))

    # The roster goes to the provider once, natively, in `config`, and the
    # loop's guidance goes to the adapter as data. For an LM that calls tools
    # natively, `Imp.Predict` leaves the `tools` input and `tool_calls` output
    # out of the prompt, so a step's request is the previous step's request
    # plus the newest exchange, which is what a provider's prompt cache is
    # keyed on. For an LM that cannot, the roster is the `tools` input, as text.
    adapter_opts =
      Keyword.merge(
        Keyword.get(opts, :adapter_opts, []),
        loop_adapter_opts(signature, tools, opts[:finish], opts[:unsent_note], opts[:finish_on])
      )

    %__MODULE__{
      signature: signature,
      react:
        Imp.Predict.new(
          react_signature,
          opts
          |> Imp.Predict.Options.take()
          |> Keyword.merge(config: config, adapter_opts: adapter_opts)
        ),
      tools: tools,
      tool_order: tool_order,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy],
      last_request_note: opts[:last_request_note],
      finish_on: resolve_finish_on!(opts[:finish_on], tools),
      finish: opts[:finish],
      unsent_note: opts[:unsent_note],
      history_replay: opts[:history_replay],
      last_request_tools:
        resolve_last_request_tools!(
          opts[:last_request_tools],
          tools,
          plain_text?(signature, opts[:finish])
        )
    }
  end

  @doc false
  # Adds the reserved `submit` tool when the signature has one. Loading a saved
  # program goes through here too, so the rule lives in one place.
  #
  # Divergence from DSPy's ReActV2, which offers `submit` for every signature:
  # a signature with one unconstrained text output gets none. Its answer is the text the
  # model writes when it stops calling tools, which is how every other
  # mainstream tool loop ends a turn, and a `submit` beside that would be a
  # second way to say the same thing. DSPy needs `submit` because a signature
  # can have several typed outputs, and those signatures still get it.
  # `finish: :submit` gives that signature `submit` as well, as DSPy does.
  def put_submit(tools, signature, finish \\ :auto) do
    if plain_text?(signature, finish) or finish == :tools,
      do: tools,
      else:
        Map.put(
          tools,
          :submit,
          Imp.Tool.new(:submit, "Submit the final outputs for the task.", & &1)
        )
  end

  # `finish: :tools` ends a turn only through a `finish_on` tool, so a loop
  # with none could never end but by interruption.
  defp validate_tools_finish!(:tools, finish_on, context) when finish_on == %{},
    do:
      raise(
        ArgumentError,
        "#{context}: finish: :tools needs at least one finish_on tool to end a turn"
      )

  defp validate_tools_finish!(_finish, _finish_on, _context), do: :ok

  @doc false
  # Shared with `Imp.Saving`, so a loaded program is held to the same rules.
  def validate_tools_program!(%__MODULE__{} = react, context) do
    validate_tools_finish!(react.finish, react.finish_on, context)

    validate_tools_last_request!(
      [
        finish: react.finish,
        last_request_note: react.last_request_note,
        last_request_tools: react.last_request_tools
      ],
      context
    )

    validate_unsent_note!(react.unsent_note, context)
    react
  end

  defp validate_tools_last_request!(opts, context) do
    if opts[:finish] == :tools and
         (is_binary(opts[:last_request_note]) or (opts[:last_request_tools] || []) != []),
       do: raise(ArgumentError, "#{context}: " <> tools_last_request_reason())

    :ok
  end

  # An empty line would be sent as an empty user message.
  defp validate_unsent_note!(note, context) when is_binary(note) do
    if String.trim(note) == "",
      do: raise(ArgumentError, "#{context}: unsent_note must say something, or be left out")

    :ok
  end

  defp validate_unsent_note!(_note, _context), do: :ok

  # A call's own `finish`, for one call: the loop as `new/3` would build it with
  # that ending, from the same tools and options.
  defp with_finish(%__MODULE__{finish: finish} = react, finish), do: {:ok, react}

  defp with_finish(%__MODULE__{finish_on: finish_on}, :tools) when finish_on == %{},
    do: {:error, {:invalid_react_v2_finish, "finish: :tools needs at least one finish_on tool"}}

  defp with_finish(%__MODULE__{} = react, :tools)
       when react.last_request_tools != [] or is_binary(react.last_request_note),
       do: {:error, {:invalid_react_v2_finish, tools_last_request_reason()}}

  defp with_finish(%__MODULE__{} = react, finish) do
    tools = react.tools |> Map.delete(:submit) |> put_submit(react.signature, finish)
    {:ok, restore_loop(%{react | finish: finish, tools: tools})}
  end

  # `finish` is a call option unless the task has an input of that name, which
  # is then the input, as it was before the option existed.
  defp pop_call_finish(inputs, react) do
    if Enum.any?(react.signature.inputs, &Imp.FieldMap.same_name?(&1.name, :finish)),
      do: {react.finish, inputs},
      else: pop_call_option(inputs, :finish, react.finish)
  end

  defp tools_last_request_reason,
    do:
      "finish: :tools makes no last request (an interrupted turn ends :incomplete), so " <>
        "last_request_note and last_request_tools would never be used"

  defp validate_tools_call_note(:tools, note) when is_binary(note),
    do: {:error, {:invalid_react_v2_last_request_note, tools_last_request_reason()}}

  defp validate_tools_call_note(_finish, _note), do: :ok

  defp validate_call_finish(finish) when finish in [:auto, :submit, :tools], do: :ok

  defp validate_call_finish(finish),
    do: {:error, {:invalid_react_v2_finish, finish}}

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

  # Names are normalized to the tools' own, as `finish_on` keys are. Only the
  # last text request reads the list; a signature with `submit` ends an
  # interrupted turn with the forced `submit`, which runs nothing else, so a
  # list there would never be used and is refused rather than ignored.
  defp resolve_last_request_tools!(names, tools, plain_text?) do
    case resolve_last_request_tools(names, tools, plain_text?) do
      {:ok, resolved} -> resolved
      {:error, message} -> raise ArgumentError, "Imp.Predict.ReActV2.new/3: " <> message
    end
  end

  defp resolve_last_request_tools([], _tools, _plain_text?), do: {:ok, []}

  defp resolve_last_request_tools(names, tools, plain_text?) when is_list(names) do
    cond do
      not plain_text? ->
        {:error,
         ":last_request_tools applies only to a turn that ends in plain text (one " <>
           "unconstrained text output, without finish: :submit); this one ends an " <>
           "interrupted turn with submit"}

      not Enum.all?(names, &(is_atom(&1) or is_binary(&1))) ->
        {:error, ":last_request_tools expects tool names, got: #{inspect(names)}"}

      true ->
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
          case Imp.Tool.resolve_name(tools, name) do
            nil -> {:halt, {:error, ":last_request_tools names no tool: #{name}"}}
            resolved -> {:cont, {:ok, acc ++ [to_string(resolved)]}}
          end
        end)
        |> then(fn
          {:ok, resolved} -> {:ok, Enum.uniq(resolved)}
          error -> error
        end)
    end
  end

  defp resolve_last_request_tools(other, _tools, _plain_text?),
    do: {:error, ":last_request_tools expects a list of tool names, got: #{inspect(other)}"}

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

  # What the loop itself tells the adapter: its guidance, and a request shape
  # that ends on the newest exchange with no response instruction.
  defp loop_adapter_opts(signature, tools, finish, unsent_note, finish_on),
    do: [
      guidance: guidance(signature, tools, finish, unsent_note, finish_on),
      response_instruction: false,
      omit_empty_request: true
    ]

  @doc false
  # The step predictor's loop-owned parts, derived from the task signature and
  # tools: the provider tool roster, the adapter guidance and request shape, and
  # which output a text reply fills. A saved program does not carry them, and
  # `Imp.Saving` rebuilds them here, so a loaded agent asks the model what the
  # agent it was saved from asked. A host's own `:adapter_opts` (renderers are
  # functions) are not saved; the host passes them again.
  def restore_loop(%__MODULE__{react: react} = agent) do
    reject_reserved_tools!(agent.signature, "loading a ReActV2 program")

    metadata =
      react.signature.metadata
      |> Map.drop(["text_field", "tool_calls_field", "tools_field"])
      |> Map.merge(step_metadata(agent.signature, agent.finish))

    # A program saved before the step had a `tools` input gets one, so it
    # describes its tools to an LM that cannot call them natively.
    inputs =
      if Enum.any?(react.signature.inputs, &Imp.FieldMap.same_name?(&1.name, :tools)),
        do: react.signature.inputs,
        else: react.signature.inputs ++ [tools_field()]

    react = %{
      react
      | config:
          Keyword.merge(
            react.config,
            provider_tool_config(agent.tools, agent.tool_order, agent.signature)
          ),
        adapter_opts:
          Keyword.merge(
            react.adapter_opts,
            loop_adapter_opts(
              agent.signature,
              agent.tools,
              agent.finish,
              agent.unsent_note,
              agent.finish_on
            )
          ),
        signature: %{
          react.signature
          | metadata: metadata,
            inputs: inputs,
            outputs: step_outputs(agent.signature, agent.finish)
        }
    }

    %{agent | react: react}
  end

  @doc false
  def with_tools(%__MODULE__{} = agent, tools) when is_map(tools) do
    tools = validate_updated_tools!(agent.tools, tools)

    react = %{
      agent.react
      | config:
          Keyword.merge(
            agent.react.config,
            provider_tool_config(tools, agent.tool_order, agent.signature)
          ),
        adapter_opts:
          Keyword.put(
            agent.react.adapter_opts,
            :guidance,
            guidance(agent.signature, tools, agent.finish, agent.unsent_note, agent.finish_on)
          )
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
         {finish, inputs} <- pop_call_finish(inputs, react),
         :ok <- validate_call_finish(finish),
         {:ok, react} <- with_finish(react, finish),
         {max_iters, inputs} <- pop_max_iters(inputs, react.max_iters),
         :ok <- validate_call_max_iters(max_iters),
         {note, inputs} <- pop_call_option(inputs, :last_request_note, react.last_request_note),
         :ok <- validate_call_note(note),
         :ok <- validate_tools_call_note(react.finish, note),
         {config, inputs} <- pop_call_option(inputs, :config, []),
         :ok <- validate_call_config(config),
         {tools, inputs} <- pop_call_option(inputs, :tools, []),
         {:ok, tools} <- call_tools(react.tools, tools),
         {:ok, last_request_tools, inputs} <- call_last_request_tools(react, inputs),
         {:ok, history} <- coerce_history(Map.get(inputs, :history, Map.get(inputs, "history"))) do
      react = %{
        react
        | tools: tools,
          last_request_note: note,
          last_request_tools: last_request_tools,
          react: %{react.react | config: Keyword.merge(react.react.config, config)}
      }

      # ReActV2 filters inputs down to signature names before any Predict call,
      # so extra keys would vanish silently here; warn at this boundary the same
      # way Imp.Predict does (:history is a documented call-time key).
      :ok = Imp.Predict.warn_extra_inputs(react.signature, inputs, [:history])

      pending =
        react.signature
        |> Imp.Signature.input_names()
        |> Map.new(fn name -> {name, fetch_input(inputs, name)} end)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      run(
        react,
        history_context(history, react.signature, react.history_replay, pending),
        pending,
        pending,
        0,
        max_iters,
        execution,
        %{thoughts: 0, retried: false}
      )
    end
  end

  # `steps.thoughts` counts the thought-only steps since the last step that
  # called a tool (see `continue_after_thought?/3`); `steps.retried` whether a
  # `finish: :tools` turn has spent its one retry of a failed request.
  defp run(react, history, inputs, pending, turn, max_iters, execution, _thoughts)
       when turn >= max_iters,
       do: interrupted(react, history, inputs, pending, :max_iters, turn, nil, execution)

  defp run(react, history, inputs, pending, turn, max_iters, execution, thoughts) do
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
          case parse_text(react.signature, react.finish, prediction) do
            {:ok, outputs} ->
              # The model stopped calling tools and said its answer. That is the
              # end of the turn, and it costs no further request.
              history =
                append_history(history, history_event(pending, prediction, calls, [], outputs))

              final_prediction(outputs, history, :answered, finish_reason(%{}, prediction))

            {:none, cause} ->
              emit_reasoning(prediction, turn)
              {history, pending} = append_thought_only_step(history, pending, prediction, calls)

              if continue_after_thought?(react, prediction, thoughts.thoughts),
                do:
                  run(
                    react,
                    history,
                    inputs,
                    pending,
                    turn + 1,
                    max_iters,
                    execution,
                    %{thoughts | thoughts: thoughts.thoughts + 1}
                  ),
                else: interrupted(react, history, inputs, pending, cause, turn, nil, execution)
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
                  run(react, history, inputs, %{}, turn + 1, max_iters, execution, %{
                    thoughts
                    | thoughts: 0
                  })
              end
          end
        end

      # DSPy's ReActV2 raises a step's LM error at once. Here a failed step
      # interrupts the turn like any other interruption, so its last request
      # is also one more try at a model response after a transient failure,
      # which a host that answers every turn relies on. The call fails only
      # when that request gets no response either (`last_request_failed/4`).
      # A request the content filter stopped is not transient: the last
      # request would carry the same history, be filtered again and be billed
      # again, so the turn fails at once, as in DSPy. An operational safety
      # guard (route, cost, transport, budget) is fatal, as
      # `Imp.OperationalSafetyError` requires: a further request would pass
      # the guard by, so the turn stops here.
      {:error, reason, history} ->
        cond do
          safety_error?(reason) ->
            step_error(history, reason)

          Imp.Errors.context_window_exceeded?(reason) ->
            incomplete_prediction(history, :context_window_exceeded, reason)

          match?(%Imp.LMError{content_filtered: true}, reason) ->
            step_error(history, reason)

          # Under `finish: :tools` there is no last request to absorb a
          # transient failure, so the turn gets one more ordinary step, once.
          react.finish == :tools and not thoughts.retried and not deadline_passed?() ->
            run(react, history, inputs, pending, turn + 1, max_iters, execution, %{
              thoughts
              | retried: true
            })

          true ->
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

  # Under `finish: :submit`, a step that wrote a thought and called nothing is
  # followed by an ordinary step, not at once by the forced `submit`: the
  # same tools and `tool_choice: "auto"`, with the thought as the model's own
  # message and the unsent note after it (`guidance/3`; with written tool
  # calls the request then ends on the tool listing). Forcing at once
  # took every other tool away from a model that had just said what it would
  # do next, and made a request that, if it failed, lost the reply the thought
  # held. Measured on real final steps across 11 models (decisions.md, row of
  # 2026-10-16), most models then called `submit` with the thought's reply, or
  # went on with the work they had announced; about one in eight wrote text
  # again. So one such step continues, and a second in a row is the
  # `:empty_tool_calls` interruption, as is a step that said nothing or only
  # whitespace (there is no thought to show, and the same request would be
  # sent again). `max_iters` still ends the turn with the forced `submit`; a
  # deadline that has passed sends no further request, continued or forced,
  # and the turn ends `:incomplete` (`:deadline_exceeded`). A signature that
  # has `submit` under `finish: :auto` keeps DSPy's ending, which forces at
  # once.
  @thought_steps_continued 1

  defp continue_after_thought?(%{finish: finish}, prediction, thoughts)
       when finish in [:submit, :tools] do
    thoughts < @thought_steps_continued and
      String.trim(to_string(Imp.get(prediction, :next_thought) || "")) != "" and
      not deadline_passed?()
  end

  defp continue_after_thought?(_react, _prediction, _thoughts), do: false

  # The one place an interrupted turn goes: the last request for a signature
  # with one text output, the forced submit for every other.
  # Under `finish: :tools` nothing ends the turn but a `finish_on` tool, and
  # nothing is forced: the turn ends `:incomplete`, with no further request,
  # and the host decides what that means.
  defp interrupted(
         %{finish: :tools},
         history,
         _inputs,
         _pending,
         cause,
         _turn,
         error,
         _execution
       ) do
    cause = if deadline_passed?(), do: :deadline_exceeded, else: cause
    incomplete_prediction(history, cause, error)
  end

  defp interrupted(react, history, inputs, pending, cause, turn, error, execution) do
    if plain_text?(react.signature, react.finish),
      do: last_text(react, history, inputs, pending, cause, turn, error, execution),
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
    # As for the last text request: a deadline that has already passed
    # leaves no time for the forced `submit`, so none is made.
    if deadline_passed?() do
      incomplete_prediction(history, :deadline_exceeded, initial_error)
    else
      forced_submit_request(
        react,
        history,
        inputs,
        pending,
        reason,
        turn,
        initial_error,
        execution
      )
    end
  end

  defp forced_submit_request(
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
        emit_reasoning(prediction, turn, forced: true)

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
        extract_final(react, inputs, pending, history, reason, %{
          initial: initial_error,
          forced_submit: forced_error
        })

      {:error, forced_error, history} ->
        last_request_failed(history, reason, forced_error, %{
          initial: initial_error,
          forced_submit: forced_error
        })
    end
  end

  # An interrupted turn of a signature with one text output. The last request
  # is an ordinary step, and its text is the single text output. A call to a
  # tool in `last_request_tools` runs as any step's call does (policy,
  # authorization, events, history), and a `finish_on` hook it meets may still
  # end the turn with its outputs. Any other call is not run, and is kept out
  # of the history, where it would replay as a call with no result; the
  # prediction names it in `unexecuted_tool_calls` instead. A completion that
  # says nothing is an empty answer: the run is over either way, and there is
  # nothing to force.
  # A deadline that has already passed leaves no time for that request, so
  # none is made.
  defp last_text(react, history, inputs, pending, cause, turn, initial_error, execution) do
    if deadline_passed?() do
      incomplete_prediction(history, :deadline_exceeded, initial_error)
    else
      {history, pending} = note_after_inputs(history, pending, react)

      case predict(react.react, react, history, pending) do
        {:ok, prediction, history} ->
          calls = prediction |> Imp.get(:tool_calls, []) |> normalize_calls(turn)
          {runnable, unexecuted} = split_last_request_calls(react, calls)
          outputs = last_text_outputs(react, prediction)
          metadata = %{termination_cause: cause} |> put_unexecuted(unexecuted)

          # The text is the answer, not a thought, so no `:reasoning` event
          # says it a second time.
          case execute_calls(react, runnable, execution, inputs) do
            {:cancel, reason} ->
              {:error, {:execution_cancelled, reason}}

            {results, _final, nil} ->
              history = append_last_step(history, pending, prediction, runnable, outputs, results)
              final_prediction(outputs, history, :last_text, finish_reason(metadata, prediction))

            {results, _final, {tool_name, finished}} ->
              # The outputs are the prediction's, not the step's, as after
              # any step a `finish_on` hook ends.
              event = history_event(pending, prediction, runnable, results, nil)

              final_prediction(
                finished,
                append_history(history, event),
                :finished_by_tool,
                Map.put(metadata, :finished_by_tool, tool_name)
              )
          end

        {:error, reason, history} ->
          last_request_failed(history, cause, reason, %{
            initial: initial_error,
            last_text: reason
          })
      end
    end
  end

  # The last request's calls the program lets run there, and the rest.
  defp split_last_request_calls(%{last_request_tools: []}, calls),
    do: {%ToolCalls{tool_calls: []}, calls}

  defp split_last_request_calls(react, %ToolCalls{tool_calls: calls}) do
    {runnable, unexecuted} =
      Enum.split_with(calls, fn call ->
        not malformed_call?(call) and
          case Imp.Tool.resolve_name(react.tools, call.name) do
            nil -> false
            name -> to_string(name) in react.last_request_tools
          end
      end)

    {%ToolCalls{tool_calls: runnable}, %ToolCalls{tool_calls: unexecuted}}
  end

  # The note is the last thing the model reads. Inputs no step has spent yet
  # (the first step failed) would otherwise render after it, so they go into
  # the history first, as the user turn they are.
  defp note_after_inputs(history, pending, %{last_request_note: note} = react)
       when is_binary(note) and note != "" and map_size(pending) > 0 do
    history = history |> append_user_turn(pending) |> append_note(react.signature, note)
    {history, %{}}
  end

  defp note_after_inputs(history, pending, react),
    do: {append_note(history, react.signature, react.last_request_note), pending}

  defp deadline_passed?, do: Imp.Deadline.expired?(Imp.Deadline.current())

  # How a turn ends whose last request failed. A turn out of time, or whose
  # context window is full, is incomplete: any further request would be
  # refused the same way, so that is what the caller has to change, and it is
  # named as the cause. A last request the model answered with something that
  # does not parse leaves the turn incomplete too, under the interruption that
  # led to it: the model responded and gave no answer. Any other failure means
  # the turn could not get a model response at all (the LM failed, its client
  # raised, a renderer raised, a safety guard refused it), so the call fails
  # with that request's error and the history so far (`StepError`). A safety
  # guard is named first: it is fatal whatever else is true of the turn.
  defp last_request_failed(history, interruption, error, termination_error) do
    cond do
      safety_error?(error) ->
        step_error(history, error)

      deadline_passed?() ->
        incomplete_prediction(history, :deadline_exceeded, termination_error)

      Imp.Errors.context_window_exceeded?(error) ->
        incomplete_prediction(history, :context_window_exceeded, termination_error)

      match?(%Imp.AdapterParseError{}, error) ->
        incomplete_prediction(history, interruption, termination_error)

      true ->
        step_error(history, error)
    end
  end

  # The history is the one a finished turn returns: every step that ran, with
  # the tools it called, which have happened and must not be forgotten.
  defp step_error(history, reason),
    do: {:error, StepError.exception(reason: reason, history: history.full)}

  defp safety_error?(reason), do: Imp.OperationalSafetyError.find(reason) != nil

  defp put_unexecuted(metadata, %ToolCalls{tool_calls: []}), do: metadata

  defp put_unexecuted(metadata, %ToolCalls{tool_calls: calls}) do
    unexecuted =
      Enum.map(calls, fn call ->
        %{id: call.id, name: call.name, arguments: Imp.Tool.normalize_arguments(call.arguments)}
      end)

    Map.put(metadata, :unexecuted_tool_calls, Imp.Redaction.redact(unexecuted))
  end

  # Only a signature with one unconstrained text output reaches the last
  # text request, and any text is its answer.
  defp last_text_outputs(react, prediction) do
    {:ok, outputs} = parse_text(react.signature, react.finish, prediction)
    outputs
  end

  # The note is what the model is told, so it goes into the durable history
  # rather than into one request: the record of the run carries it, and the
  # prompt renders it as the last user message before the last request.
  defp append_note(history, signature, text) when is_binary(text) and text != "" do
    case Imp.Signature.input_names(signature) do
      [first | _rest] -> append_user_turn(history, %{first => text})
      [] -> history
    end
  end

  defp append_note(history, _signature, _none), do: history

  # A turn the loop records with only a user side (the note, or inputs no step
  # spent) is a step event that called nothing and said nothing. The chat
  # adapter renders such a step as its user message alone, in every tool mode,
  # and a host that hands the history back gets the same rendering. Stored as
  # inputs alone, it would be a `History` entry, which the adapter renders as a
  # finished exchange with a filler reply the model never gave.
  defp append_user_turn(history, fields) do
    append_history(
      history,
      Map.merge(fields, %{tool_calls: %ToolCalls{tool_calls: []}, tool_call_results: []})
    )
  end

  defp forced_submit_prediction(react, history, pending) do
    forced = forced_submit_program(react, %{type: "tool", name: "submit"})

    case predict(forced, react, history, pending) do
      {:error, reason, history} = error ->
        # A full context window or a safety guard refuses any request, so
        # neither is read as a refusal of the named choice.
        if named_tool_choice_unsupported?(reason) and
             not Imp.Errors.context_window_exceeded?(reason) and not safety_error?(reason) do
          # Some endpoints take only the string none/auto/required subset,
          # and some only "auto". Restrict both the provider tools and the
          # rendered tool inventory to submit before requiring a call; using
          # "required" while other tools remain visible would not force final
          # submission.
          submit = Map.fetch!(react.tools, :submit)
          submit_only = %{react | tools: %{submit: submit}}
          fallback = forced_submit_program(submit_only, "required")

          # No request is sent once the deadline has passed; the refusal is
          # then the last request's failure, which names the deadline.
          retry =
            if deadline_passed?(),
              do: :deadline_passed,
              else: predict(fallback, submit_only, history, pending)

          case retry do
            :deadline_passed ->
              error

            {:ok, prediction, history} ->
              {:ok, prediction, history}

            {:error, fallback_error, history} ->
              if Imp.Errors.context_window_exceeded?(fallback_error) or
                   safety_error?(fallback_error),
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
      stepped = append_last_step(history, pending, prediction, calls, nil)
      # The step spent the pending inputs if it was recorded.
      pending = if stepped == history, do: pending, else: %{}
      extract_final(react, inputs, pending, stepped, reason, initial_error)
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
  defp append_last_step(history, pending, prediction, calls, outputs, results \\ []) do
    thought = Imp.get(prediction, :next_thought)

    if thought in [nil, ""] and calls.tool_calls == [] do
      history
    else
      event = history_event(pending, prediction, calls, results, outputs)
      append_history(history, event)
    end
  end

  # The forced request's guidance says so: its last thought, if the history
  # ends on one, is shown as the request's last user message (probe 4,
  # decisions.md row of 2026-10-16), not followed by the unsent note.
  defp forced_submit_program(react, tool_choice) do
    %{
      react.react
      | adapter_opts:
          case Keyword.fetch(react.react.adapter_opts, :guidance) do
            {:ok, %{} = guidance} ->
              Keyword.put(
                react.react.adapter_opts,
                :guidance,
                Map.put(guidance, :forced_submit, true)
              )

            _none ->
              react.react.adapter_opts
          end,
        config:
          Keyword.merge(react.react.config,
            tools:
              react.tools
              |> ordered_tools(react.tool_order)
              |> Enum.map(&tool_description(&1, react.signature)),
            tool_choice: tool_choice,
            reasoning_effort: nil
          )
    }
  end

  defp extract_final(react, inputs, pending, history, reason, initial_error) do
    if deadline_passed?(),
      do: incomplete_prediction(history, :deadline_exceeded, initial_error),
      else: run_extractor(react, inputs, pending, history, reason, initial_error)
  end

  defp run_extractor(react, inputs, pending, history, reason, initial_error) do
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
            # The outputs are recorded as what they are: produced with no tool
            # call, after the turn's last step, with any inputs no step spent.
            # The history then holds the turn's answer, as a `submit`'s event
            # does, and ends the episode.
            event =
              pending
              |> Map.merge(final)
              |> Map.merge(%{tool_calls: %ToolCalls{tool_calls: []}, tool_call_results: []})

            final_prediction(final, append_history(history, event), :extracted, %{
              termination_cause: reason
            })

          {:error, errors} ->
            incomplete_prediction(history, reason, %{
              initial: initial_error,
              extraction: Imp.Schema.retry_feedback(errors)
            })
        end

      {:error, extraction_error, history} ->
        last_request_failed(history, reason, extraction_error, %{
          initial: initial_error,
          extraction: extraction_error
        })
    end
  end

  defp extraction_program(react) do
    signature = %Imp.Signature{
      # A call that resumes a held history may give no new inputs: they are
      # in the history, as the step's own signature takes them.
      inputs:
        Enum.map(react.signature.inputs, &Imp.Signature.Field.optional/1) ++
          [Imp.Signature.Field.new(:history, :input)],
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
    available during this extraction step. `history` is in order, oldest
    first: its last messages are the current turn, and text written there was
    written in this turn, not an earlier one.
    """
    |> String.trim()
  end

  # A provider that will not take the named `tool_choice` refuses the
  # request with an error that names the parameter and says what it does
  # support, in its own words: "supported string values are none, auto,
  # required" (OpenAI-compatible endpoints), "only `"auto"` is supported for
  # `tool_choice`" (Meta's API, relayed by OpenRouter under
  # `error.metadata.raw`), "No endpoints found that support the provided
  # 'tool_choice' value" (OpenRouter routing with `require_parameters`). An
  # error that names `tool_choice` for another reason, such as Anthropic's
  # "Thinking may not be enabled when tool_choice forces tool use", is not
  # one.
  defp named_tool_choice_unsupported?(reason) do
    text = reason |> refusal_text() |> String.downcase()

    String.contains?(text, "tool_choice") and
      (String.contains?(text, "support") or String.contains?(text, "only"))
  end

  # What the provider said. For an `Imp.LMError` from ReqLLM that is the
  # response body only: ReqLLM keeps the body's top-level message as the
  # error's text, which OpenRouter sets to "Provider returned error" while the
  # upstream's words sit in `error.metadata.raw`, and the error's request body
  # names `tool_choice` on every forced request. An error with no response
  # body (another client's, or one built by hand) is read from its message.
  defp refusal_text(%Imp.LMError{reason: reason, message: message}) do
    case response_bodies(reason) do
      [] -> to_string(message)
      bodies -> bodies |> Enum.flat_map(&body_messages/1) |> Enum.join(" ")
    end
  end

  defp refusal_text(value) when is_binary(value), do: value
  defp refusal_text(value) when is_exception(value), do: Exception.message(value)

  defp refusal_text(value) when is_map(value) do
    [:reason, "reason", :message, "message", :response_body, "response_body", :error, "error"]
    |> Enum.flat_map(fn key ->
      case Map.fetch(value, key) do
        {:ok, nested} -> [refusal_text(nested)]
        :error -> []
      end
    end)
    |> Enum.join(" ")
  end

  defp refusal_text(value) when is_list(value), do: Enum.map_join(value, " ", &refusal_text/1)

  defp refusal_text(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map_join(" ", &refusal_text/1)

  defp refusal_text(value), do: inspect(value)

  # A streamed request's error wraps the HTTP error as its `cause`, and keeps
  # only the body's inner `error` object.
  defp response_bodies(%ReqLLM.Error.API.Stream{cause: cause}), do: response_bodies(cause)

  defp response_bodies(%ReqLLM.Error.API.Request{response_body: body}) when not is_nil(body),
    do: [body]

  defp response_bodies(_reason), do: []

  defp body_messages(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> body_messages(decoded)
      {:error, _not_json} -> [body]
    end
  end

  defp body_messages([first | _rest]), do: body_messages(first)
  defp body_messages(%{"error" => %{} = error}), do: body_messages(error)
  # A provider error relayed on a successful response, as the ReqLLM client
  # builds it, carries the message itself.
  defp body_messages(%{"error" => message}) when is_binary(message), do: [message]

  defp body_messages(%{} = error) do
    message = if is_binary(error["message"]), do: [error["message"]], else: []

    raw =
      case error["metadata"] do
        %{"raw" => raw} when is_binary(raw) -> body_messages(raw)
        _none -> []
      end

    message ++ raw
  end

  defp body_messages(_body), do: []

  # `tools` is the step's tool list, so a task field of that name would be
  # taken for it. A program saved before the name was reserved is refused on
  # load with the same words, naming what the caller did.
  defp reject_reserved_tools!(signature, context) do
    if Enum.any?(signature.inputs ++ signature.outputs, &Imp.FieldMap.same_name?(&1.name, :tools)) do
      raise ArgumentError,
            "#{context}: `tools` is reserved for the step's tool list; rename that field"
    end
  end

  # The task's one text output is also the step's text output. The loop's
  # persisted history still uses next_thought/tool_calls; prediction and history
  # projection below isolate that storage vocabulary from the live contract.
  defp step_text(signature, finish) do
    case text_output(signature, finish) do
      {:text, [field]} ->
        Imp.Signature.Field.optional(field)

      :submit ->
        Imp.Signature.Field.new(%{name: :next_thought, metadata: %{optional: true}}, :output)
    end
  end

  defp step_metadata(signature, finish) do
    text = step_text(signature, finish).name

    calls =
      if Imp.FieldMap.same_name?(text, :tool_calls), do: :agent_tool_calls, else: :tool_calls

    %{text_field: text, tool_calls_field: calls, tools_field: :tools}
  end

  defp step_outputs(signature, finish) do
    roles = step_metadata(signature, finish)
    [step_text(signature, finish), %{tool_calls_field() | name: roles.tool_calls_field}]
  end

  # The written form of a call, for an LM that writes its calls: the shape
  # `tool_calls` parses (a list; `name` and `arguments`, or `tool`/`args`).
  @tool_calls_desc "The tools to call, as a JSON list in which each call has `name` and " <>
                     "`arguments`. Example: " <>
                     ~s([{"name": "search", "arguments": {"query": "cats"}}])

  defp tool_calls_field,
    do:
      Imp.Signature.Field.new(
        %{name: :tool_calls, type: :array, desc: @tool_calls_desc, metadata: %{default: []}},
        :output
      )

  defp tools_field,
    do: Imp.Signature.Field.new(%{name: :tools, type: :array, metadata: %{default: []}}, :input)

  # The roster as the `tools` input: one line per tool in DSPy's `Tool.__str__`
  # shape, "name, whose description is <desc>...</desc>. It takes arguments
  # {...}.", with the arguments as JSON: the `properties` of the schema the
  # provider would get (`submit`'s included), then its `required` list and its
  # `$defs`, so an optional argument reads as one and a `$ref` resolves. The
  # properties keep their order only when the schema keeps one (a
  # `Jason.OrderedObject`); a map's are listed by name.
  defp tool_lines(react) do
    react.tools
    |> ordered_tools(react.tool_order)
    |> Enum.map(fn tool ->
      %{function: function} = tool_description(tool, react.signature)

      description =
        case function.description do
          desc when desc in [nil, ""] -> "."
          desc -> ", whose description is <desc>#{String.replace(desc, "\n", "  ")}</desc>."
        end

      "#{function.name}#{description} It takes arguments " <>
        "#{Jason.encode!(tool_arguments(function.parameters))}."
    end)
  end

  defp tool_arguments(schema) do
    [{"properties", schema_value(schema, "properties") || %{}}]
    |> Kernel.++(
      for key <- ["required", "$defs"], value = schema_value(schema, key), do: {key, value}
    )
    |> Jason.OrderedObject.new()
  end

  defp schema_value(%Jason.OrderedObject{values: values}, key) do
    Enum.find_value(values, fn {name, value} -> if to_string(name) == key, do: value end)
  end

  defp schema_value(schema, key) when is_map(schema),
    do: Map.get(schema, key) || Map.get(schema, safe_atom(key))

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp predict(program, react, history, pending) do
    context_call(history, fn projected ->
      projected = %{projected | messages: Enum.map(projected.messages, &step_turn(&1, react))}
      inputs = pending |> Map.put(:history, projected) |> Map.put(:tools, tool_lines(react))

      program = %{program | demos: Enum.map(program.demos, &step_demo(&1, program.signature))}

      case Imp.Predict.call(program, inputs) do
        {:ok, prediction} -> {:ok, step_prediction(prediction, program.signature)}
        error -> error
      end
    end)
  end

  # Saved step demonstrations use the durable step vocabulary too. Project
  # them at the request boundary, preserving the saved example itself.
  defp step_demo(example, signature) do
    example = Imp.Example.new(example)
    roles = signature.metadata

    supplied_text? = Imp.FieldMap.has_key?(example.fields, roles.text_field)

    legacy_calls? =
      Imp.FieldMap.same_name?(roles.text_field, :tool_calls) and
        not is_binary(Imp.Example.get(example, :tool_calls))

    case {Imp.FieldMap.fetch(example.fields, :next_thought), supplied_text? and not legacy_calls?} do
      {{:ok, text}, false} ->
        calls = Imp.Example.get(example, :tool_calls, [])

        example
        |> Imp.Example.delete(:next_thought)
        |> Imp.Example.delete(:tool_calls)
        |> Imp.Example.put(roles.text_field, text)
        |> Imp.Example.put(roles.tool_calls_field, calls)

      _ ->
        example
    end
  end

  # Normalize once at the loop boundary. Neither field is an additional
  # model output; these are the existing history/execution representation.
  defp step_prediction(prediction, signature) do
    roles = signature.metadata
    text = Imp.get(prediction, roles.text_field)
    calls = Imp.get(prediction, roles.tool_calls_field, [])
    %{prediction | fields: %{next_thought: text, tool_calls: calls}}
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

          # When the result came back is recorded with it, as a fact of the
          # history: a renderer that shows it reads the same bytes on every
          # later request.
          recorded =
            result
            |> Map.from_struct()
            |> Map.put(:error, error?)
            |> Map.put(:returned_at, DateTime.utc_now() |> DateTime.to_iso8601())

          {:cont, {results ++ [recorded], final, finished_by}}
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
  # task declares exactly one unconstrained text output for that text to be.
  # Several outputs, one that is not text, or one with constraints cannot be
  # filled from text alone and take the forced submit. Any text is a valid
  # value of an unconstrained text output, so the text is the answer as it
  # is. A signature with `submit` has no text answer: that step is the
  # `:empty_tool_calls` interruption.
  defp parse_text(signature, finish, prediction) do
    with {:text, [%Imp.Signature.Field{name: name}]} <- text_output(signature, finish) do
      case Imp.get(prediction, :next_thought) do
        text when is_binary(text) and text != "" -> {:ok, %{name => text}}
        _nothing -> {:ok, %{name => nil}}
      end
    else
      :submit -> {:none, :empty_tool_calls}
    end
  end

  defp text_output(signature, finish),
    do: if(plain_text?(signature, finish), do: {:text, signature.outputs}, else: :submit)

  # Whether a turn ends in plain text: a signature with one unconstrained
  # text output, unless the program asked for `finish: :submit`.
  defp plain_text?(signature, :auto), do: single_text_output?(signature)
  defp plain_text?(_signature, :submit), do: false
  defp plain_text?(_signature, :tools), do: false

  # Text is the answer only when any text is a valid answer: a constrained
  # string (an enum, a pattern, an answer shape) keeps `submit`, whose schema
  # tells the model what the output accepts.
  defp single_text_output?(%Imp.Signature{outputs: [%Imp.Signature.Field{} = field]}),
    do: field.type in [:string, "string"] and unconstrained?(field)

  defp single_text_output?(_signature), do: false

  defp unconstrained?(field) do
    constraints =
      Map.get(field.metadata, :constraints, Map.get(field.metadata, "constraints"))

    constraints in [nil, %{}]
  end

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
        {{:error, {:tool_denied, tool.name, Imp.Redaction.redact(reason)}}, true, :refused}

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
        # The name and the key may be the same text as an atom and a string.
        case Imp.FieldMap.fetch(arguments, name) do
          {:ok, value} -> {Map.put(outputs, name, value), missing}
          :error -> {outputs, missing ++ [name]}
        end
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
    |> Map.put(:tool_calls, plain_calls(calls))
    |> Map.put(:tool_call_results, results)
    |> then(fn event -> if final, do: Map.merge(event, final), else: event end)
    # The history is what the model reads on its next step and what a host
    # stores to continue the conversation, so every input, call, result and
    # reasoning block stays as it was; Run events redact their own copies.
    |> maybe_put(:reasoning_content, Map.get(prediction.metadata, :native_reasoning))
    |> maybe_put(:reasoning_details, Map.get(prediction.metadata, :reasoning_details))
  end

  # The calls are held as their fields, as a history reloaded from
  # `Imp.History.dump/1` holds them, so a live history and a reloaded one are
  # the same turns.
  defp plain_calls(%ToolCalls{tool_calls: calls}),
    do: %{tool_calls: Enum.map(calls, &Map.from_struct/1)}

  # The prediction's fields are the signature's outputs and nothing else, so
  # an output may take any name; how the turn went is metadata.
  defp final_prediction(outputs, history, reason, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.merge(%{history: history.full, termination_reason: reason})
      |> projection_metadata(history)

    {:ok, Imp.Prediction.new(outputs, metadata: metadata)}
  end

  # Why the provider stopped the reply whose text is the answer, where the LM
  # client reports it: in the result's provider metadata (`Imp.LM.Result`'s
  # `:req_llm` entry, which `Imp.Usage` reads usage from too).
  defp finish_reason(metadata, prediction) do
    provider = map_value(prediction.metadata, :req_llm) || %{}
    maybe_put(metadata, :finish_reason, map_value(provider, :finish_reason))
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_other, _key), do: nil

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
          metadata: Map.merge(%{step: turn}, Map.new(metadata))
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
  defp history_context(history, signature, replay, pending) do
    outputs = Imp.Signature.output_names(signature)
    size = length(history.messages)

    boundaries =
      history.messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {entry, _} ->
        outputs != [] and
          Enum.all?(outputs, fn name ->
            Imp.FieldMap.has_key?(entry, name)
          end)
      end)
      |> Enum.map(&elem(&1, 1))

    boundaries =
      if size > 0 and List.last(boundaries) != size, do: boundaries ++ [size], else: boundaries

    %{
      full: history,
      boundaries: boundaries,
      omitted: 0,
      omitted_groups: 0,
      retries: 0,
      # `history_replay: :actions`: the steps given before this call are
      # earlier turns, shown as their actions (`actions_view/2`).
      actions_before: if(replay == :actions, do: current_turn_start(history, signature, pending)),
      inputs: Imp.Signature.input_names(signature),
      outputs: outputs
    }
  end

  # An earlier turn's step as `history_replay: :actions` shows it. A step that
  # carries the task's outputs was the answer and is shown whole. Any other
  # step loses the text and reasoning the model wrote beside its calls; one
  # that called nothing keeps only the inputs it carried, and goes when it
  # carried none. Only the request changes: the history keeps every step.
  # Divergence from DSPy's ReActV2, whose history replays every step whole
  # (decisions.md).
  @step_words [:next_thought, :reasoning_content, :reasoning_details]

  # Where the current turn starts in a history passed to a call. A call with
  # new inputs starts a turn, so every passed step is earlier. A call without
  # them (a resume mid-turn) continues the turn the last step carrying the
  # task's inputs opened; that step and those after it are the current turn,
  # shown whole, since a provider that keeps reasoning within a turn
  # (DeepSeek's `reasoning_content`, Anthropic's thinking blocks, Gemini's
  # thought signatures) needs it on the turn's own calls.
  defp current_turn_start(history, signature, pending) do
    if pending != %{} do
      length(history.messages)
    else
      inputs = Imp.Signature.input_names(signature)

      history.messages
      |> Enum.with_index()
      |> Enum.filter(fn {step, _} -> Enum.any?(inputs, &Imp.FieldMap.has_key?(step, &1)) end)
      |> List.last()
      |> case do
        {_step, index} -> index
        nil -> 0
      end
    end
  end

  defp actions_view(step, context) do
    if Enum.any?(context.outputs, &(not is_nil(Imp.FieldMap.get(step, &1)))) do
      [step]
    else
      step = Enum.reduce(@step_words, step, &Imp.FieldMap.delete(&2, &1))

      cond do
        history_calls(step) != [] -> [step]
        Enum.any?(context.inputs, &Imp.FieldMap.has_key?(step, &1)) -> [step]
        true -> []
      end
    end
  end

  defp history_calls(step) do
    case Imp.FieldMap.get(step, :tool_calls) do
      %ToolCalls{tool_calls: calls} -> calls
      %{tool_calls: calls} when is_list(calls) -> calls
      %{"tool_calls" => calls} when is_list(calls) -> calls
      calls when is_list(calls) -> calls
      _ -> []
    end
  end

  defp projected_messages(context) do
    messages = Enum.drop(context.full.messages, context.omitted)

    case context do
      %{actions_before: before} when is_integer(before) ->
        {earlier, current} = Enum.split(messages, max(before - context.omitted, 0))
        Enum.flat_map(earlier, &actions_view(&1, context)) ++ current

      _context ->
        messages
    end
  end

  # A stored turn that carries the answer of a one-text-output task but no
  # step outputs (a host wrote it, or it predates the loop's own events) is,
  # in the step's terms, a step that answered in text: `next_thought` is the
  # answer and it called nothing. Read that way, every adapter replays it as
  # the answer the model gave, not as step fields it never filled. Only the
  # prompt's view changes; the history the caller holds does not. A binary
  # task output named tool_calls is text, not the stored call collection.
  defp step_turn(turn, %__MODULE__{signature: signature, finish: finish}) when is_map(turn) do
    with {:text, [%Imp.Signature.Field{name: name}]} <- text_output(signature, finish),
         false <- Imp.FieldMap.has_key?(turn, :next_thought),
         false <-
           Imp.FieldMap.has_key?(turn, :tool_calls) and
             not Imp.FieldMap.same_name?(name, :tool_calls),
         answer when is_binary(answer) <- Imp.FieldMap.get(turn, name) do
      if Enum.any?(Map.keys(turn), &is_binary/1),
        do:
          turn |> Imp.FieldMap.put("next_thought", answer) |> Imp.FieldMap.put("tool_calls", []),
        else: turn |> Imp.FieldMap.put(:next_thought, answer) |> Imp.FieldMap.put(:tool_calls, [])
    else
      _step_turn -> turn
    end
  end

  defp step_turn(turn, _react), do: turn

  defp append_history(context, event),
    do: %{context | full: Imp.History.append(context.full, event)}

  defp context_call(context, call) do
    projected = %{context.full | messages: projected_messages(context)}

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

  defp pop_max_iters(inputs, default), do: pop_call_option(inputs, :max_iters, default)

  # A call-time option is read under its atom or its string name and taken out
  # of the inputs, so it never reaches the step's fields.
  defp pop_call_option(inputs, key, default) do
    value =
      cond do
        Map.has_key?(inputs, key) -> Map.fetch!(inputs, key)
        Map.has_key?(inputs, to_string(key)) -> Map.fetch!(inputs, to_string(key))
        true -> default
      end

    {value, Map.drop(inputs, [key, to_string(key)])}
  end

  defp validate_call_note(note) when is_binary(note) or is_nil(note), do: :ok
  defp validate_call_note(note), do: {:error, {:invalid_react_v2_last_request_note, note}}

  # The loop chooses the tool roster and `tool_choice` on each step.
  defp validate_call_config(config) when is_list(config) do
    if Keyword.keyword?(config) and
         not Enum.any?([:tools, :tool_choice], &Keyword.has_key?(config, &1)),
       do: :ok,
       else: {:error, {:invalid_react_v2_config, config}}
  end

  defp validate_call_config(config), do: {:error, {:invalid_react_v2_config, config}}

  # A call's own runners for tools the program holds. What the model is shown
  # of each tool -- its name, description and schema -- must be the program's,
  # so the request, its tool roster and its cacheable prefix are the same; a
  # tool shown any differently is refused. Only `run` is the call's. The
  # program value is not changed: `with_tools/2`, the path an optimizer's
  # updates take, still refuses a changed runner.
  defp call_tools(tools, []), do: {:ok, tools}

  defp call_tools(tools, given) when is_list(given) do
    Enum.reduce_while(given, {:ok, tools}, fn
      %Imp.Tool{} = tool, {:ok, acc} ->
        case Imp.Tool.resolve_name(acc, tool.name) do
          nil ->
            {:halt, invalid_call_tools("#{tool.name} is not one of the program's tools")}

          name ->
            held = Map.fetch!(acc, name)

            if tool.description == held.description and tool.schema == held.schema,
              do: {:cont, {:ok, Map.put(acc, name, %{held | run: tool.run})}},
              else:
                {:halt,
                 invalid_call_tools(
                   "#{tool.name} must be shown to the model as the program shows it: " <>
                     "the same description and schema"
                 )}
        end

      other, _acc ->
        {:halt, invalid_call_tools("expected Imp.Tool structs, got: #{inspect(other)}")}
    end)
  end

  defp call_tools(_tools, given),
    do: invalid_call_tools("expected a list of Imp.Tool structs, got: #{inspect(given)}")

  defp invalid_call_tools(message), do: {:error, {:invalid_react_v2_tools, message}}

  # A call's own `last_request_tools` replaces the program's, checked as the
  # program's were. A host that makes a one-request call for a summary gives
  # `[]`, so the program's listed tools cannot act in it.
  # Presence of the key, under either spelling, is what says the call gives
  # its own list; any value it gives is checked, so none can stand for the
  # program's.
  defp call_last_request_tools(react, inputs) do
    case Enum.find([:last_request_tools, "last_request_tools"], &Map.has_key?(inputs, &1)) do
      nil ->
        {:ok, react.last_request_tools, inputs}

      key ->
        inputs_left = Map.drop(inputs, [:last_request_tools, "last_request_tools"])

        case resolve_last_request_tools(
               Map.fetch!(inputs, key),
               react.tools,
               plain_text?(react.signature, react.finish)
             ) do
          {:ok, resolved} -> {:ok, resolved, inputs_left}
          {:error, message} -> {:error, {:invalid_react_v2_last_request_tools, message}}
        end
    end
  end

  defp validate_call_max_iters(max_iters) when is_integer(max_iters) and max_iters >= 0, do: :ok

  defp validate_call_max_iters(max_iters),
    do: {:error, {:invalid_react_v2_max_iters, max_iters}}

  defp fetch_input(inputs, name), do: Imp.FieldMap.get(inputs, name)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # What the adapter needs to say about the loop, as data. `submit_tool` is the
  # tool that ends the turn, so a renderer never has to know its name, and nil
  # when the signature has no `submit` and the answer is text. `outputs`
  # are the task's output fields, so each step says what every output means;
  # otherwise their descriptions reach the model only inside `submit`'s schema.
  defp guidance(signature, tools, finish, unsent_note, finish_on) do
    %{
      submit_tool: if(plain_text?(signature, finish) or finish == :tools, do: nil, else: :submit),
      input_names: Imp.Signature.input_names(signature),
      output_names: Imp.Signature.output_names(signature),
      outputs: signature.outputs,
      tool_names: tools |> Map.keys() |> Enum.sort(),
      unsent_note: unsent_note || unsent_note(signature, finish, finish_on)
    }
    |> maybe_put(:finish_tools, finish_tools(finish, finish_on))
  end

  # The tools that end a `finish: :tools` turn, in name order, for the
  # guidance and the default unsent note.
  defp finish_tools(:tools, finish_on),
    do: finish_on |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp finish_tools(_finish, _finish_on), do: nil

  # Under `finish: :submit` a thought-only step is followed by an ordinary
  # step, and the adapter tells the model, after that step's message, what
  # became of it and what its two ways on are. This is a fact about the step
  # (nothing a step writes is sent; only `submit` is), so it is rendered
  # after every thought-only step, the same in every request and on replay.
  # Measured on real final steps across 11 model families (decisions.md, row
  # of 2026-10-16 on the unsent note): with this line after the thought, no sample wrote text
  # again and replies were submitted intact; with the thought shown back as a
  # user message, some models took it for an echo of their own output and
  # submitted nothing; with the first sentence alone, models probed their
  # status and took extra steps.
  defp unsent_note(signature, finish, finish_on)

  defp unsent_note(signature, :submit, _finish_on) do
    fields = signature |> Imp.Signature.output_names() |> Enum.map(&"`#{&1}`")

    with_fields =
      case fields do
        [one] -> one
        several -> Enum.join(Enum.drop(several, -1), ", ") <> " and " <> List.last(several)
      end

    "Your message above was not sent. To reply, call `submit` with #{with_fields}; " <>
      "to keep working, call a tool."
  end

  # A plain-text loop has no `submit` to name, but a history written under
  # `finish: :submit` can hold thought-only steps; after each, the factual
  # half of the note, so the thought does not read as a message that was
  # sent. A history written in a plain-text loop has no such step (its text
  # steps carry the answer), so its requests are unchanged.
  defp unsent_note(signature, :auto, _finish_on) do
    if single_text_output?(signature), do: "Your message above was not sent."
  end

  # Under `finish: :tools` only a `finish_on` tool ends the turn, so the line
  # names them. A host that knows what those tools mean passes its own
  # (`:unsent_note`).
  defp unsent_note(_signature, :tools, finish_on) do
    "Your message above was not sent. To end the turn, call " <>
      or_list(finish_tools(:tools, finish_on)) <> "; to keep working, call a tool."
  end

  defp or_list([one]), do: "`#{one}`"

  defp or_list(names) do
    quoted = Enum.map(names, &"`#{&1}`")
    Enum.join(Enum.drop(quoted, -1), ", ") <> " or " <> List.last(quoted)
  end

  defp provider_tool_config(tools, order, signature) do
    [
      tools: tools |> ordered_tools(order) |> Enum.map(&tool_description(&1, signature)),
      tool_choice: "auto"
    ]
  end

  # The roster is sent in the order the tools were declared, then `submit`.
  # A map's order would be the order the tool names' atoms were created in,
  # which differs between processes and would change the prompt a provider
  # caches. A name missing from the order (a program saved before it was
  # recorded) comes after the declared ones, sorted.
  defp ordered_tools(tools, order) do
    declared = Enum.filter(order, &Map.has_key?(tools, &1))

    rest =
      tools
      |> Map.keys()
      |> Enum.reject(&(&1 in declared or &1 == :submit))
      |> Enum.sort_by(&to_string/1)

    submit = if Map.has_key?(tools, :submit), do: [:submit], else: []
    Enum.map(declared ++ rest ++ submit, &Map.fetch!(tools, &1))
  end

  defp declared_order(tools) when is_list(tools),
    do:
      tools
      |> Enum.flat_map(fn
        %Imp.Tool{name: name} -> [name]
        _other -> []
      end)
      |> Enum.uniq()

  defp declared_order(_tools), do: []

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

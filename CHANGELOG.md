# Changelog

User-visible changes to Imp are recorded here.

## Unreleased

- The last request of an interrupted one-text-output turn no longer says
  `tool_choice: "none"`. It is a step like any other, with the same tools and
  `tool_choice: "auto"`. Told "none" while it wanted a tool, a model wrote the
  call as text in its own tool markup, and that text became the answer. A tool
  call on that request is still not run and is listed in
  `unexecuted_tool_calls`; the answer is the completion's text, which may be
  empty.

- A failed tool call reaches the model as plain text instead of an Elixir
  term. An MCP error result is the text of its content, the tool's own words,
  after `Error: ` unless the text already begins with "error"; a JSON-RPC
  error is the server's message; a call that got no answer says why in one
  sentence, and unless the request was never sent, that it may have been
  carried out (a timeout, a closed or failed connection, a broken stream, a
  server that stopped waiting for its tool or a tool that crashed). An
  unknown tool, missing or invalid arguments, a denied tool and a tool that
  exits or throws are sentences too; a tool that exits may have been carried
  out. `Imp.Adapter.Chat.format_tool_result/1`
  renders these, `Imp.Adapter.Chat.tool_error_text/1` gives the words without
  `Error: `, and `Imp.MCP.failure_text/1` gives the MCP ones. The recorded
  error term is unchanged. `Imp.Predict.ReAct`'s `:dspy_3_2_1` observations
  use the same words after `Execution error in <tool>: `, where they showed
  `inspect/1` of the reason.

- ReActV2 preserves provider-native reasoning text and opaque reasoning details
  across tool calls and saved-history reloads. ReqLLM receives the original
  continuation data, including provider extension fields and signatures, instead
  of losing it while rebuilding assistant messages. Operational history must be
  stored privately; run events and explicit diagnostic redaction still redact
  credential-shaped values.
- `Imp.Clients.ReqLLM` returns a response whose body carries a provider error
  as `{:error, %ReqLLM.Error.API.Request{}}`. OpenRouter relays an upstream
  provider's refusal as a successful HTTP response with an error object and no
  choices, which ReqLLM decodes to an empty message; read as a completion, a
  refused request was a model that said nothing.
- `ReActV2` offers `submit` only to a signature that needs it. A task
  signature with exactly one output of type `:string` gets no `submit` tool:
  a step that comes back as prose with no tool call is the answer, in that
  one request, with `termination_reason: :answered`, which is how Anthropic's
  tool runner, the OpenAI Agents SDK, LangGraph's ReAct and Pydantic AI end a
  turn. Its history event carries the output, as a `submit`'s does, and the
  answer is not also emitted as a `:reasoning` event. A signature with several
  outputs, or one non-text output, keeps DSPy's `submit` unchanged.
- A step of a one-text-output signature that calls nothing and says nothing
  is an empty answer: the turn ends there with `termination_reason:
  :answered` and no further request, because saying nothing is how a model
  declines to answer.
- An interrupted turn of a one-text-output signature (the step limit, a
  failed request, prose the output does not accept) makes one more
  request with the same tools as every step, and its text is the answer, with `termination_reason: :last_prose`
  and `termination_cause` naming the interruption (`:max_iters`,
  `:prediction_error`, `:parse_error`, `:invalid_answer`). A completion that says nothing is an empty answer rather
  than an error. A tool call the model makes on that request anyway is not
  run; the text is the answer and the calls are listed in
  `unexecuted_tool_calls`. `last_prose_note`, a string, puts one line of host text in
  front of that request as a user message and keeps it in the returned
  history; Imp writes no sentence of its own. If the process's `Imp.Deadline`
  has already passed, no request is made and the run ends with
  `termination_reason: :deadline_exceeded`. `forced_submit_notice` is for
  signatures with `submit` and `last_prose_note` for those without; each is
  refused at construction for the other. There is no `prose` or
  `on_max_iters` option, and a dump no longer carries them.
- `Imp.Observability` reports a prediction that ended `:answered`,
  `:last_prose` or `:finished_by_tool` as complete; it reported them as
  incomplete.
- `ReActV2` gains `finish_on`, a map from tool name to
  `fn arguments, result, inputs -> {:finish, outputs} | :continue end`. A tool
  named there ends the turn with the outputs the function returns, which are
  validated against the signature exactly as a `submit`'s are, with
  `termination_reason: :finished_by_tool` and `finished_by_tool` naming the
  tool. This is the shape Pydantic AI calls an output tool: one call both does
  the work and carries the answer. `:continue` leaves the loop running. When a
  step calls several terminal tools, the first in call order finishes the run
  and the rest still execute and are recorded; a `submit` in the same step
  still wins. The functions persist by registry name, like a tool runner.
- A `:model_request` event now records the whole request, not only its
  messages. Its metadata carries `:options`, the request options with the tool
  definitions removed, and `:tools_hash`, a SHA-256 of the canonical JSON of
  those definitions or `nil` when the request offered none. The definitions
  themselves are emitted once per run per distinct hash, as a new
  `:tools_offered` event whose input is the tool list as sent. A recorded run
  can now be reproduced call for call, without repeating an unchanging roster
  on every one. Both payloads are redacted like every other event.

- The chat adapter's format options gain the `:history_note_renderer` seam,
  `fn signature, turn -> nil | String.t()`. It is consulted for every stored
  history turn, native tool turns included, after that turn's own messages, and
  its text becomes one user message immediately behind them. Before it, a host
  had no way to say anything *about* a turn that carried tool calls: those
  turns route through the native replay path, which consults neither
  `:output_renderer` nor `:input_section_renderer`. A note is data about the
  turn — the answer was never delivered, the account's allowance ran out — so
  the model reads it as the next thing after the turn, and the record the loop
  keeps is untouched.
- A signature field's description now reaches the provider in the JSON schema
  Imp builds for it (`Imp.Schema.json_schema/1`), so `ReActV2`'s `submit` tool
  declares each output field's own words about itself in its parameter schema.
  A field without a description still emits no `description` key. This is the
  only place a field description reaches a host that replaces the chat
  adapter's rendered system section.
- A `ReActV2` step answered in plain prose with no tool call is now a thought
  that called nothing, not a parse failure. It used to fail the chat parse and
  re-ask the whole prompt through `Imp.Adapter.JSON`, which doubled the cost of
  the step and broke the provider's prefix cache; the prose is now
  `next_thought` and `tool_calls` is empty, which is what the turn-ending rule
  above then reads. The prose is
  recorded as that turn's thought in the history and shown back to the model as
  a plain assistant turn in any next request. `Imp.Adapter.Chat` reads a
  marker-free completion this way only for a signature that declares
  `metadata[:prose_step]`; every other signature parses exactly as before, JSON
  fallback included.
- `Imp.Adapter.Types.ToolCall.from_map/1` accepts `tool` as a spelling of the
  tool name, beside `name` and `recipient_name` (the arguments already accepted
  `arguments`, `args` and `parameters`). `%{"tool" => ..., "arguments" => ...}`
  is what a model emits when it writes a tool call as JSON instead of calling
  natively, and `Imp.Predict.ReActV2` now executes such a call instead of
  recording a malformed-call observation and spending another iteration on it.

## 0.4.0 — 2026-09-17

- `Imp.ACP` and `Imp.MCP.connect/2` are part of Imp. The separate `imp_acp`
  package is retired: `Imp.ACP.start_link/1` and `Imp.ACP.run/1` expose an
  ordinary Imp program to an ACP host, and `Imp.MCP.connect/2` imports
  authorized MCP servers through ExMCP as ordinary tools with explicit
  connection cleanup. There is no compatibility shim; a consumer that depended
  on `imp_acp` depends on `imp` alone and changes the module prefix. ExMCP is
  declared `runtime: false`, so an OTP release that uses either must list
  `applications: [ex_mcp: :load]` in its release definition. Ordinary Imp
  startup still starts no protocol endpoint.
- A map or list value in a prompt, including a structured tool result, now
  renders the way DSPy renders a dict: `json.dumps(..., ensure_ascii=False)`
  with Python's default separators, complete. It was `inspect/1` at its
  default limit, which cut any structured value past fifty elements to an
  ellipsis the model could not count and no host bound could measure. A term
  JSON cannot carry renders as a complete `inspect`.
- ReActV2 sends the tool roster once, natively, and never renders it as text;
  it no longer declares a `tools` input field or writes "You are an Agent..."
  into `signature.instructions`. The loop's guidance (`finish_tool`,
  `input_names`, `output_names`, `tool_names`) travels to the adapter as data
  through the new `:adapter_opts` on `Imp.Predict.Predict` and
  `Imp.Predict.ReActV2`. Each step's request is now the previous step's request
  plus the newest exchange, which is what a provider's prompt cache is keyed
  on; before, the first user message changed shape between steps one and two
  and the roster was re-sent after the history on every call.
- The chat adapter's format options (`Imp.Adapter.Chat`) gain `:system_renderer` (a function of the
  signature and the format options, default the DSPy system message),
  `:guidance` (rendered by the default system renderer the way ReAct's
  instructions used to read), and `:omit_empty_request` (end the request on
  the newest history message rather than an empty user message; off by
  default, so the JSON and XML adapters keep DSPy's shape).
- `:reasoning_effort` is the one reasoning option on `Imp.Clients.ReqLLM`, at
  construction or per call, and `:openrouter_reasoning` is gone. A call naming
  `reasoning_effort: nil` spends no reasoning on that call, which is what
  ReAct's forced submit asks for; previously that nil, combined with a
  configured OpenRouter effort, raised and ended the turn without an answer.
  Which OpenRouter wire field carries the effort is a separate switch,
  `openrouter_reasoning_wire: :top_level | :nested` (default top-level, as
  ReqLLM sends it); it names an encoding, never a value. Saved programs
  allowlist both in place of `openrouter_reasoning`.
- Changed the cost a host reads off a model call to a plain number. The
  `:model_response` event's `metadata.cost` is now the provider's reported
  total in USD as a non-negative float, or `nil` when the provider reported
  nothing Imp can read as a number; it was whatever the provider library put
  there, most recently ReqLLM's private billing breakdown map. When the
  provider reported a breakdown, the whole map is on the event as
  `metadata.billing`, untouched; when it reported none, there is no
  `:billing` key. `Imp.Core.LMResponse` carries the same pair as `:cost` and
  the new `:billing` field, and reads a total given as a number, a string, a
  `Decimal`, or a breakdown map. A host summing spend reads the number and no
  longer has to know a provider library's internal shape.
- Added `Imp.MCP.OAuth`, a credential store for remote HTTP MCP servers that
  require a browser-authorized OAuth grant. It begins the flow, listens on
  `127.0.0.1` for the redirect, stores the grant encrypted as one file per
  credential under a directory the host names, and refreshes it without the
  person. A grant is bound to the URL it was authorized for, so a descriptor
  cannot point another server's credential at itself. A refresh the
  authorization server answers with `invalid_grant` is reported as
  `{:mcp_oauth_reauthorization_required, credential}` rather than as a
  retryable failure.
- Added two server descriptor auth forms that `Imp.MCP.connect/2` resolves to
  headers at connect time: `%{"type" => "oauth", "credential" => ref}`, which
  reads the store passed as the new `:credentials` option, and
  `%{"type" => "bearer_env", "variable" => name}`, which reads the host's
  environment and connects with no `Authorization` header (logging one
  warning) when the variable is unset, unless `"required" => true`. Static
  `"headers"` are unchanged.
- Added `on_failure: :drop` to `Imp.MCP.connect/2`. Under it a server whose
  transport or `initialize` fails, which accepts the connection and never
  answers, or which cannot answer `tools/list`, is left out with its client
  closed instead of failing the whole import: the tools of the servers that did
  connect are returned, and the new `unavailable` field of `Imp.MCP.Import`
  names each dropped server with a short reason and with the `index` of its
  descriptor in the list that was passed in. The default `on_failure: :refuse`
  keeps the previous all-or-nothing behaviour, except that a transport that
  refuses the connection is now reported as `{:mcp_connection_failed, reason}`
  rather than as the import helper's exit. A descriptor `:authorize` refused,
  one whose declared `auth` cannot produce a header, a malformed one, and
  anything raised by the caller's own `:tool_filter` refuse the import under
  both settings.
- Each MCP dial is now bounded by `:timeout` on its own rather than sharing one
  budget with the whole list. A host that accepts the connection and answers
  nothing returns within neither `:handshake_timeout` nor `:era_probe_timeout`,
  so two of them used to exhaust the shared budget and refuse the import as
  `{:error, :mcp_import_timeout}` whatever `:on_failure` said; now each costs
  its own timeout and is reported as `{:mcp_connection_failed, :timeout}`.
- An abandoned dial no longer leaks its client. `ExMCP.Client` traps exits and
  ignores the `EXIT` from the process that started it, so killing the import
  helper at a timeout left every half-open client alive, holding its socket,
  for the life of the node.
- A `tools/list` body that is not a catalog is now reported as
  `{:mcp_tools_list_failed, server, {:invalid_mcp_tools_response, shape}}`
  rather than as a bare `{:invalid_mcp_tools_response, shape}` that named no
  server.
- The repository is public. Installing at a tag needs no credentials, and the
  README, docs, and livebooks no longer describe a private source release.
- Removed the evidence-certification bookkeeping from the source checkout. It
  never shipped in the package, so a consumer sees no change; the benchmark
  harness it wrapped is unchanged.
- Added [Benchmarks](https://github.com/deepfates/imp/blob/main/docs/BENCHMARKS.md)
  and its [results table](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md).
  Every number this repository publishes is one row in that table, carrying
  the dataset and its license, the model, the provider, the date, the commit,
  and the command that produced it; prose elsewhere cites a row rather than
  restating a number. The benchmarks page says what each command needs from
  you — key, Python environment, time, rough cost — and separates a row a
  stranger can re-measure with an API key from one that only recomputes
  statistics from committed rows, and from the claims that cannot be
  re-measured at all. Neither page publishes an aggregate or a release score.
  The tutorial's rows were re-measured live for this release, a month after the
  first run, and both runs are recorded. They live in the repository, not in
  the installed package.

## 0.3.2 — 2026-09-01

- Made the RLM controller prompt describe the restricted language actually
  accepted by its interpreter, including supported repair paths and explicit
  unsupported forms.
- Preserved explicit no-retry provider policy across Req function, module, and
  `{module, function, args}` adapters.

## 0.3.1 — 2026-08-23

- Clarified the supported center versus pre-1.0 advanced workflows, the exact
  meaning of typed inputs and outputs, and the restricted-interpreter security
  boundary.
- Completed the structured signature field reference and corrected cold-reader
  prerequisites and cross-references.

## 0.3.0 — 2026-08-23

Private Git source release. Imp is not published to Hex.

### Added

- Typed code fields, richer structured signatures, and consistent Chat, JSON,
  and XML adapter validation.
- General program parameters and checksummed parameter artifacts for named
  predictors, tools, playbooks, and custom optimizable components.
- Full MIPROv2 TPE search, expanded GEPA/SIMBA/COPRO behavior, persistent
  playbook optimization, optimizer checkpoints, and Optimize Anything program
  artifacts.
- Addressable ReActV2 and RLM runs with ordered events, cancellation, explicit
  per-effect authorization, and owner-death cleanup.
- MCP stdio process ownership that reaps server process groups when a call or
  run is cancelled.
- Provider streaming for composed programs, including named-predictor field
  selection and a typed terminal prediction.
- A complete deployment example with disjoint evaluation, parameter artifacts,
  fresh-process loading, concurrent serving, hot reload, and failure
  containment.

### Changed

- `Imp.optimize/3`, `/4`, and `/5` now return `{:ok, program}` or
  `{:error, reason}`. The corresponding `optimize!` functions raise.
- Adapter types moved from `Imp.Adapters.Types` to `Imp.Adapter.Types`.
- Saved programs and parameter artifacts use atomic private writes and require
  live providers, callbacks, tools, and policies to be rebound from trusted
  application code.
- ReActV2 uses a validated `submit` tool, falls back to tools-disabled typed
  extraction when a provider cannot honor forced tool choice, and grounds that
  extraction only in successful retained observations.
- Evaluation timeouts, provider failures, metric failures, budget exhaustion,
  and cancelled work propagate as observable failures instead of silently
  becoming ordinary scores.
- The private release installs consistently from the immutable `v0.3.0` Git
  tag in the README, Livebooks, and packaged examples.

### Fixed

- Cached ReqLLM responses no longer double-count token usage.
- ReAct retains a single tool-call trajectory when context truncation cannot
  safely remove a complete turn.
- ReActV2 converts malformed provider tool calls into non-executable error
  observations so a model can recover without bypassing policy or
  authorization.
- Whole-program and optimizer-report identities survive artifact round trips.
- Composed streaming cancels provider work on early halt or consumer death.
- Batch messages retain their structured conversations after JSON transport.
- Optimizer progress subscribers receive real trial events.

### Removed

- `Imp.Agent` and `Imp.Agent.Runtime`. Use ReActV2 or RLM as the program and
  ordinary Elixir supervision as the runtime.
- `Imp.Streaming.Messages.StatusMessageProvider`, which did not implement an
  execution-stage status contract. Use stream listeners and `:telemetry`.

## 0.2.1 — 2026-07-18

### Added

- Configurable teacher and rollout timeouts for BootstrapFewShot, GRPO, and
  BootstrapFinetune.

### Fixed

- Saved Predict programs retain JSON retry and fallback configuration.
- GEPA reflection no longer sends an invalid provider connection option.
- Reasoning-model token-limit normalization is wire-neutral.
- Signature errors suggest `array[...]` when given DSPy's `list[...]` spelling.
- Global test configuration and async synchronization no longer leak across
  tests.

## 0.2.0 — 2026-07-17

### Added

- `Imp.stream/3` and `Imp.collect/3`, with provider streaming and local
  post-call chunking modes.
- Public optimizer progress subscriptions and evaluation timeout reporting.
- Deterministic LabeledFewShot selection and seeded data splitting.

### Fixed

- Batch requests preserve structured messages.
- Optimizer trial telemetry is emitted as documented.
- Timed-out evaluation rows are reported explicitly.

## 0.1.0 — 2026-07-16

Initial private Git source release of Imp's signature, program, provider,
evaluation, optimization, tool, retrieval, persistence, and Livebook APIs.

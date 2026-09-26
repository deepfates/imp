# Changelog

User-visible changes to Imp are recorded here.

## 0.5.0 — not yet released

### Security

- An LM client, the HTTP, Databricks and Weaviate retrievers and the MLflow
  and W&B trackers print with their credentials redacted, and so does a
  program holding one. `Imp.req_llm(model, api_key: key)` printed the key in
  IEx, in log lines and in crash reports, and a RAG program printed its
  retriever's bearer token. Refusing to save a retriever that is not portable
  names its module instead of printing it.
- A client, retriever or tracker prints every header value as `[REDACTED]`,
  whatever the header is called (`X-Subscription-Token`, `Cookie`), and the
  query, fragment and user info of every URL, given as a string or a `%URI{}`.
  A saved program holds no header at all, so an LM with custom headers has to
  be rebound after loading, and `Imp.save!` refuses an LM whose `base_url` has
  a query, fragment or user info. Option errors, including those for the
  options passed to a call, name a credential-bearing option without printing
  its value. The ExMCP client's state, which a crash report prints, is redacted
  the same way. Before, a header was hidden only when its name looked like a
  credential, and `Imp.save!` wrote other headers' values to disk.
- RLM controller code cannot make a struct. A map literal that named
  `__struct__` was dispatched by every protocol as that struct: a map shaped
  like a `File.Stream` sent `Enum.join` into the `Enumerable` implementation
  for `File.Stream`, which read the named file. A map literal, `submit/1` and
  the result of a library call may no longer carry the key, and a library call
  takes no struct but a range or MapSet and no Elixir module named as a value.
  A module is not a value at
  all (`m = File` fails with `{:module_value_not_allowed, "File"}`); a sorter
  is `:asc`, `:desc` or a function, since an Erlang module given as a sorter
  had its `compare/2` called, and `Map.from_struct/1` takes no module; and a
  library call that hands back a function it was given (`Map.get(m, k, f)`)
  fails the turn instead of leaving a native closure in a variable.

### Installing

- Imp is a Hex package: `{:imp, "~> 0.5"}`. Every dependency comes from Hex,
  including ExMCP (`~> 1.5`, unpatched); the `deepfates/ex_mcp` Git fork, the
  bundled `vendor/ex_mcp` path and the `EX_MCP_PATH` override are gone.
- What 0.4.0 got from the fork now lives in Imp: stdio MCP servers in their
  own process group, a `PATH` without the release's own directories, and the
  HTTP options public servers need (no `Origin` header, a written `/` path
  kept, one retry with the standard `initialize` after a non-401 4xx on the
  era probe). What an upgrader meets:
  - erlexec is a direct dependency. It builds a C++ port program, and an OTP
    release that uses `Imp.MCP` or `Imp.ACP` lists
    `applications: [ex_mcp: :load, erlexec: :load]`.
  - Imp sets `SHELL=/bin/sh` in a VM started without `SHELL`, because
    erlexec's port program does not start without it.
  - Closing a stdio connection, or the death of the process that owns it,
    sends the server's group SIGTERM and SIGKILL one second later; 0.4.0 stopped
    the group without a SIGTERM a server could handle.
  - When a stdio server exits on its own, what is left of its group gets
    SIGKILL half a second later.
  - Trust for an authorized remote server is VM-wide: while a connection to it
    is open, its exact origin is in ExMCP's `trusted_origins`, so any ExMCP
    client in the VM may send credentials to that origin. In 0.4.0 the trust
    belonged to the one connection. The origin is removed when the last
    connection to it closes, and origins the host configured are left alone.

### MCP

- An MCP tool call that got no answer from its tool returns
  `{:error, %Imp.MCP.CallFailure{}}` instead of
  `{:mcp_tool_call_failed, server, reason}` or
  `{:mcp_connection_unavailable, server, reason}`. Its `outcome` says whether
  the call was refused before anything ran, its credential was refused (an
  HTTP 401 or a failed OAuth flow), it was never sent, or it was sent with no
  trustworthy answer (`:refused`, `:auth_refused`, `:not_sent`, `:unknown`);
  `reason` keeps ExMCP's error unchanged, and an exit is kept as
  `{:exit, reason}`.
- `Imp.Tool.outcome/1` gives the outcome of a tool call's value: `:result`
  when the tool answered, MCP error results included, unless the error result
  declares `structuredContent.outcome` as `"refused"`, `"auth_refused"` or
  `"unknown"`, which it then is (a server marks a write that may have been
  applied `"unknown"`). A value alone never reads as `:refused`, because a tool can
  return any term: ReActV2 and RLM decide a refusal where they refuse the call
  (an unknown tool, a malformed call, arguments that fail the schema, a tool
  policy, a host's authorization, submit outputs that do not fit) and record
  every call's outcome on its `:tool_result` event as `metadata.outcome`.
  `Imp.Tool.outcomes/0` lists the five.
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
  error term is unchanged. `Imp.Predict.ReAct`'s `:dspy` observations
  use the same words after `Execution error in <tool>: `, where they showed
  `inspect/1` of the reason.
- `Imp.MCP.connect/2` takes `pool_size:` (1 by default): that many
  connections are opened to each `http` or `sse` server, and each tool call
  borrows an idle one for the length of the call, so up to `pool_size` calls to
  one server run at once. One ExMCP client sends one HTTP request at a time, so
  without it a quick call waits behind a slow one to the same server. A call
  that finds every connection busy until its `:timeout` fails as `:not_sent`
  (`reason: :no_idle_connection`), and a call on a closed HTTP import fails as
  `:not_sent` with `reason: :not_connected` rather than a process exit. A
  `stdio` server keeps one connection whatever `pool_size` says: ExMCP already
  sends it several calls at once, and another connection would be another
  server process. The extra connections are dialed at once, so a server costs
  the import at most about three `:timeout`s. A connection whose call timed
  out, or whose caller died during the call, is replaced in the background
  rather than lent again while ExMCP still waits on that request, and is
  closed once that request is done, so the server finishes what it was doing;
  a replacement that cannot be dialed leaves the server a connection fewer.
- A call to an HTTP MCP server that asks for progress (`call_meta` with a
  `progressToken`) no longer loses its server-side work when the caller's
  `:timeout` passes. ExMCP ended such a request's stream a second after the
  call's timeout, and its server ended the tool with it: a 3 s write under a
  300 ms timeout never finished. The caller is answered at its
  `:timeout`, `:unknown` with `reason: :timeout`, and the request runs on to
  the connection's limit.
  `:call_meta` is still called in the process that makes the call.
- An HTTP MCP call can take as long as the import's `:timeout` allows. ExMCP
  ended every HTTP request at its own 30 s default whatever `:timeout` said,
  so a call to a tool that takes 33 s failed at about 30 s under
  `timeout: 45_000`. ExMCP's `request_timeout` is now the import's `:timeout`,
  and never less than 30 s.
- `"type" => "sse"` now means MCP's deprecated HTTP+SSE transport (2024-11-05):
  the descriptor's `"url"` is the event stream's (`https://host/sse`), and
  requests go to the URL the server names on it. Before, `sse` was Streamable
  HTTP with a standing GET stream, so a server that speaks only the old
  transport answered its first request with 405. It works with servers that
  name the session `sessionId` (the TypeScript SDK's, ExMCP's), not with the
  Python SDK's SSE servers (`session_id`): their dial fails with
  `:sse_endpoint_without_session_id` and a message saying to use `"http"`. A
  server that speaks Streamable HTTP is reached as `"http"`. An `sse`
  descriptor with `"headers"` or `"auth"` is refused
  (`:mcp_sse_credentials_refused`): the server names where requests go, and
  its credentials would go there whatever origin it named. Under
  `on_failure: :drop` only that server is left out, with a warning, and so is
  an `sse` URL with a query string (`:mcp_sse_url_refused`), which ExMCP would
  dial without it. An `sse` connection whose event stream ends (ExMCP ends it
  after a stretch with nothing on it, and does not reopen it) is replaced,
  rather than kept and lent; the stretch is at least 60 s and longer than a
  request can take.
- A caller of `Imp.MCP.connect/2` that dies while its import is connecting no
  longer leaves the connections already made open. They close with the import's `:owner`, which
  is the caller unless another process was named.
- `Imp.MCP.OAuth.begin/3` runs its own browser flow on ExMCP's public OAuth
  functions. Its `:flow` option is replaced by `:client_registration`
  (`:auto`, `{:pre_registered, client_id, client_secret}` or `{:cimd, url}`);
  a pre-registered client also names its `:client_issuer`, and the flow
  refuses to begin when the server names a different authorization server. A
  server with neither protected-resource nor authorization-server metadata is
  refused rather than given guessed `/authorize` and `/token` endpoints.
- A tool's name keeps the type it was given. `Imp.Tool.new/4` no longer turns a
  string into an atom that happens to exist, and tools imported from an MCP
  server are always named by the server's string. Lookups (`resolve_name/2`,
  tool policies) already compare names by text; code that matched an imported
  tool's name against an atom matches the string now.
- `Imp.ACP.start_link/1`, `Imp.ACP.run/1` and `Imp.ACP.Local.start_link/1`
  raise `ArgumentError` for an option they do not know, before anything
  starts; `Imp.ACP.Local` checks its `:agent_options` before it listens. In
  0.4.0 a key Imp did not know went to ExMCP, which handed it to the
  transport, so a misspelled `:permission_policy` or `:session_store` was
  silently ignored. The options are declared once and `Imp.ACP.start_link/1`
  documents them. A transport's own options go in `:transport_options`
  (`Imp.ACP.Local` passes its socket there), and `:capabilities` is no longer
  accepted beside `:agent_capabilities`.

### Runs

- A run no longer outlives its control process, and a cancellation that
  never returns no longer holds a run. When the control ends (its event
  sink's process died, or `Imp.Run.stop/1` was called while the run was still
  going), every cancellation registered by work in flight (an authorization
  decision being waited on, an RLM budget, an ACP terminal command) is called
  with `{:run_control_ended, reason}`, and then the task is killed; its
  monitor reports `:killed`. In 0.4.0 the task ran on until its next event and
  those effects were never cancelled. `Imp.Run.cancel/3` and
  `cancel_with_events/3` give the registered cancellations the cancel's
  `timeout` (5 s by default) and then end the task; the control ending, its
  owner going down, and work registered after a cancel give them 5 s. The
  cancellations are called at once, each in its own process, and one still
  running at the end of that time is abandoned. In 0.4.0 they were called one
  after another inside the control, so one that never returned held the run
  and made the cancel exit after 30 s. `Imp.Run.cancel/2` on a run whose
  control has already ended still exits (`:noproc`).
- `Imp.Run.start/3` takes `admission: {pool, limit}`: the run holds a place in
  the host's named pool instead of the machine-wide `:async_max_workers` pool,
  at most `limit` runs hold places in that pool at once, and a full pool
  returns `{:error, :busy}` without waiting. Runs started without it wait for
  the machine-wide pool as before.
- An `Imp.Run` event sink that raises, throws or exits is no longer ignored.
  The run's owner is sent
  `{:imp_run_event_sink_failed, run_id, %{sequence: _, kind: _, reason: _}}`,
  and delivery goes on with the next event. Stopping or cancelling a run
  reports the event the sink was holding the same way (`reason:
  :in_sink_when_stopped`, since it may have been stored), and each event after
  it, which the sink never received, as
  `{:imp_run_event_undelivered, run_id, %{sequence: _, kind: _}}`. Run owners
  receive these messages where they received nothing before; an owner with a
  strict `handle_info/2` needs clauses for them.
- `Imp.Run.start/3` raises `ArgumentError` for an option it does not know. In
  0.4.0 it ignored one, so a misspelled `:authorize` started a run whose tool
  calls nobody was asked about. Its options are declared once, and its
  documentation lists them; an invalid capture bound now raises from
  `start/3` instead of returning `{:error, {%ArgumentError{}, stacktrace}}`.
- `Imp.Run.Event.kinds/0` lists every event kind Imp emits. ReActV2 no longer
  emits a `:final` event: it carried the same prediction as the
  `:run_finished` event after it. A host may still emit kinds of its own with
  `Imp.Run.emit/2`.
- `Imp.Trajectory.to_atif/2` names the event that ended the run
  `extra.terminal_event` (it was `extra.outcome`), and a tool result's
  `extra.outcome` is the `Imp.Tool.outcome/1` its loop recorded (`"result"`,
  `"refused"`, `"auth_refused"`, `"not_sent"`, `"unknown"`) rather than
  `"returned"` or `"error"` read from whether the event carried an error. A
  stored event whose kind Imp does not know keeps its kind string instead of
  becoming `:other`.

### ReActV2, adapters and models

- Prompts name types in plain words instead of Python annotations, in every
  adapter and in ReAct: `` `team` (one of: atlas, harbor, beacon, quill) ``
  where 0.4.0 wrote `` `team` (Literal['atlas', 'harbor', 'beacon', 'quill']) ``,
  and "string", "integer", "number", "true or false", "list of strings",
  "object", "code in python" for `str`, `int`, `float`, `bool`, `list[str]`,
  `dict[str, Any]` and `Code_python`. "(must be formatted as a valid Python
  int)" is "(must be formatted as an integer)", and ReAct's `:dspy`
  mode lists tool arguments as JSON. Fields, order, constraints and parsing
  are unchanged. A saved program's prompt text changes with this, so an
  optimized program may be worth re-evaluating.
- Values in prompts take their JSON spelling: `null`, `true` and `false`
  where 0.4.0 wrote `None`, `True` and `False`, in inputs, demos, ReAct
  observations and field constraints. The structured-output schema sent to a
  provider is named `outputs` (title `Outputs`) instead of
  `DSPyProgramOutputs`. The MIPROv2 proposer's dataset summary shows each
  example as `{"inputs": {...}, "outputs": {...}}` instead of
  `Example({...}) (input_keys={...})`. GEPA's reflective dataset and SIMBA's
  program listing use the same words, so an enum shows its allowed values.
- A non-string answer for a string field is kept as its JSON text (`"true"`,
  `"[\"x\", \"y\"]"`) where 0.4.0 gave Python's `"True"` and `"['x', 'y']"`;
  a `null` is no value, so a required field reports it missing and an
  optional one is `nil`, where 0.4.0 gave the string `"None"`.
- A `null` answer for any output field with a declared default takes the
  default, as an omitted one does; 0.4.0 kept the null and failed "is
  required". A present non-null value, `""` and `[]` included, still wins
  over the default.
- InferRules shows the rule model each example's values as JSON text
  (`null`, `{"k": 1}`, `1500000.0`) instead of Elixir's `inspect` output, and
  a `Jason.OrderedObject` (a ReAct observation, for one) renders as JSON in
  its own order instead of as the struct.
- Each ReActV2 step lists the task's output fields with their types and
  descriptions ("The outputs to produce are: ..."). Before, a model saw an
  output's description only inside `submit`'s parameter schema.
- `Imp.Adapter.SingleField` names an untyped input's type (`- ticket
  (string)`), where it wrote empty parentheses.
- The names follow the glossary: a step answered in text ends as `:answered`,
  the last request of an interrupted turn as `:last_text` with
  `last_request_note`, the step signature declares `metadata[:text_field]`, and
  the tool list sent to a provider is the `:tools_sent` event.
- A ReActV2 or ReAct prediction's fields are the signature's outputs and
  nothing else. `history`, `termination_reason`, `termination_cause`,
  `termination_error`, `finished_by_tool`, `unexecuted_tool_calls` and
  `context_projection` are in `prediction.metadata`; in 0.4.0 they were
  fields, so an output named `history` collided with the loop's own. Read
  `prediction.metadata.history` where `Imp.get(prediction, :history)` was
  read.
- `termination_reason` says only how the turn ended: `:answered`, `:submit`,
  `:finished_by_tool`, `:last_text`, `:forced_submit`, `:extracted` (the
  tools-disabled extractor wrote the outputs; it was `:forced_submit` with
  `completion_mode: :typed_extraction`, and `completion_mode` is gone), or
  `:incomplete` (no answer; it was the failure itself, such as `:max_iters`
  or `:context_window_exceeded`). `termination_cause` is set whenever the turn
  was interrupted, including a forced submit that answered, where 0.4.0 left
  it out: the interruption that led to the last request. An `:incomplete`
  turn names the same interruption, unless its context window was full or
  its `Imp.Deadline` had passed, which are named instead, so a turn that hit
  `max_iters` and then ran out of time is `:deadline_exceeded`. `Imp.Predict.ReAct`
  follows the same rule: `:dspy` mode's extraction after `max_iters`, a
  parse failure or an empty step is `:extracted` with that cause, spelled
  `:parse_error` (it was `:parse_failure`), and `:provider_native` mode's
  `:direct` is `:answered` with `termination_cause: :empty_tool_calls`.
  `Imp.Prediction.complete?/1` is false exactly for `:incomplete`, and
  `Imp.Observability` reads it.
- `ReActV2` offers `submit` only to a signature that needs it. A task
  signature with exactly one output of type `:string` and no constraints gets
  no `submit` tool:
  a step that comes back as text with no tool call is the answer, in that
  one request, with `termination_reason: :answered`, which is how Anthropic's
  tool runner, the OpenAI Agents SDK, LangGraph's ReAct and Pydantic AI end a
  turn. Its history event carries the output, as a `submit`'s does, and the
  answer is not also emitted as a `:reasoning` event. A signature with several
  outputs, one non-text output, or one constrained text output (an `enum`, a
  pattern, an answer shape) keeps DSPy's `submit` unchanged, so the allowed
  values reach the model in its schema; a step of such a signature that
  writes text instead of calling `submit` is the `:empty_tool_calls`
  interruption, and a turn that ends without a valid `submit` is
  `:incomplete`.
- A step of a one-text-output signature that calls nothing and says nothing
  is an empty answer: the turn ends there with `termination_reason:
  :answered` and no further request, because saying nothing is how a model
  declines to answer.
- An interrupted turn of a one-text-output signature (the step limit, a
  failed request) makes one more
  request with the same tools as every step and `tool_choice: "auto"`, and its
  text is the answer, with `termination_reason: :last_text`
  and `termination_cause` naming the interruption (`:max_iters`,
  `:prediction_error`, `:parse_error`). A completion that says nothing is an empty answer rather
  than an error. A tool call the model makes on that request anyway is not
  run; the text is the answer and the calls are listed in
  `unexecuted_tool_calls`. If the process's `Imp.Deadline` has already
  passed, no request is made and the turn ends `:incomplete` with
  `termination_cause: :deadline_exceeded`.
- `last_request_note`, a string, puts one line of host text in front of the
  last request of an interrupted turn, the text-only request or the forced
  `submit`, as a user message, keeps it in the returned history, and is saved
  with the program. Imp writes no sentence of its own.
- `ReActV2` gains `finish_on`, a map from tool name to
  `fn arguments, result, inputs -> {:finish, outputs} | :continue end`. A tool
  named there ends the turn with the outputs the function returns, which are
  validated against the signature exactly as a `submit`'s are, with
  `termination_reason: :finished_by_tool` and `finished_by_tool` (in the
  prediction's metadata) naming the tool. This is the shape Pydantic AI calls an output tool: one call both does
  the work and carries the answer. `:continue` leaves the loop running. When a
  step calls several terminal tools, the first in call order finishes the run
  and the rest still execute and are recorded; a `submit` in the same step
  still wins. The functions persist by registry name, like a tool runner.
- A `ReActV2` step answered in plain text with no tool call is now a thought
  that called nothing, not a parse failure. It used to fail the chat parse and
  re-ask the whole prompt through `Imp.Adapter.JSON`, which doubled the cost of
  the step and broke the provider's prefix cache; the text is now
  `next_thought` and `tool_calls` is empty, which is what the turn-ending rule
  above then reads. The text is
  recorded as that turn's thought in the history and shown back to the model as
  a plain assistant turn in any next request. `Imp.Adapter.Chat` reads a
  marker-free completion this way only for a signature that declares
  `metadata[:text_field]`; every other signature parses exactly as before, JSON
  fallback included.
- ReActV2 preserves provider-native reasoning text and opaque reasoning details
  across tool calls and saved-history reloads. ReqLLM receives the original
  continuation data, including provider extension fields and signatures, instead
  of losing it while rebuilding assistant messages. Operational history must be
  stored privately; run events and explicit diagnostic redaction still redact
  credential-shaped values.
- A `:model_request` event now records the whole request, not only its
  messages. Its metadata carries `:options`, the request options with the tool
  definitions removed, and `:tools_hash`, a SHA-256 of the canonical JSON of
  those definitions or `nil` when the request offered none. The definitions
  themselves are emitted once per run per distinct hash, as a new
  `:tools_sent` event whose input is the tool list as sent. A recorded run
  can now be reproduced call for call, without repeating an unchanging roster
  on every one. Both payloads are redacted like every other event.
- `Imp.LM.generate/3` takes `purpose:`, a name for what kind of call this is.
  It is recorded on the `:model_request` event's metadata as `:purpose` and is
  never sent to the provider, so a caller that makes more than one kind of model
  call can tell them apart on the record.
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
- `Imp.Adapter.Types.ToolCall.from_map/1` accepts `tool` as a spelling of the
  tool name, beside `name` and `recipient_name` (the arguments already accepted
  `arguments`, `args` and `parameters`). `%{"tool" => ..., "arguments" => ...}`
  is what a model emits when it writes a tool call as JSON instead of calling
  natively, and `Imp.Predict.ReActV2` now executes such a call instead of
  recording a malformed-call observation and spending another iteration on it.
- `Imp.Clients.ReqLLM` returns a response whose body carries a provider error
  as a failed request (`Imp.LMError`, below). OpenRouter relays an upstream
  provider's refusal as a successful HTTP response with an error object and no
  choices, which ReqLLM decodes to an empty message; read as a completion, a
  refused request was a model that said nothing.
- `Imp.Predict.ReActV2.new/3` documents its options.
- `Imp.predict/2`, `Imp.chain_of_thought/2` and `Imp.configure/1` raise
  `ArgumentError` for an option or setting they do not know, and document the
  ones they take. In 0.4.0 `Imp.predict(sig, temperature: 0)` built a program
  that ignored the temperature; a request option given at the top level (such
  as `:temperature`, `:max_tokens` or `:n`) is now refused with a message that
  says to put it under `config:`. Settings of a caller's own, such as a request
  id, go through `Imp.context/2`. Both check Imp's own settings the same way,
  so `:track_usage` and `:warn_on_type_mismatch` must now be booleans. ReAct,
  ReActV2, Avatar, CodeAct, ProgramOfThought, MultiChainComparison and
  `Imp.Optimizer.Avatar` give the same `config:` message.
- `:max_errors` and `:retriever` are no longer settings. Nothing read
  `:retriever`; give a retriever to the program (`Imp.rag/3`). `:max_errors`
  was read only by BootstrapFewShot, RandomSearch and COPRO, as the fallback
  for their own `:max_errors`; given none, they now use 10, the setting's old
  default, and their reports say `max_errors_source: :default` where they said
  `:settings` or `:teacher_settings`. `Imp.configure/1`, `Imp.context/2` and an
  optimizer's `:teacher_settings` refuse either key with a message naming where
  it belongs.
- `ReActV2`'s `submit` and a `finish_on` callback's outputs find a field by
  the text of its name. A string signature keeps a field name as a string
  when its atom did not exist yet, so outputs keyed by that atom were never
  found and the turn ended `:incomplete` with `missing_output_fields`.
- RLM controller code may call every function of `Enum`, `Keyword`, `List`,
  `Map` and `String` except `String.to_atom`, `List.to_atom`,
  `String.splitter`, `Enum.random`, `Enum.shuffle` and `Enum.take_random`, and
  may pass them anonymous functions and captures, which the interpreter runs
  under the cell's step and value budgets. Registered tools, `llm_query` and
  `submit` stay outside such functions; a function's patterns may pin a
  variable (`fn ^target -> ... end`). Without a module, the Kernel data
  functions `elem/2`, `to_string/1`, the `is_*` type checks, `length/1`,
  `map_size/1`, `tuple_size/1`, `byte_size/1`, `abs/1`, `round/1`, `trunc/1`,
  `div/2`, `rem/2`, `max/2` and `min/2` are available. Other calls return
  `{:function_not_allowed, ...}`. Assignment takes the same patterns as a
  function clause (`{a, b} = pair`, `[first | rest] = lines`), `[x | acc]`
  builds a list, and a `for` generator takes a pattern and a map
  (`for {key, n} <- counts`) and the `into:` and `uniq:` options. `into:` and
  `uniq:` were ignored, and `reduce:` is refused with
  `{:unsupported_for_option, :reduce, ...}`. A function held in a variable or
  written in place can be called directly (`f.(x)`,
  `(fn x -> ... end).(x)`), under the same rules as one a library call runs.
- RLM controller code that calls a value that is not a function (`g = 1;
  g.(1)`) fails that turn with `{:not_a_function, "g", 1}`, which the
  controller reads and repairs. It ended the whole call with
  `{:module_call_failed, Imp.Predict.RLM, ...}` whenever the variable's name
  was not already an atom. An unexpected error inside the interpreter now
  fails the turn the same way, as `{:interpreter_error, message}`.
- The RLM controller prompt names one reply shape, `{"reasoning", "code"}`,
  for every turn including the last, which calls `submit/1` from code. It
  also offered a bare JSON object of the outputs as a final answer, which a
  text reply never in fact got. The controller's first reply almost always
  failed to parse: gpt-5.4 sends several JSON objects in one reply (its
  action twice, or several actions written ahead of their outputs). Such a
  reply now runs the first object that carries code, as a REPL would.
- `max_preview_chars` bounds every RLM variable preview in characters. A
  list was previewed as its first `max_preview_chars` items, so after
  `lines = String.split(log, "\n")` on a 20,000-line log the controller's
  turn message grew from 2,351 to 89,312 bytes. A list, map, tuple or other
  term is now previewed as the first `max_preview_chars` characters of its
  printed form, with `length` or `size` beside it, as upstream previews
  `str(value)`; a map's preview shows its values, not only its keys. A
  variable holding a tuple, which could not be encoded into the turn message
  and ended the call, is previewed the same way, and so is an integer too
  long for the preview.
- RLM `max_recursion_depth` is one rule: the number of levels of child RLMs
  below the root. `recurse/2` already allowed a child at depth
  `max_recursion_depth`, but `rlm_query*` started one only below it, so the
  default of 1 gave `recurse/2` a child and `rlm_query` none. Both now allow
  one level by default; `max_recursion_depth: 0` makes `rlm_query*` a one-shot
  sub-LM query, as the standalone runtime's `max_depth=1` does.

### Signatures

- Numeric bounds are `minimum` and `maximum`, JSON Schema's names, in
  validation, in the JSON schema and in the rendered prompt, and a validation
  error's rule is `:minimum` or `:maximum`. `min` and `max` raise an
  `ArgumentError` naming the key to use; before, the documented
  `minimum`/`maximum` were ignored. Pydantic's `ge` and `le` still mean the
  same bounds.
- Constraint keys are read by one normalizer for validation, the JSON schema
  and the rendered prompt, so `"min_length"`/`"max_length"` given as strings
  now constrain validation and the schema too, as they already did the
  prompt.
- An `enum` constraint with atom members raises `ArgumentError` when the
  field is built, showing the string members to write instead. An answer
  arrives as text and a signature saves as JSON, so `enum: [:atlas]` failed
  every parse ("must be one of [:atlas, :harbor]"), and returning the atom
  would have made a program answer differently after `Imp.save!`/`Imp.read!`.
- A signature refuses a repeated field name, on one side or across the arrow,
  and names it: the string form raises a signature parse error, the map
  form and `Imp.Signature.extend/3` raise `ArgumentError`, and `:a` and `"a"`
  are the same name. Before, only a name on both sides of the arrow raised,
  and `"q -> a, a"` built two fields called `a`.
- `json_retries: n` makes up to n retries of a parse failure, each the
  original request plus the latest failure's message, and stops at the first
  reply that parses. Before, any n above 0 made one.
- An arity-3 metric receives `nil` as its trace from `Imp.evaluate/4` and the
  optimizers' validation scoring, and the program's trace while an optimizer
  bootstraps demos, as DSPy's `trace=None` has it. Before, evaluation passed
  the trace too, so a ported metric that scores continuously when evaluated
  and passes or fails when compiling gave its compile-time answer.
- `Imp.read!/2` and `Imp.load!/2` load a saved program in a VM that never
  created the atoms it names: a demo's field names, a RAG program's `query_field` and
  `context_field`, a memory retriever's document keys, tool names and tool
  policies, and any atom tag in saved metadata load as strings when the atom
  does not exist, and no atom is created. `Imp.Example`, `Imp.Prediction` and
  the tool index look them up by text; a caller reading saved metadata
  directly may find `metadata["my_flag"]` where it expected
  `metadata[:my_flag]`, which is `nil` in a VM where `:my_flag` does not
  exist yet. It raised `ArgumentError` ("not an already existing
  atom"), so a router saved by one process failed to load in a fresh one.

### Errors and shapes

Every change here is breaking for code that matches on the old shape.

- A failed request from `Imp.Clients.ReqLLM` is
  `{:error, %Imp.LMError{}}`, whatever failed: an HTTP error status, an error
  relayed inside a successful response, a connection that failed, or an
  exception raised inside ReqLLM, or a response or stream of a shape ReqLLM
  never returns. It carries `status`, `retryable` and
  `context_window_exceeded`, with ReqLLM's own error unchanged under
  `reason`. `retryable` is `true` for a 408, 425, 429 or 5xx status, for a
  request that never reached the provider (connection refused, no free
  pooled connection, closed or timed out before sending), for any other
  status whose ReqLLM error says `retryable: true`, and for a timeout while
  waiting for the answer or a stream that failed after it started; those
  last two may have run and been billed, and a retried stream repeats chunks
  the caller already has. A 409 is never retryable. In 0.4.0 these reached
  the caller as ReqLLM's structs, as `{:req_llm_generate_failed, text}`,
  `{:req_llm_stream_failed, text}`, `{:invalid_req_llm_response, text}` or
  `{:invalid_req_llm_stream, text}`, or, for a context-length refusal, as
  `Imp.ContextWindowExceededError`, which is gone. An option the client refuses raises `ArgumentError` before the
  request, as every other option error does.
- `Imp.Errors.retryable?/1` reads `Imp.LMError`'s `retryable`, and the new
  `Imp.Errors.context_window_exceeded?/1` its `context_window_exceeded`, each
  through `{:error, _}` and `{:lm_failed, _, _}`. In 0.4.0 `retryable?/1` was
  true only for an `Imp.LMError` that nothing built.
- An LM client that raises is `{:lm_failed, client, exception}` with the
  exception struct, and one that throws or exits is
  `{:lm_failed, client, {kind, value}}`. In 0.4.0 both were the message text.
  The same holds for `{:module_call_failed, module, reason}` from
  `Imp.call/2`, `{:retriever_failed, _, reason}`, `{:tool_error, tool,
  reason}`, `{:tool_policy_error, tool, reason}`, `{:parallel_program_failed,
  reason}`, `{:ensemble_program_failed, reason}`, `{:optimizer_failed,
  optimizer, reason}` and `{:optimizer_capabilities_failed, optimizer,
  reason}`, the MCP import's `:mcp_connection_failed` and
  `:mcp_tool_import_failed`, and `Imp.ACP`'s `:program_factory_failed`,
  `:input_mapper_failed`, `:output_renderer_failed`, `:before_turn_failed`,
  `:permission_policy_failed` and `:host_request_failed`, and for
  `{:http_transport_failed, transport, reason}` from `Imp.HTTP` (and so the
  training clients' `:training_transport_failed`, `:training_refresh_failed`
  and `:training_cancel_failed`, and `Imp.Retrievers.HTTP`'s
  `{:transport, reason}`),
  `{:embedding_provider_failed, provider, reason}` from `Imp.Embeddings`, and
  `Imp.Predict`'s `{:adapter_format_failed, adapter, reason}` and
  `{:adapter_lm_opts_failed, adapter, reason}`, and
  `{:program_runtime_error, reason}` from `Imp.Predict.ProgramOfThought` and
  `Imp.Predict.CodeAct`, whose model still reads the exception's message.
  Several of these carried text on one path and a term on another.
- A completion that cannot be read as the outputs is always
  `%Imp.AdapterParseError{}`, with a `kind`: `:malformed`, `:missing_fields`
  (`reason` is the missing names), `:invalid_fields`, `:unsupported_output`
  or `:other`; `kind` is required. In 0.4.0 an adapter could return the struct,
  `{:missing_output_fields, names}` or `{:unsupported_lm_output, raw}`, and
  `Imp.Adapter.TwoStep` `{:two_step_extraction_failed, reason, completion}`.
  `Imp.Predict.ReAct`'s final outputs follow the same rule: in 0.4.0 a missing
  output was `{:missing_output_fields, names}` and one of the wrong type an
  `%Imp.AdapterParseError{}` with no `kind`.
- `Imp.Predict` returns that struct, with `trace` (the redacted
  messages, the raw completion, and which output fields were read) and, for
  `n > 1`, `completion_index`. In 0.4.0 it returned
  `%{reason: {:error, reason}, trace: trace}`, and an `n > 1` failure
  `{:completion_parse_failed, index, reason}` inside it. Because of that map,
  a `ReActV2` step that could not be parsed was recorded as
  `termination_cause: :prediction_error`; it is now `:parse_error`.
- When the chat or XML adapter's JSON fallback makes its request and that
  request fails, `Imp.Predict` returns the LM's error. In 0.4.0 it
  returned the original parse failure with the LM error inside it.
  `Imp.Adapter.TwoStep`'s extraction request does the same: when it fails,
  the call returns that `Imp.LMError` (or `{:lm_failed, _, _}`), so a 429
  from the extraction model reads as retryable. In 0.4.0 it was
  `{:two_step_extraction_failed, reason, completion}`.
- A failure reason that holds a pid, port or reference, such as a
  `GenServer.call` timeout, is written to JSON (optimizer checkpoints and
  reports, `Imp.History.dump/1`) as its inspected text. Before, the write
  raised `Protocol.UndefinedError`.
- `Imp.Predict.Refine` and `Imp.Predict.Assertions` return
  `{:error, reason}` like every `Imp.Module`: `:no_attempts` with `n: 0`
  (`max_attempts: 0` for `Assertions`), `{:refine_fail_count_exceeded, reason}`,
  or the last
  attempt's reason. In 0.4.0 they returned `{:error, reason, history}`, which
  `Imp.call/2` reported as `{:invalid_module_result, module, text}`.
- A tool a tool policy does not allow is `{:tool_denied, tool, :tool_policy}`,
  and a tool a run's `:authorize` callback refuses is
  `{:tool_denied, tool, reason}` with the callback's reason. In 0.4.0 they
  were `{:tool_denied, tool}` and `{:tool_authorization_denied, tool, reason}`.
- MCP import refusals: a tool named after one in `:reserved_tool_names` is
  `{:mcp_tool_name_reserved, tool, servers}` (it shared
  `:mcp_tool_name_collision` with two servers offering one name); an
  unauthorized descriptor is `{:mcp_server_not_authorized, server, answer}`,
  where `answer` is what `:authorize` returned or `:not_trusted`; a descriptor
  that cannot be addressed is `{:invalid_mcp_server, index, %ArgumentError{}}`
  (it was `:mcp_connection_failed` with the message and no name); and a
  server left out under `on_failure: :drop` carries the same reason term the
  import would have refused with, where 0.4.0 shortened its detail to text.
- `Imp.HTTP.request/6` and `Imp.Retrievers.HTTP` refuse a method they cannot
  send as `{:http_method_not_supported, refuser, method}`; one of them said
  `{:unsupported_http_method, method}`.
- `Imp.stream/3` without `provider_stream: true` ends a failed call with
  `%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}`,
  as a provider stream does; it yielded a bare `{:error, reason}`.
- An `Imp.Telemetry` span's `[:exception]` event carries `:kind`, `:reason`
  and `:stacktrace`, as `:telemetry.span/3` does; it carried `:error` as text.
  `Imp.Redaction` keeps an exception's type while redacting its fields.
- `Imp.optimize!` raises `Imp.Error` with the reason `Imp.optimize` would
  have returned when optimization fails, and `ArgumentError` only for a call
  that could never run (including options the optimizer refused). In 0.4.0
  every failure was an `ArgumentError` carrying text. `Imp.Error` is now that
  exception; nothing raised it before.
- `Imp.Example` and `Imp.Prediction` keep each key as the atom or string it
  was given, and look keys up by their text. In 0.4.0 a string key became an
  atom whenever that atom already existed in the VM, so the same data could
  come back keyed either way. Data read from JSON now keeps its string keys:
  a history turn loaded with `Imp.History.load!/1`, or a demo field a
  signature does not declare in a saved optimizer artifact.
- A tool receives its arguments as a map with string keys, from every runtime
  (ReActV2 and its `finish_on` callbacks, ReAct, Avatar, CodeAct, RLM) and
  from `Imp.Tool.call/2`, which turns atom keys into strings at every depth.
  In 0.4.0 a key became an atom when that atom already existed in the VM, so
  the same tool could see either shape. Match on strings: `fn %{query: q}`
  becomes `fn %{"query" => q}`. Tool policies and `unexecuted_tool_calls` see
  the same string keys. The built-in tools follow: `Imp.ACP.Host`'s
  `fetch` tool and `Imp.Optimizer.Playbook.EquationSearch.solve_tool/0` read
  string keys only.

### Public surface: what is exported

- Gone, with what to use instead:
  - `Imp.MCP.Client`, `Imp.MCP.HTTPClient`, `Imp.MCP.StreamableHTTPClient`,
    `Imp.MCP.StdioClient`, `Imp.MCP.Catalog` and `Imp.MCP.import_tools`:
    `Imp.MCP.connect/2`, which returns the tools and one `cleanup`. A tool
    schema spelled `:input_schema` is no longer accepted; MCP's
    `"inputSchema"` is.
  - `Imp.ACP.MCP` and `Imp.ACP.MCP.Import`: `Imp.MCP.connect/2`, and
    `Imp.ACP.ToolKind.derive_all(import.annotations)` for `:tool_kinds`.
  - `Imp.Core.ToolCall` and `Imp.Core.ToolResult`, which nothing built, and
    `Imp.MCP.json_rpc_result` and `Imp.MCP.initialize_params`, which
    nothing called.
- No longer documented, because they are Imp's own machinery:
  `Imp.Clients.TRLProtocol`, `Imp.Optimizer.Utils`,
  `Imp.Telemetry.execute` and `span`, `Imp.Prediction.set_lm_usage`,
  `Imp.MCP.Connections.import_tools` (use `Imp.MCP.connect/2`), the
  transition functions of `Imp.Training.FastSlow.State`, and the `validate_*`
  option validators. `compile/N` on an optimizer that `Imp.optimize/3,4,5` or
  `Imp.train/4` runs is no longer documented either: call those, which take
  the same datasets and invocation options with one argument order.
  `KNNFewShot`, `Ensemble`, `Playbook` and `InstructionSearch` keep
  `compile`, because the facade does not run constructors or workflows.
- Now documented: `Imp.Deadline`, `Imp.Observability.Inspection` (what
  `Imp.Observability.inspect_artifact/2` returns, with `json_safe/1`),
  `Imp.Run.barrier/3`, `Imp.Run.new_event_id/1`,
  `Imp.Run.register_cancellable/1` and `unregister_cancellable/1`,
  `Imp.Tasks.async/1` and `async_nolink/1` (tasks that carry the caller's
  settings, run and telemetry context), and the modules public
  functions return or call: `Imp.Predict.RLM.SandboxSerializable`,
  `Imp.Optimize.Anything.Result`, `Imp.Optimizer.Parameter.Set` and
  `Imp.Optimizer.Parameter.Change`, and `Imp.Optimizer.GEPA.Callback`.
- `Imp.MCP`, `Imp.MCP.Connections`, `Imp.MCP.Import`, `Imp.MCP.CallFailure`,
  `Imp.ACP` and `Imp.ACP.ToolKind` are stable, and so are the LabeledFewShot,
  BootstrapFewShot, random search, KNNFewShot, COPRO, MIPROv2, GEPA, SIMBA,
  InferRules and Ensemble optimizers, `Imp.Optimizer.Artifact` and
  `Imp.Optimizer.Report`: stable means they do not break within 0.x without a
  deprecation. `Imp.ExternalCommand` and `Imp.Tasks` are experimental. The
  documentation lists the MCP
  and ACP modules in a group of their own instead of under experimental
  optimizers.
- An ACP agent started without `:agent_info` introduces itself as `imp` at
  Imp's version, not as `imp-acp` `0.1.0`.
- Plug is no longer a dependency of Imp. The demo MCP servers, its only user,
  are not in the package.

### Public surface: facade and behaviours

- `Imp.load/2` takes the map `Imp.dump/1` returns and gives `{:ok, program}`
  or `{:error, %ArgumentError{}}`; `Imp.load!/2` is its raising form.
  Reading a file `Imp.save!/2` wrote is `Imp.read!/2`, which was
  `Imp.load!/1`. `Imp.Saving` has the same four functions.
- `Imp.react/3` builds `Imp.Predict.ReActV2`, and `Imp.react_v2` is gone.
  `Imp.Predict.ReAct`, the earlier loop, has no facade name; its port of
  DSPy's `dspy.ReAct` is `mode: :dspy`, which was `:dspy_3_2_1`. A program
  saved with `"dspy_3_2_1"` still loads.
- `Imp.Predict.Predict` is `Imp.Predict`. It and `Imp.Predict.ChainOfThought`
  are stable.
- `Imp.Signature.ParseError`, which every signature constructor raises, is
  documented, with its `:input` and `:position` fields.
- `Imp.Retrievers.KNN` is deleted. It did not implement `Imp.Retrieve`, and
  `Imp.Retrieve.Memory` is the token-overlap retriever.
- The `compile` function of `Imp.Optimizer.BootstrapFewShotWithRandomSearch`
  is hidden, like the other optimizers'; `Imp.optimize/4` runs it.
- `Imp.Adapter.Types.Document`, `History`, `Citation` and `Type`, and
  `Imp.Datasets.Error`, are documented. `priv/public_api.json` now lists every
  packaged module, the `@moduledoc false` ones among `excluded_modules`.
- `Imp.LM` declares `generate(lm, messages, opts)`, where `lm` is the struct
  or the module it was given; `request/2` and `stream/3` stay optional. An LM
  is a struct or module implementing it. The `%{module: module, opts: opts}`
  map and a bare two-argument function, both deprecated in 0.4.0, are
  refused: at construction with the `:lm` option's error, and by
  `Imp.LM.generate/3` as `{:error, {:not_an_lm, lm}}`. The clients'
  `generate/2` is gone; call a client through `Imp.LM.generate/3`, as
  `Imp.LM.generate(Imp.Clients.ReqLLM.new(model), messages)`. `Imp.LM.Static.new/1` takes
  `:model`, the model a static client stands in for.
- `Imp.Retrieve` declares `retrieve(retriever, query, opts)`; a module
  retriever receives itself first, as an LM does. A two-argument function is
  still a retriever.

### Public surface: one name per idea

- MCP names a server descriptor a descriptor and a server's name
  `server_name`. `Imp.MCP.CallFailure` has `server_name`, `tool_name` and the
  descriptor's `index` where it had `server` and `tool`; an `unavailable` entry
  has `server_name` where it had `server`; `tool.metadata.mcp` gains `index`;
  `:authorize`'s two-argument context is `%{cwd:, descriptor:}`.
- One allow/deny vocabulary: `:allow` or `{:deny, reason}`, as `Imp.Run`'s
  `:authorize` and `Imp.ACP`'s `:permission_policy` already answer.
  `Imp.MCP.connect/2`'s `:authorize` returned `:ok` or `true`; a refused
  descriptor is now `{:mcp_server_not_authorized, server_name, reason}`, with
  `:not_trusted` for one outside `:trusted_servers`. A `:tool_policy` function
  returned `true`, `:ok` or `false`; a refused call is now
  `{:tool_denied, name, reason}`, where `reason` names what denied it:
  `:tool_policy` for a name or list policy, or the function's own reason.
  Any other answer refuses with `{:invalid_decision, answer}`.
  `Imp.ToolPolicy` is documented.
- DSPy's names for DSPy's ideas. `num_threads` is the concurrency option of
  `Imp.Evaluate`, `Imp.evaluate/4`, `Imp.Predict.Parallel`,
  `Imp.Predict.Search`, `Imp.Experiment`'s evaluation options,
  `Imp.Clients.ReqLLMBatch`, and the GEPA, MIPROv2, SIMBA, BetterTogether and
  BootstrapFinetune optimizers, where it was `max_concurrency`; COPRO, InferRules
  and random search already said `num_threads`. COPRO's
  `proposal_max_concurrency` is `proposal_concurrency`, as GEPA's is. `Imp.Predict.Refine` counts its attempts in `n`,
  as `Imp.Predict.BestOfN` and DSPy's `Refine` do, where it had `max_attempts`;
  a Refine saved with `"max_attempts"` still loads. `Imp.Predict.RLM` takes
  `max_iterations` only, DSPy RLM's name; `max_iters` was a second spelling.
- `Imp.Optimizer.RandomSearch`, `Imp.Optimizer.BootstrapRS` and
  `Imp.Optimizer.BootstrapFewShotWithRandomSearch` were three names for one
  optimizer; it is `Imp.Optimizer.BootstrapFewShotWithRandomSearch`, DSPy's
  class name. Its `candidates` and `demos_per_candidate` options, second names
  for `num_candidate_programs` and `max_bootstrapped_demos`, are gone.
- The ReActV2 loop's guidance key `finish_tool` is `submit_tool`, the tool it
  names. The step signature's `metadata[:text_step]` is
  `metadata[:text_field]`: it names the output field a text reply fills.
- A ReActV2 `:reasoning` event says `forced: true` where it said `forced?`,
  and names its step as `step:` where it said `turn:`: a turn is one call of
  the agent, and a step is one request inside it.
- `Imp.MCP.connect/2`'s `:credentials` option is `:credential_store`, the
  `Imp.MCP.OAuth.Store` a descriptor's `"credential"` is looked up in.
  `Imp.MCP.OAuth.Pending` has `server_url` where it had `resource_url`, the
  name `begin/3` and `authorization_header/3` give the same URL. Credentials
  already on disk load unchanged.
- An `Imp.Clients.MLXLMTrainer` `:runner` is called with `cwd:` where it was
  called with `cd:`, the name ACP, MCP and `Imp.MCP.connect/2` use.
- `Imp.Optimizer.GEPA.Callback` hooks take `(event, context)` only; a bare
  callback module's context is `nil`. A bare module's one-argument hooks were
  called and its two-argument ones were not.
- A ReActV2 agent loaded from a saved program asks the model what the agent it
  was saved from asked. Loading lost the step predictor's loop guidance, its
  request shape (`response_instruction: false`, `omit_empty_request: true`)
  and its tool roster's atom keys; they are rebuilt from the signature and
  tools. A host's own `:adapter_opts`, such as renderers, are functions and
  are not saved; pass them again.
- `Imp.load/2` given a string says to read a file with `Imp.read!/1`.
- One `load` contract: `load` returns `{:ok, value}` or `{:error, reason}`,
  `load!` raises, and `read!` reads a file. The `load` of `Imp.Signature`,
  `Imp.History` and `Imp.Optimizer.Report` raised, so each is now
  `load!/1`. `Imp.Clients.TrainingJob`'s `load` is `load!/2`, and its old
  `load!`, which read a checkpoint file, is `read!/2`.
  The dataset loaders that read a file are `read!`:
  `Imp.Datasets.GSM8K.read!/1`, `Imp.Datasets.HotPotQA.read!/1`,
  `Imp.Datasets.MATH.read!/1` and `Imp.Datasets.DataLoader.read!/3`.
  The `load` of `Imp.Datasets.Colors`, which builds examples from records and raises,
  is `load!/1`.

### Retrieval

- `Imp.Retrieve.Memory` (`Imp.memory/2`) returns only documents that share a
  word with the query, up to `k`. It returned `k` documents whatever they
  scored, so a document with no word in common came back with `score: 0`
  because it came first in the list.

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

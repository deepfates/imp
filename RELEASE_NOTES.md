# Imp v0.5.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
Declare a task as named inputs and outputs, call it like any other Elixir
program, measure it on examples, compile it with an optimizer, and run the
selected program under OTP.

This release puts Imp on Hex. It is `0.5.0` rather than a patch because the
install line changes, an OTP release that uses the protocol adapters lists one
more application, and ReActV2 and `Imp.MCP.OAuth` change shapes a program may
depend on.

## Install

```elixir
{:imp, "~> 0.5"}
```

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [protocol runtime in
releases](docs/PRODUCTION_OPERATIONS.md#protocol-runtime-in-releases).
Ordinary Imp startup starts no protocol endpoint.

`mix deps.get` and `mix hex.audit` report two cowlib advisories
(CVE-2026-43966, CVE-2026-43969). cowlib arrives only through ExMCP's
Cowboy server, and Imp's HTTP goes through Req, Finch and Mint. The first is
fixed one layer up: Cowboy 2.16.0 and later refuse a response header
containing CR or LF, and a fresh `mix deps.get` resolves Cowboy 2.19.0. The second is in the encoder
for an outgoing `Cookie` request header, which nothing in Imp's dependency
tree calls, and no cowlib release fixes it yet.

## Headline changes

- Imp depends on ExMCP 1.5 from Hex, unpatched. What Imp needed from the
  `deepfates/ex_mcp` fork now lives in Imp: stdio MCP servers that end with
  their connection, children included; a clean `PATH` for them inside a
  release; trust for authorized remote servers; the connection options public
  servers need; and the browser OAuth flow.
- `ReActV2` offers `submit` only to a signature that needs one. A task with
  exactly one text output ends its turn on a step that answers in text, and an
  interrupted turn makes one last request whose text is the answer instead of
  failing.
- `ReActV2` gains `finish_on` for tools whose call is the answer.
- `:model_request` events record the whole request, and tool definitions are
  emitted once per run as `:tools_sent`.
- An MCP tool call that got no answer says whether it was refused, had its
  credential refused, was never sent, or may have run (`Imp.MCP.CallFailure`,
  `Imp.Tool.outcome/1`), an error result that declares its outcome is read as
  declared, and a failed tool call reaches the model as plain text.
- A ReAct prediction's fields are its outputs; how the turn ended is metadata,
  in one vocabulary, with `Imp.Prediction.complete?/1`.
- `Imp.Run` and `Imp.ACP` refuse options they do not know, and
  `Imp.Run.Event.kinds/0` lists every event kind.
- A host names its own run pool and limit (`Imp.Run.start/3`'s `:admission`),
  and a failing run event sink is reported to the run's owner.
- `Imp.MCP.connect/2` takes `pool_size:`, so several calls to one HTTP server
  run at once, and an HTTP call can take as long as its `:timeout` allows.
- A run no longer outlives its control process, and a cancellation that never
  returns no longer holds a run.

## Breaking changes from v0.4.0

- Replace `{:imp, github: "deepfates/imp", tag: "v0.4.0"}` with
  `{:imp, "~> 0.5"}`. `EX_MCP_PATH` is no longer read.
- A release that uses `Imp.MCP` or `Imp.ACP` adds `erlexec: :load` beside
  `ex_mcp: :load`.
- Trust for an authorized remote MCP server is VM-wide. While a connection to
  it is open, its exact origin (`scheme://host:port`) is in ExMCP's
  `trusted_origins`, so any ExMCP client in the same VM may send credential
  headers to that origin without consent. In 0.4.0 the trust belonged to the
  one connection. No other origin is trusted, the origin is removed when the
  last connection to it closes, and origins the host configured are left
  alone. A host that runs other ExMCP clients it does not trust with those
  origins should know this.
- `Imp.MCP.OAuth.begin/3` no longer takes `:flow`; a pre-registered client is
  `client_registration: {:pre_registered, client_id, client_secret}` with
  `client_issuer:` naming the authorization server it belongs to. A server
  with no OAuth metadata at all is refused instead of given guessed endpoints.
- An `Imp.Tool` named with a string keeps the string, and tools imported from
  an MCP server are named by the server's string. Code that compared an
  imported tool's `name` to an atom compares it to the string.
- An MCP tool call that got no answer returns
  `{:error, %Imp.MCP.CallFailure{}}` instead of
  `{:mcp_tool_call_failed, server, reason}` or
  `{:mcp_connection_unavailable, server, reason}`. A call that reaches its
  `:timeout` is `%Imp.MCP.CallFailure{outcome: :unknown, reason: :timeout}`,
  answered at the timeout while the request runs on; a call to an HTTP server
  whose connections all stay busy until the timeout is `:not_sent` with
  `reason: :no_idle_connection`.
- `"type" => "sse"` is MCP's deprecated HTTP+SSE transport, and its `"url"`
  is the event stream's. In 0.4.0 it was Streamable HTTP with a standing GET
  stream; a Streamable HTTP server is now `"type" => "http"`. An `sse`
  descriptor with `"headers"` or `"auth"`, or with a query string in its URL,
  is refused before anything is dialed (`:mcp_sse_credentials_refused`,
  `:mcp_sse_url_refused`): the whole import under the default
  `on_failure: :refuse`, only that server under `on_failure: :drop`.
- When a run's control process ends while the run is still going, the task is
  killed after its registered cancellations are called; its monitor reports
  `:killed`.
- A run's owner can receive `{:imp_run_event_sink_failed, run_id, details}`
  and `{:imp_run_event_undelivered, run_id, event}`; an owner with a strict
  `handle_info/2` needs clauses for them.
- `Imp.Run.start/3`, `Imp.ACP.start_link/1`, `Imp.ACP.run/1` and
  `Imp.ACP.Local.start_link/1` raise `ArgumentError` for an option they do
  not know. A transport's own options for `Imp.ACP` go in
  `:transport_options`, and `:capabilities` is spelled `:agent_capabilities`.
- `Imp.predict/2`, `Imp.chain_of_thought/2` and `Imp.configure/1` raise
  `ArgumentError` for an option or setting they do not know. Request options
  such as `:temperature` go under `config:`; a setting of your own goes
  through `Imp.context/2`.
- `:max_errors` and `:retriever` are no longer settings, and
  `Imp.configure/1` and `Imp.context/2` refuse them. Pass `:max_errors` to
  BootstrapFewShot, RandomSearch or COPRO (10 when not given) and a retriever
  to the program.
- ReActV2 emits no `:final` event; `:run_finished` carries the prediction.
  `Imp.Trajectory.to_atif/2`'s `extra.outcome` is `extra.terminal_event`, and
  a tool result's `extra.outcome` is the recorded `Imp.Tool.outcome/1`
  instead of `"returned"` or `"error"`.
- A ReActV2 or ReAct prediction's fields are its outputs only: `history`,
  `termination_reason`, `termination_cause`, `termination_error`,
  `finished_by_tool`, `unexecuted_tool_calls` and `context_projection` are in
  `prediction.metadata`. `termination_reason` says how the turn ended, and a
  turn without an answer is `:incomplete` with `termination_cause` saying why;
  typed extraction is `:extracted` (no `completion_mode`), and
  `Imp.Predict.ReAct` spells `:parse_failure` as `:parse_error` and `:direct`
  as `:answered`. Use `Imp.Prediction.complete?/1` to ask whether a turn
  answered.
- For a signature with one `:string` output, `ReActV2` offers no `submit`
  tool, and a step answered in text with no tool call ends the turn.
- Errors have one shape per tag, with the reason as a term. A failed
  `Imp.Clients.ReqLLM` request is `%Imp.LMError{}` (with `status`,
  `retryable` and `context_window_exceeded`; `Imp.ContextWindowExceededError`
  is gone), and a completion that cannot be parsed is
  `%Imp.AdapterParseError{kind: ...}`, which `Imp.Predict` returns
  directly instead of `%{reason: {:error, _}, trace: _}`. A raise inside a
  client, program, tool, tool policy, retriever, optimizer or ACP callback
  keeps the exception struct where 0.4.0 kept its message.
  `{:tool_denied, tool}` is `{:tool_denied, tool, :tool_policy}`, and a run's
  `:authorize` refusal is `{:tool_denied, tool, reason}`; `Refine` and
  `Assertions` return `{:error, reason}`;
  `Imp.optimize!` raises `Imp.Error` for a failed optimization. The CHANGELOG
  lists every tag that changed.
- `Imp.Example` and `Imp.Prediction` keep string keys as strings. Code that
  read a field of data loaded from JSON with `map.field` or `map[:field]`
  reads it with `Imp.Example.get/2` or by its string key.
- `Imp.MCP.Client`, `Imp.MCP.HTTPClient`, `Imp.MCP.StreamableHTTPClient`,
  `Imp.MCP.StdioClient`, `Imp.MCP.Catalog`, `Imp.MCP.import_tools`,
  `Imp.ACP.MCP` and `Imp.Core.ToolCall`/`ToolResult` are gone.
  `Imp.MCP.connect/2` imports tools; `Imp.ACP.ToolKind.derive_all/1` gives an
  import's ACP tool kinds.
- A saved program holds no HTTP header, credential or not. An LM with custom
  headers (a routing header such as `x-tenant` included) sends requests
  without them after loading until it is rebound with `Imp.with_lm/2` or a
  scoped `Imp.context/2`.
- `Imp.save!` refuses an LM whose `base_url` has a query, fragment or user
  info.
- Prompts name types in plain words instead of Python annotations
  (`one of: atlas, harbor` where 0.4.0 wrote `Literal['atlas', 'harbor']`),
  values take their JSON spelling (`null`, `true`, `false`), and the
  structured-output schema is named `outputs`. A non-string answer for a
  string field is kept as its JSON text (`"true"`, not `"True"`), and a
  `null` answer is no value rather than the string `"None"`. Fields, order
  and parsing are unchanged, but a saved optimized program now sends
  different prompt text.
- An `Imp.Telemetry` span's `[:exception]` event carries `:kind`, `:reason`
  and `:stacktrace`, as `:telemetry.span/3` does, instead of `:error` as
  text.
- An optimizer's `compile/N` is no longer documented where `Imp.optimize` or
  `Imp.train` runs the optimizer; call those.
- `Imp.load!/1` reading a file is `Imp.read!/1`; `Imp.load/1` returns
  `{:ok, program}` and `Imp.load!/1` takes the dumped map.
- `Imp.react/3` builds ReActV2 and `Imp.react_v2` is gone.
  `Imp.Predict.ReAct`'s `mode: :dspy_3_2_1` is `mode: :dspy`.
- `Imp.Predict.Predict` is `Imp.Predict`.
- `Imp.Retrievers.KNN` is deleted; `Imp.Retrieve.Memory` retrieves by token
  overlap.
- An LM is a struct or module whose `generate/3` takes it first. The
  `%{module:, opts:}` map and a bare function are refused; so is a module
  that defines only `generate/2`. A retriever module's `retrieve/3` takes
  itself first.
- `Imp.MCP.CallFailure` has `server_name`, `tool_name` and `index`; an
  `unavailable` entry has `server_name`; `:authorize` returns `:allow` or
  `{:deny, reason}` and its context names the `descriptor`;
  `:credentials` is `:credential_store`.
- A `:tool_policy` function returns `:allow` or `{:deny, reason}`, and a
  refused call is `{:tool_denied, name, reason}`.
- `max_concurrency` is `num_threads` on evaluation, parallel, search, batch and
  optimizer options. `Refine`'s `max_attempts` is `n`; `RLM` takes
  `max_iterations` only. `Imp.Optimizer.RandomSearch` and `BootstrapRS` are
  `Imp.Optimizer.BootstrapFewShotWithRandomSearch`.

## Upgrade path

1. Change the dependency line, run `mix deps.get`, and commit `mix.lock`.
2. Add `erlexec: :load` to any release that lists `ex_mcp: :load`.
3. Replace `OAuth.begin/3`'s `:flow` with `:client_registration` if you used it.
4. Match MCP call failures on `%Imp.MCP.CallFailure{outcome: ...}` (a 401 is
   `:auth_refused`), compare imported tool names as strings, and give run
   owners clauses for `:imp_run_event_sink_failed` and
   `:imp_run_event_undelivered`.
5. Read a ReAct or ReActV2 prediction's `history` and `termination_*` from
   `prediction.metadata`, and match `termination_reason` against the new
   values.
6. Change `"type" => "sse"` descriptors for Streamable HTTP servers to
   `"http"`. A server that needs credentials is reached over Streamable HTTP;
   an `sse` descriptor takes none.
7. Match LM failures on `%Imp.LMError{}` (or ask `Imp.Errors.retryable?/1`
   and `Imp.Errors.context_window_exceeded?/1`), parse failures on
   `%Imp.AdapterParseError{kind: ...}`, and exception reasons on the struct
   rather than its text.
8. Rename `Imp.react_v2` to `Imp.react`, `Imp.Predict.Predict` to
   `Imp.Predict`, and `Imp.load!(path)` to `Imp.read!(path)`; give custom LMs
   and retriever modules the `generate/3` and `retrieve/3` that take the
   client first, and wrap an LM function in a struct that implements
   `Imp.LM`.
9. Rename `max_concurrency:` to `num_threads:` where you configure
   evaluation, optimizers or parallel calls; answer `:authorize` and
   `:tool_policy` with `:allow` or `{:deny, reason}`; match a refused tool
   call as `{:tool_denied, name, reason}`; read `server_name` and `tool_name`
   from MCP failures and absences. Call `Imp.Signature.load!/1`,
   `Imp.History.load!/1`, `Imp.Optimizer.Report.load!/1` and
   `Imp.Clients.TrainingJob.load!/2` where you called `load`, and
   `Imp.Clients.TrainingJob.read!/2` where you read a checkpoint file, and
   the datasets' `read!` where you called their `load(path)`.
10. Rebind the LM of any loaded program that relies on custom headers, and
    move a `base_url` query, fragment or user info into configuration the
    host supplies at load time.
11. Update telemetry handlers for `[:exception]` to read `:kind`, `:reason`
    and `:stacktrace`.
12. Re-evaluate saved optimized programs on held-out data, since their
    prompt text changed, and run your application smoke test against the new
    release; a one-text-output ReActV2 program now ends turns differently.

The [CHANGELOG](CHANGELOG.md) records every user-visible change in this
release. Generated module documentation is the complete API reference. Start
with `Imp`, `Imp.Signature`, `Imp.Module`, `Imp.Evaluate`, `Imp.Optimizer`,
`Imp.ACP`, `Imp.MCP`, and `Imp.Telemetry`.

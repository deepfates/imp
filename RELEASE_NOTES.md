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

## Headline changes

- Imp depends on ExMCP 1.5 from Hex, unpatched. What Imp needed from the
  `deepfates/ex_mcp` fork now lives in Imp: stdio MCP servers that end with
  their connection, children included; a clean `PATH` for them inside a
  release; trust for authorized remote servers; the connection options public
  servers need; and the browser OAuth flow.
- `ReActV2` offers `submit` only to a signature that needs one. A task with
  exactly one text output ends its turn on a step that answers in prose, and an
  interrupted turn makes one last request whose text is the answer instead of
  failing.
- `ReActV2` gains `finish_on` for tools whose call is the answer.
- `:model_request` events record the whole request, and tool definitions are
  emitted once per run as `:tools_sent`.
- An MCP tool call that got no answer says whether it was refused, never sent,
  or may have run (`Imp.MCP.CallFailure`, `Imp.Tool.outcome/1`), and a failed
  tool call reaches the model as plain text.
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
- A run's owner can receive
  `{:imp_run_event_sink_failed, run_id, details}`; an owner with a strict
  `handle_info/2` needs a clause for it.
- For a signature with one `:string` output, `ReActV2` offers no `submit`
  tool, and a step answered in prose with no tool call ends the turn. Code that
  matches on `termination_reason` meets three new values: `:answered`,
  `:last_text` and `:finished_by_tool`.

## Upgrade path

1. Change the dependency line, run `mix deps.get`, and commit `mix.lock`.
2. Add `erlexec: :load` to any release that lists `ex_mcp: :load`.
3. Replace `OAuth.begin/3`'s `:flow` with `:client_registration` if you used it.
4. Match MCP call failures on `%Imp.MCP.CallFailure{outcome: ...}`, compare
   imported tool names as strings, and give run owners a clause for
   `:imp_run_event_sink_failed`.
5. Change `"type" => "sse"` descriptors for Streamable HTTP servers to
   `"http"`. A server that needs credentials is reached over Streamable HTTP;
   an `sse` descriptor takes none.
6. Run your held-out evaluation and application smoke test against the new
   release; a one-text-output ReActV2 program now ends turns differently.

The [CHANGELOG](CHANGELOG.md) records every user-visible change in this
release. Generated module documentation is the complete API reference. Start
with `Imp`, `Imp.Signature`, `Imp.Module`, `Imp.Evaluate`, `Imp.Optimizer`,
`Imp.ACP`, `Imp.MCP`, and `Imp.Telemetry`.

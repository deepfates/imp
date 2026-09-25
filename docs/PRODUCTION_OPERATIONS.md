# Production Operations

This is the operational companion to the Learning Path. After a program has a
signature, examples, metrics, optimization, and any needed tools, this page
explains how to run it with live providers, bounded concurrency, observable
failures, and runtime-only credentials.

## Runtime Posture

Production applications should run Imp as an OTP application:

```elixir
Application.ensure_all_started(:imp)
```

Normal Mix releases and applications start dependencies automatically. The
explicit call matters for embedded scripts, Livebook setup cells, and unusual
host runtimes. Imp keeps lazy-start fallbacks only for script-style contexts
where the OTP application spec is unavailable. If the `:imp` application is
available but fails to start, Imp raises instead of creating shadow runtime
state outside supervision.

Supervised Imp runtime state:

- `Imp.Settings` owns global defaults. Prefer `Imp.context/2` for scoped
  overrides in request code and tests. Plain BEAM tasks keep ordinary
  process-local semantics; Imp-owned fan-out through `Parallel`, provider async,
  evaluation, and optimizer tasks inherits the caller's Imp context.
- `Imp.Cache` owns the ETS table used by the built-in response cache.
- supervised task owners hold linked async helpers, including provider async
  and parallel prediction fan-out.
- a separate unlinked task supervisor handles bounded workers whose callers
  own cancellation and result collection.
- host applications still own higher-level orchestration lifetimes and
  cancellation policy.

Calling settings/cache APIs before `:imp` is started attempts to start the
application, so lazy library use and supervised app use share the same ownership
path. Global settings are intentionally mutable and node-local. Use
`Imp.context/2` for request, test, or task scoped overrides; those overrides
live in the calling process and are restored after the function returns.

Cache entries live in an ETS table owned by `Imp.Cache`. A cache owner
crash/restart recreates the table and loses cached values by design.
`fetch_or_store/2` coalesces concurrent misses per key while unrelated keys
continue independently. The owner monitors the active producer and promotes a
waiting caller after a producer crash; coalescing, retries, and producer
failures have dedicated redacted telemetry events.

Provider access uses `Imp.req_llm/2`, which delegates provider
catalogs, Req/Finch transport, streaming, structured-output negotiation, and
provider-specific option translation to `ReqLLM`. Imp does not maintain a
parallel OpenAI-compatible provider client stack.

## Secret Handling

The library avoids persisting provider secrets in saved program JSON.

Security-sensitive defaults:

- saved provider clients load without serialized credentials
- saved training-job checkpoints contain lifecycle state and checksums but no
  transport or API key; both must be reinjected explicitly on load
- dispatch journals serialize callers using the same path within one BEAM node,
  bind provider/model/endpoint/method semantics and job idempotency identity,
  and refuse credential-bearing job locators; their atomic rename and checksum
  cover ordinary process interruption, not adversarial writers, power loss, or
  filesystem failure
- custom provider endpoint configuration must be explicit and must not silently
  bind ambient provider credentials
- provider clients use real transport by default; tests use injectable
  transports and ExUnit tags instead of hidden provider fallbacks
- Databricks vector-search retrievers require explicit `token:` for explicit
  endpoint URLs and do not silently bind ambient `DATABRICKS_TOKEN`
- default `:httpc` transport verifies TLS peer certificates
- default `:httpc` transport applies finite HTTP timeouts unless overridden
- unknown external keys are not converted with `String.to_atom/1`
- prediction, program, ReAct, CodeAct, and RLM traces redact common
  secret keys and secret-shaped values
- ReAct-family and RLM programs support tool policies

Operational advice:

- never commit `.env`
- rotate keys that were pasted into logs, screenshots, or shared artifacts
- prefer short-lived provider keys for CI and demos
- use explicit `api_key:` or environment variables at runtime, not saved state
- treat MCP, retriever, training, and provider URLs as trusted configuration;
  Imp does not provide a network egress sandbox or private-IP SSRF guard

## Telemetry Events

Imp emits redacted `:telemetry` events through `Imp.Telemetry`.
Every span carries a stable `call_id`; a nested span also carries the enclosing
`parent_call_id`. Imp propagates that lineage through its supervised task boundary, so module,
evaluation, optimizer, LM, tool, retriever, MCP, and training work can be
reconstructed without installing mutable callbacks in program structs. Attach
handlers with `:telemetry.attach/4` or `:telemetry.attach_many/4`; a
`callbacks:` setting is rejected because it would otherwise imply observation
that never occurs.

Use `Imp.trace/2` to capture selected redacted runtime events around one
operation without installing telemetry handlers manually. Use
`Imp.inspect_history/2` for a redacted rendering of recent signature-shaped
turns. Long-running optimizer UIs can call
`Imp.subscribe_optimizer_progress/1` and detach the returned handle with
`Imp.unsubscribe_optimizer_progress/1`.

`Imp.disable_logging/0` and `Imp.enable_logging/0` control only logs emitted
through `Imp.Observability.log/3`; they do not mutate the host application's
global Logger level. Log metadata is redacted before emission.

## Deployment Reference

`examples/deployment` is a packaged OTP reference application. It loads a
checksummed program artifact during supervised startup, resolves callback names
through a host-supplied callback allowlist, obtains provider configuration from runtime
environment variables, and serves calls through a GenServer. The accompanying
test executes the same server with a deterministic LM and registry-backed
artifact.

Stable event families:

- `[:imp, :module, :start | :stop | :exception]`
- `[:imp, :evaluate, :start | :stop | :exception]`
- `[:imp, :optimizer, :start | :stop | :exception]`
- `[:imp, :lm, :start | :stop]`
- `[:imp, :lm, :stream, :start | :chunk | :stop]`
- `[:imp, :adapter, :parse, :retry | :error]`
- `[:imp, :cache, :hit | :miss | :coalesced | :retry | :producer_down | :producer_exception]`
- `[:imp, :tool, :start | :stop | :exception]`
- `[:imp, :retriever, :start | :stop | :exception]`
- `[:imp, :training, :submit | :refresh | :cancel, :start | :stop | :exception]`
- `[:imp, :optimizer, :trial, :start | :stop | :exception]` (RandomSearch,
  COPRO, SIMBA, and MIPROv2 candidate evaluations)
- `[:imp, :optimizer, :progress]` (GEPA generations)

Event metadata is redacted before dispatch. Secret-shaped values and common
secret keys are replaced with `[REDACTED]`.

## Live Provider Setup

Configure `OPENAI_API_KEY` and `OPENAI_MODEL` in the host application's secret
store, then exercise the application's own bounded live smoke before rollout.


## Protocol integration and migration

`Imp.ACP` serves an Imp program to an ACP (Agent Client Protocol) client, and
`Imp.MCP` imports tools from MCP (Model Context Protocol) servers. Ordinary Imp
boot starts its supervision without starting ExMCP. Protocol use
starts ExMCP explicitly; listeners, subprocess servers, and remote connections
require an explicit caller. `Imp.ACP.run/1` reserves stdout
before application boot; release launchers must likewise keep logs on stderr.

For remote capabilities, prefer an explicitly owned import:

```elixir
server = %{"name" => "account", "type" => "http", "url" => "http://127.0.0.1:4400/mcp"}
{:ok, imported} = Imp.MCP.connect([server], trusted_servers: [server], owner: self())
program = Imp.react_v2("question -> answer", imported.tools, lm: lm)
# Run the program while its connection owner is alive.
imported.cleanup.()
```

The exact server descriptor must be authorized. Host-supplied command, URL,
headers, environment and working-directory claims remain untrusted input.

A descriptor is a local `"stdio"` server (a `"command"` Imp starts) or a remote
`"http"` (Streamable HTTP) or `"sse"` server (a `"url"`). `"sse"` is MCP's
deprecated HTTP+SSE transport and has limits: it takes no credentials (below),
no query string in its URL, and works only with servers that name the session
`sessionId`, as the TypeScript SDK's do; the Python SDK's SSE servers fail to
dial. Reach a server as `"http"` when it offers Streamable HTTP.
`Imp.MCP.Connections` documents every descriptor key and option.

A stdio server runs as the leader of its own process group. Closing its
connection, or the death of the process that owns the connection, sends the
group SIGTERM and then SIGKILL one second later, so a server that ignores EOF
and SIGTERM, and any children it started, end with it. When the server exits
on its own, what is left of its group gets SIGKILL half a second later. A
descendant that starts
its own session (`setsid`) leaves the group and is not reached. The server
starts with only `HOME`, `LANG`, `LOGNAME`, `PATH`, `SHELL`, `TEMP`, `TMP`,
`TMPDIR`, `TZ`, `USER`, the certificate-path variables and `LC_*` from the host,
plus the descriptor's own `env`; inside an OTP release, the release's own
directories are removed from that `PATH`.

ExMCP refuses credential headers to any HTTP origin not in its VM-wide
`config :ex_mcp, :security, trusted_origins: [...]`. While a connection to an
authorized remote server is open, Imp adds that server's exact origin
(`scheme://host:port`) to the list and removes it when the last connection to it
closes; origins the host configured itself are left alone. If the process that
keeps this list crashes, its restart removes every origin it had added, so
open connections to those servers are refused until they reconnect rather than
trusted with nothing tracking them. For that time any
ExMCP client in the VM may send credentials to that one origin, and to no
other. No `Origin` header is sent, and a URL written with a `/` path is posted to
at `/`.

One server that cannot be reached fails the whole import, which is what a
caller that needs all of its tools wants. A long-lived host whose servers are
independent passes `on_failure: :drop` instead: a server whose transport or
`initialize` fails, which accepts the connection and never answers, or which
cannot answer `tools/list`, is closed and left out, `imported.unavailable`
carries `%{server: name, index: index, reason: reason}` for it, and the rest of
the catalog is imported. Match absences on `index` — the position of the
descriptor in the list that was passed in — and print `server`: two descriptors
may carry the same name, and one without a name is reported as `"unnamed"`.
Dropping covers the connection and `tools/list` only — a descriptor
`:authorize` refused, one whose declared `auth` cannot produce a header (a
`bearer_env` variable declared `required` and unset, say), a malformed one, and
anything the caller's own `:tool_filter` raises still refuse the import. The
exceptions are an `"sse"` descriptor that carries credentials (below) or has a
query string in its URL: it is left out as an unreachable server is.

Each dial is bounded by `:timeout` on its own, so a host that accepts the
connection and then answers nothing — a firewall dropping packets, a wedged
proxy — costs that server its timeout and no more. A server can cost up to
about three dials (the first, one retry with the standard handshake when the
server refuses ExMCP's opening probe, and the extra connections of
`pool_size:`, which are dialed together), so budget a boot that dials n servers
at about `3 * n * :timeout` in the worst case.

`pool_size:` (1 by default) opens that many connections to each `"http"` or
`"sse"` server, so up to that many calls to one server run at once; ExMCP's
client sends one HTTP request at a time. A call is answered at its `:timeout`
as `%Imp.MCP.CallFailure{outcome: :unknown, reason: :timeout}` while its
request runs on, and a call that finds every connection busy until then is
`:not_sent` (`reason: :no_idle_connection`). A `stdio` server keeps one
connection. `Imp.MCP.Connections` has the details.
Imported clients follow `:owner` (the importing process by default); a temporary
import worker should name its long-lived owner explicitly. Cleanup is idempotent.
Closed-client calls return errors rather than exiting their callers.

`Imp.MCP.HTTPClient.new/2`, `StreamableHTTPClient.new/2`, and
`StdioClient.new/2` are convenience constructors backed by the same ExMCP
importer. They connect during construction and return `Imp.MCP.Client`;
close them with `Imp.MCP.Client.close/1`. Connection failures raise at
construction; use `connect/2` for tagged error handling. A stdio server stays
alive across discovery and calls until cleanup or owner death; code that needs
a fresh process per operation opens and closes a catalog per operation. Cancelling a call requests cancellation; a noncooperative server can
continue remote work until its connection owner closes it. Cancellation is not
rollback.

The constructor options `:transport`, `:transport_opts`, `:protocol_version`,
`:session_id`, `:max_attempts`, `:retry_delay`, `:max_retry_after`, and
`:idempotency_key` are rejected, not ignored: ExMCP owns framing, negotiation,
sessions and retries. Test the boundary against an actual local MCP server. `:headers`, `:timeout`,
`:result_mode`, ownership and catalog-filter options are supported; stdio
also accepts `:args`, `:env`, and `:cwd`.

Known interoperability limit of ExMCP 1.5: when an HTTP server selects legacy
version `2025-03-26`, the initial `notifications/initialized` request can still
carry the client's `2025-11-25` header. Later requests use the selected version,
but a strict older server may reject establishment. Current version peers and
stdio do not have this particular limitation. ExMCP's connection manager must
settle the HTTP version before sending that notification before compatibility
with strict older HTTP servers can be claimed.

Imported tool calls explicitly disable generic transport retries and use
ExMCP's `:safe_only` broken-stream policy. An ambiguous write is not repeated.
Applications needing replay must establish a real server idempotency contract
and deliberately use the protocol client's API; a stable request ID alone is
not such a contract. Imp has no backoff or Retry-After options of its own. Discovery errors are returned to the caller, which
can decide whether to retry a new import.

Tool errors return `{:error, {:mcp_tool_error, original_envelope}}`, retaining
`content`, `structuredContent`, error codes and operation identifiers, so
refusal, authorization refusal and indeterminate effect outcomes the tool
reports remain distinguishable. The model reads only the text of an error
result's content (`Imp.MCP.failure_text/1`); the recorded term keeps the whole
envelope.

A call that got no answer from its tool returns
`{:error, %Imp.MCP.CallFailure{outcome: outcome, reason: reason}}`. `outcome`
is `:refused` (a JSON-RPC parse error, invalid request or method not found,
or a 4xx status other than 401), `:auth_refused` (a 401 or a failed OAuth
flow: the credential was refused and nothing ran),
`:not_sent` (the request never left) or `:unknown` (it was, or may yet be,
delivered, with no trustworthy answer: a timeout, a closed connection after
sending, a 5xx status, a handler that crashed or timed out on the server,
invalid params, which a server can send after its tool ran).
`reason` is ExMCP's own error, unchanged. An error result that declares
`structuredContent.outcome` as `"refused"`, `"auth_refused"` or `"unknown"`
(a server marks a write that may have been applied `"unknown"`) has that
outcome. `Imp.Tool.outcome/1` reads the outcome of any tool call's value, and
ReActV2 and RLM record each call's outcome on its `:tool_result` event as
`metadata.outcome`, deciding a refusal where they refused the call rather than
from the term. A timeout is always `:unknown`: ExMCP's client
sends one HTTP request at a time from its own process, so a call that timed
out waiting behind another is still sent afterwards.

Each imported tool carries `metadata.mcp` with `server_name`, `tool_name`,
`schema`, and `annotations`. These describe its original source, regardless of
its execution alias. Import results also index this provenance by execution
name. This metadata contains no server credentials or connection descriptor.

### Authenticating a remote MCP server

A descriptor may carry static `"headers"`. It may instead name an
auth kind, which Imp resolves to a header when the connection is built. The
resolved header is never written back into the descriptor, so the
authorization callback, `:call_meta`, and imported tool provenance never see a
credential.

OAuth, for a server a person authorizes in a browser — the official Readwise
server, or any MCP server with OAuth discovery:

```elixir
store = Imp.MCP.OAuth.store(directory: "~/.imp/mcp", secret: host_secret)

{:ok, pending} =
  Imp.MCP.OAuth.begin(store, "https://mcp2.readwise.io/mcp", credential: "readwise")

# Open pending.authorization_url in a browser on this machine. begin/3 is
# already listening on 127.0.0.1 for the redirect.
{:ok, "readwise"} = Imp.MCP.OAuth.await(pending)

server = %{
  "name" => "readwise",
  "type" => "http",
  "url" => "https://mcp2.readwise.io/mcp",
  "auth" => %{"type" => "oauth", "credential" => "readwise"}
}

{:ok, imported} =
  Imp.MCP.connect([server], trusted_servers: [server], credentials: store)
```

The grant is one encrypted file per credential under the directory the host
names. `Imp.MCP.connect/2` refreshes it when it is within a minute of expiry,
and also whenever the authorization server stated no usable lifetime at all,
using the stored refresh token and without asking the person again. When the
refresh token is gone — revoked, or already rotated — the error is
`{:mcp_oauth_reauthorization_required, credential}`, which a host can tell
apart from a transport failure worth retrying.

A grant is bound to the exact URL it was authorized for. A descriptor for a
different `"url"` that names the same credential is refused with
`{:mcp_oauth_credential_binding_mismatch, credential}` rather than handed the
token, so a credential cannot be pointed at another server.

A host that already owns an HTTP route for the redirect passes `redirect_uri:`
to `begin/3`, keeps the pending value, and calls `Imp.MCP.OAuth.complete/2`
with the callback parameters; it dispatches each callback to the right pending
value by `pending.state`. Otherwise `begin/3` opens a loopback listener on
`127.0.0.1` that answers only the redirect carrying this flow's `state` and
404s anything else, so a stray local request cannot consume it.

### The host secret

`Imp.MCP.OAuth.store/1` takes a secret, and the file encryption key is derived
from it. Generate 32 or more random bytes once — `:crypto.strong_rand_bytes(32)`,
or `openssl rand -base64 32` — and keep it for the life of the host: change it
and the stored credentials can no longer be read, and every server has to be
authorized again. Store it in a file with owner-only permissions next to the
credential directory, or in the host's environment. Never commit it, and never
log it.

`Imp.MCP.OAuth` says in full what that encryption protects (a copy of the
credential file taken without the secret) and what it does not (anyone who can
read the secret, the host's memory, or run code as the host's user). It also
says where a token can still appear despite this module: once the header is
handed to `ExMCP.Client` it lives in that client's transport state, and an OTP
crash report prints it — as it does for a static `"headers"` entry.

A bearer token the host reads from its own environment:

```elixir
server = %{
  "name" => "exa",
  "type" => "http",
  "url" => "https://mcp.exa.ai/mcp",
  "auth" => %{"type" => "bearer_env", "variable" => "EXA_API_KEY"}
}
```

When the variable is set, its value becomes `Authorization: Bearer <value>`.
When it is unset the server is connected with no `Authorization` header and
one warning naming the server and the variable is logged: a server that
answers anonymously with lower rate limits still works before the person has
found a key. Add `"required" => true` when the server is useless without the
key; the connection is then refused with a message naming the variable.

Both forms apply to `"http"` descriptors and may be combined with static
`"headers"`. An `"sse"`
descriptor (MCP's deprecated HTTP+SSE transport) takes neither: its server
names the URL requests are posted to, and ExMCP would send the credentials
there whatever origin it named, so such a descriptor is refused
(`:mcp_sse_credentials_refused`). Under `on_failure: :drop` only that server is
left out, named in `imported.unavailable` and logged; otherwise the import is
refused. Reach the server's Streamable HTTP endpoint with `"type" => "http"`
instead.

### Local ACP attachment

A long-running application can supervise `Imp.ACP.Local` with
`socket_path: "/short/private/path/acp.sock"` and `agent_options: [program_factory:
factory]`. Each connection receives its own ACP adapter. The factory can return
an `Imp.Module` wrapper for independently owned application work; the application
owns that work and its MCP connections. A plain predictor still belongs to its
ACP session and stops when that session closes.

Configure an ordinary ACP client to run the application's executable that calls
`Imp.ACP.Local.relay(socket_path)`. A release can expose this through its normal
`eval` command; relay execution must remain in the foreground with exclusive
stdio. This forwards existing ACP NDJSON without distributed Erlang or another
application protocol. Disconnect ends the relay and its attachment. The service
and other attachments remain alive. The relay ends on either stream's EOF.

The socket directory must be private; an absent directory is created with mode
0700 and the socket uses 0600. Use a short path within the operating system's
UNIX socket path limit. Existing paths are refused, including stale sockets;
remove one only after establishing independently that its owner is gone.
Graceful listener shutdown removes only its own socket. Both directions bound
frames to `:max_frame_bytes` (default 1 MiB); oversize input closes that
attachment. This is local same-user access, not an internet transport.

For independently owned work, `agent_options` may include
`on_cancel: fn program, session_metadata -> ... end`. It runs only for an
explicit cancellation of an active prompt, before the adapter stops its own
observer run. Return `:ok` only after the application has accepted cancellation;
ordinary session close and transport loss never call this hook. Any other return
or exception refuses cancellation and leaves the observer active. On the ACP
wire the pending prompt receives `stopReason: "refusal"` with
`_meta.imp_acp.failure` containing `category: "cancel_callback_failed"` and
`operation: "cancel"`. This describes refusal to cancel, not a model refusal or
proof that application work stopped. An application must keep independently
owned work observable after this prompt response; ACP has no separate
cancellation-error response for its notification.

### Protocol runtime in releases

Imp compiles against ExMCP but does not start its application during ordinary
prediction, evaluation or optimization. ACP entry points and nonempty MCP
connections start it explicitly, and the first stdio MCP connection starts
erlexec, which owns the server's process group. An OTP release using those
features must include `applications: [ex_mcp: :load, erlexec: :load]` in its
release definition; `:load` bundles the applications and dependencies while
preserving explicit startup. A release
that already depends directly on ExMCP includes it normally. Plain Imp users
need no protocol server or connection.

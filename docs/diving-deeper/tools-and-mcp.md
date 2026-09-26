# Tools and MCP

## Intent

A tool lets a program call Elixir code that a model chooses: the model sees a
name, a description and an argument schema, picks the tool, and supplies the
arguments; Imp checks them and runs the function. Tools come from your own
code with `Imp.tool/4`, or from MCP servers with `Imp.MCP.connect/2`, and
either kind goes into the same programs: `Imp.react/3`, `Imp.rlm/2`,
`Imp.code_act/3`.

MCP (the Model Context Protocol) is the standard way for a server to offer
tools to any model client. ACP (the Agent Client Protocol) is the standard
way for an editor or other client to talk to an agent. Imp speaks both: it
imports tools from MCP servers, and it serves an Imp program as an ACP agent.

Read this page to define tools, decide which calls may run, connect MCP
servers, tell apart the ways a call can fail, and put a program behind an ACP
client. For the loop that decides when to call tools, see [ReAct](react.md).

## Design decisions

### 1. A tool is a value you can call yourself

`Imp.tool(name, description, fun, schema: schema)` returns an `%Imp.Tool{}`:
a name, a description written for the model, a JSON-schema-shaped argument
contract, and a one-argument function. `Imp.Tool.call/2` runs it the same way
a program does, so a tool is tested like any other function, and code that
already knows which action to take calls it directly instead of asking a
model.

### 2. The schema is checked before the function runs

Arguments that fail the schema never reach your function: the call returns
`{:error, {:schema_validation, errors}}` or `{:error, {:missing_required,
keys}}`, and in a tool loop the model reads that error and can try again.
The check covers the argument's `type`, `required` keys, and each property's
`type`, `enum`, `minimum` and `maximum`. Anything deeper is your function's
to check.

A tool always receives its arguments as a map with string keys, at every
depth, whether they came from a model or from your own code: `Imp.Tool.call/2`
turns atom keys into strings too. Match on strings (`fn %{"team" => team}`).
Nothing a model sends becomes an atom.

### 3. Two separate questions: which tools, and this call

A tool policy is part of the program: which of its tools the model may call
at all. It is `:allow` (every tool), a list of tool names, or a function of
the tool name and arguments returning `:allow` or `{:deny, reason}`. A
refused call is not made; the model reads that it was not allowed, and the
loop records `{:error, {:tool_denied, name, reason}}` as the call's result.
A policy that raises, or returns anything else, refuses the call too, so a
broken policy never runs a tool.

Whether a particular call may run right now is the host's question, answered
per run: `Imp.start_run/3` takes `authorize:`, a function of each call that
answers `:allow`, `{:deny, reason}` or `{:cancel, reason}`, and an ACP client
is asked before each call (below).

### 4. "Did not happen" and "not known" are different outcomes

A tool that timed out may have done its work. A request that never left did
not. Collapsing the two is how a retry repeats a payment. So Imp never
retries a tool call on its own, and `Imp.Tool.outcome/1` reads any call's
result as one of:

| Outcome | Meaning | Safe to repeat? |
| --- | --- | --- |
| `:result` | the tool answered, possibly with an error of its own | the tool said what happened |
| `:refused` | declined before anything ran: unknown tool, bad arguments, a policy, an authorization, a server that rejected the request | yes; whether it would succeed depends on why |
| `:auth_refused` | the credential was refused before anything ran | after renewing the credential |
| `:not_sent` | the request never left | yes |
| `:unknown` | it may have run, and nothing says whether: a raise or exit in the function, a timeout, a dropped connection | check first |

### 5. An MCP server is authorized by what it is, not by what it is called

Imp dials only descriptors you approve: exactly, in `trusted_servers:`, or
through an `authorize:` function of the whole descriptor. A name proves
nothing, so a descriptor that says `"name" => "files"` but runs a different
command is a different server. Approval covers the command, URL, headers,
environment and working directory the descriptor carries.

### 6. Connections belong to a process

An import belongs to a process: the caller, or the one named by `owner:`. Its
connections close when you call `imported.cleanup.()` or when that process
ends, and a local server is stopped with everything it started. Nothing is
left running because a request crashed.

## API walkthrough

### Defining a tool

```elixir
on_call =
  Imp.tool(
    :on_call,
    "Look up the on-call engineer for a squad.",
    fn %{"team" => team} ->
      %{"atlas" => "Maya", "harbor" => "Tom", "beacon" => "Ines", "quill" => "Raj"}[team]
    end,
    schema: %{
      "type" => "object",
      "properties" => %{"team" => %{"type" => "string", "enum" => ["atlas", "harbor", "beacon", "quill"]}},
      "required" => ["team"]
    }
  )

Imp.Tool.call(on_call, %{team: "atlas"})
#=> "Maya"
```

A call that breaks the schema returns the error without running the function:

```elixir
Imp.Tool.call(on_call, %{})
#=> {:error, {:missing_required, ["team"]}}
```

Good names, descriptions and schemas matter: they are all the model knows
about the tool. `Imp.react/3` sends them to the provider as native tool
definitions.

### Tool policies

Pass `tool_policy:` to `Imp.react/3`, `Imp.rlm/2` or `Imp.code_act/3`.
`Imp.ToolPolicy.authorize/3` is the check they make. A policy function gets
the tool's name and the string-keyed arguments the tool would receive:

```elixir
policy = fn name, args ->
  if name == :on_call and args["team"] == "beacon",
    do: {:deny, :paged_directly},
    else: :allow
end

Imp.ToolPolicy.authorize(policy, :on_call, %{"team" => "beacon"})
#=> {:error, {:tool_denied, :on_call, :paged_directly}}
```

A name or list policy denies with the reason `:tool_policy`. In a ReAct loop,
`submit` is a tool like the others, so a list policy must include `:submit`
for the loop to finish with one.

### Connecting MCP servers

A descriptor is a map with string keys. A local server is a command Imp
starts, speaking MCP on its standard input and output:

```elixir
notes = Path.join(System.tmp_dir!(), "routing_notes")
File.mkdir_p!(notes)
File.write!(Path.join(notes, "squads.md"), "atlas owns money. harbor owns the platform.\n")

server = %{
  "name" => "notes",
  "command" => "npx",
  "args" => ["-y", "@modelcontextprotocol/server-filesystem", notes]
}

{:ok, imported} = Imp.MCP.connect([server], trusted_servers: [server])

read = Enum.find(imported.tools, &(&1.name == "read_text_file"))
Imp.Tool.call(read, %{"path" => Path.join(notes, "squads.md")})
#=> "atlas owns money. harbor owns the platform.\n"

imported.cleanup.()
```

`imported.tools` are ordinary `Imp.Tool` values; pass them to `Imp.react/3`
with your own. Each carries `metadata.mcp`: the descriptor's `index`, its
`server_name`, the `tool_name` the server published, its schema and its
annotations, and never a credential.

A remote server is `"type" => "http"` (MCP's Streamable HTTP transport) with
a `"url"`:

```elixir
server = %{"name" => "docs", "type" => "http", "url" => "https://mcp.example.com/mcp"}
```

The options you will reach for:

- `trusted_servers:` or `authorize:`, one of which is required. `authorize:`
  is `fn descriptor -> :allow | {:deny, reason} end`, or a two-argument
  function that also receives `%{cwd:, descriptor:}`. A refused descriptor
  fails the import with `{:mcp_server_not_authorized, server_name, reason}`;
  one missing from `trusted_servers:` has the reason `:not_trusted`.
- `timeout:` bounds each dial and each call.
- `on_failure: :drop` keeps the servers that answered when one does not.
  The default, `:refuse`, fails the whole import, which is what a program
  that needs every tool wants. Under `:drop`, a server whose connection,
  `initialize` or `tools/list` fails is closed and listed in
  `imported.unavailable` as `%{server_name:, index:, reason:}`. Match on
  `index`, the descriptor's position in your list: names need not be unique,
  and a descriptor without one is reported as `"unnamed"`. A descriptor that
  was refused, is malformed, or cannot build its credentials still fails the
  import: `:drop` forgives the network, not the declaration.
- `"tool_prefix"` in a descriptor names every tool from that server with the
  prefix, always. Without prefixes, two servers offering the same tool name
  fail the import with `{:mcp_tool_name_collision, tool, servers}`; Imp never
  renames a tool to make it fit, so a tool's name does not depend on which
  servers answered.
- `pool_size:` (1 by default) opens that many connections to each HTTP
  server, so that many calls to it can run at once. A call that finds every
  connection busy until its timeout fails as `:not_sent`, with the reason
  `:no_idle_connection`. A stdio server keeps one connection, which already
  handles concurrent calls.

Each dial is bounded by `timeout:` on its own. A server can cost up to about
three dials (the first, one retry with the standard handshake if the server
refuses the first probe, and the extra `pool_size` connections, dialed
together), so budget a boot that connects `n` servers at about
`3 * n * timeout` in the worst case. `Imp.MCP.Connections` documents every
key and option.

#### Local servers

A stdio server runs in its own process group. Closing its connection, or the
end of the process it belongs to, sends the group SIGTERM, then SIGKILL a
second later, so a server that ignores its input closing, and any children it
started, stop with it. A child that starts its own session (`setsid`) leaves
the group and is not reached.

The server sees only `HOME`, `LANG`, `LOGNAME`, `PATH`, `SHELL`, `TEMP`,
`TMP`, `TMPDIR`, `TZ`, `USER`, the certificate-path variables and `LC_*` from
your environment, plus the descriptor's own `"env"`. It runs in `cwd:`, the
current directory by default. Inside an OTP release, the release's own
directories are removed from its `PATH`.

#### Remote servers and credentials

A descriptor may carry static `"headers"`, or an `"auth"` entry that Imp
resolves to a header when it connects. The resolved header is never written
back into the descriptor, so your `authorize:` function, the tool metadata and
the logs never see a token.

A bearer token from the host's environment:

```elixir
server = %{
  "name" => "exa",
  "type" => "http",
  "url" => "https://mcp.exa.ai/mcp",
  "auth" => %{"type" => "bearer_env", "variable" => "EXA_API_KEY"}
}
```

When the variable is set, it becomes `Authorization: Bearer <value>`. When it
is not, the server is connected without one and a warning names the variable,
so a server that also answers anonymously still works. Add
`"required" => true` to refuse the connection instead.

ExMCP, the MCP client Imp uses, sends credential headers only to origins in
its VM-wide trusted list. While a connection to an authorized server is open,
Imp adds that server's exact origin (`scheme://host:port`) to the list, and
removes it when the last connection to it closes.

#### OAuth for third-party servers

This is experimental.

For a server a person authorizes in a browser, such as Readwise's, Imp runs
the OAuth flow and keeps the grant encrypted on disk:

~~~elixir
store = Imp.MCP.OAuth.store(directory: "~/.imp/mcp", secret: host_secret)

{:ok, pending} = Imp.MCP.OAuth.begin(store, "https://mcp2.readwise.io/mcp", credential: "readwise")
# Open pending.authorization_url in a browser on this machine.
{:ok, "readwise"} = Imp.MCP.OAuth.await(pending)

server = %{
  "name" => "readwise",
  "type" => "http",
  "url" => "https://mcp2.readwise.io/mcp",
  "auth" => %{"type" => "oauth", "credential" => "readwise"}
}

{:ok, imported} = Imp.MCP.connect([server], trusted_servers: [server], credential_store: store)
~~~

`begin/3` listens on `127.0.0.1` for the redirect and answers only the one
carrying this flow's `state`. A host that already has a route for the
redirect passes `redirect_uri:` and calls `Imp.MCP.OAuth.complete/2` with the
callback's parameters. `connect/2` refreshes a grant near expiry without
asking the person again; when the refresh token is gone, the error is
`{:mcp_oauth_reauthorization_required, credential}`, which is not a failure
worth retrying. A grant is bound to the URL it was authorized for, and naming
it from a descriptor with another URL is refused.

`host_secret` is 32 or more random bytes, generated once
(`:crypto.strong_rand_bytes(32)`) and kept for the life of the host: the
encryption key is derived from it, and a new one makes every stored grant
unreadable. Keep it out of the repository and the logs. `Imp.MCP.OAuth` says
what the encryption protects and what it does not.

#### The legacy SSE transport

`"type" => "sse"` reaches servers that speak MCP's older HTTP-with-SSE
transport, and only those that name the session `sessionId` in the URL they
tell the client to post to, as the TypeScript SDK's servers do. Python SDK SSE
servers fail to connect. An `"sse"` descriptor takes no `"headers"` or
`"auth"`: the server chooses where requests are posted, and credentials
would go wherever it said. It takes no query string in its URL either. Such
a descriptor is refused, or left out under `on_failure: :drop`. Use
`"type" => "http"` whenever the server offers Streamable HTTP.

### When a call fails

A tool that answers with an MCP error result has answered: the call returns
`{:error, {:mcp_tool_error, envelope}}`, keeping the server's `content`,
`structuredContent`, codes and identifiers. Its outcome is `:result`, unless
the server declares otherwise in `structuredContent.outcome` (`"refused"`,
`"auth_refused"` or `"unknown"`); a server that may have applied a write
before failing says `"unknown"`.

A call that got no answer from its tool returns
`{:error, %Imp.MCP.CallFailure{}}` with the `outcome`, the `server_name`,
`tool_name` and `index`, and ExMCP's `reason`:

```elixir
imported.cleanup.()

Imp.Tool.call(read, %{"path" => Path.join(notes, "squads.md")}) |> Imp.Tool.outcome()
#=> :not_sent
```

A timeout is always `:unknown`: the request may still be delivered after the
caller stopped waiting. Imported calls are never retried by the transport,
and a broken stream is not replayed, so an ambiguous write is not repeated.
`Imp.MCP.failure_text/1` is the sentence the model reads for a failed call;
a program's record keeps the whole term.

ReAct and RLM record each call's outcome on its `:tool_result` run event as
`metadata.outcome`, decided where the call was refused or sent. Read that for
a recorded call; use `Imp.Tool.outcome/1` for a value you hold.

A strict server that negotiates the older `2025-03-26` protocol version over
HTTP may reject the connection: ExMCP 1.5.0 sends its first notification with
the newer version header. Current servers and stdio servers are not affected.

### Serving a program over ACP

An ACP client, such as an editor with agent support, starts your agent as a
command and talks to it over standard input and output. `Imp.ACP.run/1` makes
an Imp program that agent:

~~~elixir
# agent.exs, started by the client as `mix run agent.exs`
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

Imp.ACP.run(
  program_factory: fn _session ->
    Imp.react(
      Imp.signature(
        "ticket -> reply: string, contact: string",
        "Find the on-call engineer for the squad that owns the ticket and write a one-sentence reply naming them. " <>
          "atlas owns money, harbor the platform, beacon identity, quill the product."
      ),
      [on_call],
      lm: lm,
      max_iters: 5
    )
  end,
  input_key: :ticket,
  output_key: :reply
)
~~~

Each prompt the client sends becomes the `ticket`; the `reply` goes back as
the agent's message. Before each tool call, the client is asked for
permission and shows the call. Given "We were charged twice this month.",
`gpt-5.4-mini` asked to run `on_call` with `%{"team" => "atlas"}`, got
`"Maya"`, and replied "The on-call engineer for atlas is Maya."

- `program_factory:` builds a program for each session and receives the
  session's `cwd`, `mcp_servers`, `session_id` and `meta`. Use `program:`
  for one immutable program shared by every session.
- `permission_policy:` decides tool calls: `:client` (the default) asks the
  client; `:unrestricted` asks no one and leaves the program's own tool
  policy in charge; a function returns `:allow`, `:client` or
  `{:deny, reason}`. Only a program that runs tools through a run's
  authorization (ReAct, RLM, or your own module with `execute/3`) can ask.
  The default policy refuses any other, a plain predictor included, with
  the failure `execution_capability_unsupported`; serve such a program with
  `permission_policy: :unrestricted`.
- `session_store:` is a directory where sessions are saved, so a client can
  load, list and resume them.
- `on_cancel:` runs when the client cancels an active prompt, for work your
  application owns outside the program. Return `:ok` only once that work has
  accepted the cancellation.

Standard output is the protocol. `Imp.ACP.run/1` silences logging before it
starts anything; a release that runs it must also keep its own logs on
standard error.

#### A long-running application as an agent

This is experimental.

`Imp.ACP.Local` lets a supervised application be the agent, with a thin
command as the client's entry point. Supervise
`{Imp.ACP.Local, socket_path: path, agent_options: [program_factory: factory]}`
and configure the client to run a command that calls
`Imp.ACP.Local.relay(path)`, for example through your release's `eval`. The
relay forwards the client's messages over a Unix socket; each connection gets
its own session, and a disconnect ends only that attachment.

The socket's directory must be private (it is created with mode 0700; the
socket is 0600), and the path must be short enough for the operating
system's socket-path limit. An existing path is refused, stale sockets
included. This is local, same-user access, not a network transport.

#### Releases

Ordinary Imp does not start ExMCP. Protocol use starts it when needed, and
the first stdio MCP connection starts erlexec, which owns the server's
process group. A release that uses MCP or ACP must bundle both:

~~~elixir
# mix.exs
def project do
  [
    app: :my_app,
    releases: [my_app: [applications: [ex_mcp: :load, erlexec: :load]]]
  ]
end
~~~

## Cross-links

- [ReAct](react.md): the loop that calls tools, and how a turn ends.
- [Modules and composition](modules-and-composition.md): RLM and CodeAct,
  which also take tools.
- `Imp.Tool`, `Imp.ToolPolicy`, `Imp.MCP`, `Imp.MCP.Connections`,
  `Imp.MCP.CallFailure`, `Imp.MCP.OAuth`, `Imp.ACP`, `Imp.ACP.Local`: the
  reference.

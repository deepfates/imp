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
  interrupted turn makes one last text-only request instead of failing.
- `ReActV2` gains `finish_on` for tools whose call is the answer.
- `:model_request` events record the whole request, and tool definitions are
  emitted once per run as `:tools_offered`.

## Breaking changes from v0.4.0

- Replace `{:imp, github: "deepfates/imp", tag: "v0.4.0"}` with
  `{:imp, "~> 0.5"}`. `EX_MCP_PATH` is no longer read.
- A release that uses `Imp.MCP` or `Imp.ACP` adds `erlexec: :load` beside
  `ex_mcp: :load`.
- `Imp.MCP.OAuth.begin/3` no longer takes `:flow`; a pre-registered client is
  `client_registration: {:pre_registered, client_id, client_secret}` with
  `client_issuer:` naming the authorization server it belongs to. A server
  with no OAuth metadata at all is refused instead of given guessed endpoints.
- An `Imp.Tool` named with a string keeps the string, and tools imported from
  an MCP server are named by the server's string. Code that compared an
  imported tool's `name` to an atom compares it to the string.
- For a signature with one `:string` output, `ReActV2` offers no `submit`
  tool, and a step answered in prose with no tool call ends the turn. Code that
  matches on `termination_reason` meets three new values: `:answered`,
  `:last_prose` and `:finished_by_tool`.

## Upgrade path

1. Change the dependency line, run `mix deps.get`, and commit `mix.lock`.
2. Add `erlexec: :load` to any release that lists `ex_mcp: :load`.
3. Replace `OAuth.begin/3`'s `:flow` with `:client_registration` if you used it.
4. Run your held-out evaluation and application smoke test against the new
   release; a one-text-output ReActV2 program now ends turns differently.

The [CHANGELOG](CHANGELOG.md) records every user-visible change in this
release. Generated module documentation is the complete API reference. Start
with `Imp`, `Imp.Signature`, `Imp.Module`, `Imp.Evaluate`, `Imp.Optimizer`,
`Imp.ACP`, `Imp.MCP`, and `Imp.Telemetry`.

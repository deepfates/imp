# Imp v0.4.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
Declare a task as named inputs and outputs, call it like any other Elixir
program, measure it on examples, compile it with an optimizer, and run the
selected program under OTP.

This release absorbs the protocol adapters that previously lived on `main`
only, and changes three published shapes. It is `0.4.0` rather than a patch
because a program written against `v0.3.2` can need edits.

## Install

`v0.4.0` is a Git source release from a public repository; no credentials are
required.

```elixir
{:imp, github: "deepfates/imp", tag: "v0.4.0"}
```

Imp is not published to Hex. Use a path dependency only while developing
against a local checkout.

ExMCP is declared `runtime: false`, so an OTP release that uses `Imp.ACP` or
`Imp.MCP` must list `applications: [ex_mcp: :load]` in its release
definition; see [protocol runtime in
releases](docs/PRODUCTION_OPERATIONS.md#protocol-runtime-in-releases).
Ordinary Imp startup starts no protocol endpoint.

## Headline changes

- `Imp.ACP` and `Imp.MCP.connect/2` are in the tag. The separate `imp_acp`
  package is retired with no compatibility shim: a consumer that depended on
  it now depends on `imp` alone. `Imp.MCP.connect/2` also gains OAuth
  credentials for remote HTTP servers (`Imp.MCP.OAuth`), `bearer_env`
  descriptor auth, `on_failure: :drop` with an `unavailable` list, and a
  per-dial timeout.
- `:reasoning_effort` is the one reasoning option on `Imp.Clients.ReqLLM`.
  `:openrouter_reasoning` is gone; the wire encoding is the separate
  `:openrouter_reasoning_wire`.
- ReActV2 sends the tool roster natively and no longer declares a `tools`
  input field or writes its instructions into `signature.instructions`. Loop
  guidance travels to the adapter through `:adapter_opts`.
- The `:model_response` event's `metadata.cost` is a plain USD float or `nil`,
  with any provider breakdown under `metadata.billing`.
- Structured values in a prompt render complete, the way DSPy renders a dict,
  instead of a truncated `inspect/1`.

## Breaking changes from v0.3.2

- Replace `openrouter_reasoning: ...` with `reasoning_effort: ...`. Saved
  programs allowlist `:reasoning_effort` and `:openrouter_reasoning_wire` in
  its place, so rebuild artifacts that carried the old key.
- A caller that passed or read ReActV2's `tools` input field no longer has
  one; the roster is sent natively.
- A host that read `metadata.cost` as a provider billing map reads a number
  now, and finds the map under `metadata.billing` when the provider sent one.

## Upgrade path

1. Rename the reasoning option and rebuild saved artifacts with `0.4.0`.
2. Drop any `tools` handling around ReActV2.
3. Sum spend from `metadata.cost` as a number.
4. If you depended on `{:imp, github: "deepfates/imp", branch: "main"}` for the
   adapters, move to the tag.
5. Run your held-out evaluation and application smoke test against the tagged
   dependency.

New in this release: [Benchmarks](https://github.com/deepfates/imp/blob/main/docs/BENCHMARKS.md)
and its [results table](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md)
carry every number this repository publishes with the command that produces it,
and the ticket-routing rows were re-measured live for this release, a month
after the first run, with both runs recorded.

The [CHANGELOG](CHANGELOG.md) records every user-visible change in this
release. Generated module documentation is the complete API reference. Start
with `Imp`, `Imp.Signature`, `Imp.Module`, `Imp.Evaluate`, `Imp.Optimizer`,
`Imp.ACP`, `Imp.MCP`, and `Imp.Telemetry`.

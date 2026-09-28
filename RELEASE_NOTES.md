# Imp v0.7.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
Declare a task as named inputs and outputs, call it like any other Elixir
program, measure it on examples, compile it with an optimizer, and run the
selected program under OTP.

This release makes the money a model call reports mean one thing, fixes
streamed calls through `Imp.Clients.ReqLLM`, and fixes reasoning efforts. It
is `0.7.0` rather than `0.6.1` because three of those fixes change what a
caller receives: a call's `cost` is `nil` where the provider reported no
charge, where it was ReqLLM's catalog estimate; a stream that did not
complete returns `{:error, %Imp.LMError{}}`, where it returned the text that
had arrived; and a streamed call's recorded model is the model id or the
model the provider reported, where it was the whole `"provider:model"`
string.

## Install

```elixir
{:imp, "~> 0.7"}
```

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

`mix deps.get` and `mix hex.audit` report two cowlib advisories
(CVE-2026-43966, CVE-2026-43969). cowlib arrives only through ExMCP's
Cowboy server, and Imp's HTTP goes through Req, Finch and Mint. The first is
fixed one layer up: Cowboy 2.16.0 and later refuse a response header
containing CR or LF, and a fresh `mix deps.get` resolves Cowboy 2.19.0. The second is in the encoder
for an outgoing `Cookie` request header, which nothing in Imp's dependency
tree calls, and no cowlib release fixes it yet.

Imp declares `mint` `~> 1.8`, as Finch does, and a fresh `mix deps.get` resolves `mint`
1.11.0. That release fixes three advisories but reuses HTTP/1 connections
that timed out; Imp's own lock holds 1.10.1. See Known limits for the choice
an application has.

## Headline changes

- `cost` on `Imp.Core.LMResponse` and on the `:model_response` event is the
  charge the provider reported, and `nil` when it reported none. OpenRouter
  reports its charge unasked, and Imp now reads it; a call made through
  OpenRouter with the caller's own provider key reports OpenRouter's fee plus
  the upstream charge. A provider whose response carries no charge (the
  Anthropic, OpenAI and Google APIs called directly among them) gives a `nil`
  `cost`. ReqLLM's catalog price is the new `estimated_cost`.
- A call streamed through `Imp.Clients.ReqLLM` (`Imp.stream/3` with
  `provider_stream: true`) records the usage and cost the provider reported;
  in 0.6.0 every such call was recorded with no usage and no cost. A stream
  that stops with a provider error, with finish reason `:error` or
  `:cancelled`, or with a body that ends before the provider finished, is an
  error, and the usage that arrived before it is still recorded. A streamed
  call to a client built from a spec map or a `{provider, opts}` tuple no
  longer fails.
- `:reasoning_effort` accepts every effort ReqLLM accepts, `max` among them,
  read from ReqLLM's own option. An effort given as a string, as every effort
  loaded from a saved program is, reaches ReqLLM as its atom; in 0.6.0 it
  failed every call on most providers, OpenRouter (without
  `openrouter_reasoning_wire: :nested`), Anthropic, Google and Groq among
  them.

## Upgrading from 0.6

1. Change the dependency to `{:imp, "~> 0.7"}`, run `mix deps.get`, and
   commit `mix.lock`. No dependency was added or removed.
2. Treat a `nil` `cost` as an unknown charge, not a free call. A host that
   wants the 0.6.0 number for a call with no reported charge reads
   `estimated_cost` (or `:estimated_cost` on the event), knowing it is an
   estimate; it is `nil` for a streamed call.
3. Where you call `Imp.stream/3` with `provider_stream: true`, handle
   `{:error, %Imp.LMError{}}` from a stream that did not complete as a failed
   call. The request reached the provider, so it may have been charged.
4. Where you match the model recorded for a streamed call (the `req_llm`
   metadata of its `:model_response` event, or its `Imp.Usage` key), expect
   the model the provider reported, or the configured model id without its
   provider prefix: `gpt-test` for `"openai:gpt-test"`, and the `Imp.Usage`
   key `"openai/gpt-test"`. A client built from a string-keyed spec map or a
   tuple now records its provider, streamed or not, so its `Imp.Usage` key
   is `"provider/model"` where it was the model alone.
5. Expect spend totals built on `Imp.Usage` or on `:model_response` events to
   grow: streamed calls now carry their usage and cost, and a streamed call
   that fails after the provider reported usage records it on its failed
   `:model_response` event and in `Imp.Usage`.

## Known limits

- The usage map (`:usage` on the `:model_response` event, `Imp.Usage`,
  `Imp.Prediction.get_lm_usage/1`) is ReqLLM's, unchanged. For a
  non-streamed call its `:cost` and `:total_cost` are ReqLLM's catalog
  estimate, not a charge, and OpenRouter's charge is its `"cost"`. Read money
  from `cost` and `estimated_cost`.
- An error the provider sends inside a stream has `status` `nil` and
  `retryable: true`, because ReqLLM's stream decoder keeps only its message;
  the same error in a non-streamed response may carry a status that says not
  to retry.
- `mint` 1.11.0 leaves an HTTP/1 connection open after a receive timeout,
  and Finch 0.23.0, the newest release, returns it to its pool with the
  unanswered request still on it. A later request the pool gives that
  connection waits behind the unanswered one and times out, and so does a
  retry that lands there, until the server answers the first request or
  closes the connection. If the late answer arrives while another request is
  waiting, Finch raises `CaseClauseError`. This affects every Req or Finch user on HTTP/1, the
  default for Req and ReqLLM, whose server can time out; ReqLLM spreads a
  host's requests over several connections, so there only the requests that
  draw the stuck one fail. With `mint` 1.10.1 a timeout closes the
  connection and the next request opens a new one, so Imp's lock holds
  1.10.1. It has three advisories that 1.11.0 fixes: EEF-CVE-2026-91043
  (high) and EEF-CVE-2026-92103 are in Mint's HTTP/2 client only, and
  EEF-CVE-2026-94194 is in HTTP/1 chunked framing and needs a malicious
  server behind an intermediary that reads the framing strictly. An
  application chooses one: add `{:mint, "~> 1.10.1"}` to its dependencies to
  lock 1.10.1 and keep those advisories, or take 1.11.0 and accept that a
  connection that timed out is reused until the server closes it. Finch has
  an open, unreleased fix (https://github.com/sneako/finch/pull/397); a Finch
  release that includes it ends the choice.
- A flat two-element name-first list that is not itself an element of a
  list (at the top level, in a tuple, or under a key that is not a credential
  name), such as `["password", "hunter2"]`, is not redacted, where 0.5.0
  redacted it. Such a list is read as a key and value only as an element of a
  list, so that lists of names such as `with_inputs([:api_key, :question])`
  survive saving.
- The GEPA, SIMBA, MIPROv2, InferRules and random-search checkpoints redact
  their failure reasons but otherwise hold the resume state as it is: GEPA's
  candidates, evaluation cache, proposed instructions and reflection data, and
  the others' instructions, demos and scores. Fast-Slow and Playbook
  checkpoints likewise hold their prompts, rollouts and playbooks. Treat
  checkpoint files as sensitive.
- A ReActV2 step whose prose quotes its own field names (a JSON object with
  `next_thought` or `tool_calls` keys, a `[[ ## field ## ]]` line, a
  `<next_thought>` tag) is not read as prose and goes to the JSON fallback,
  which usually costs one more call. If the model repeats the same reply, the
  step ends `:incomplete`. Beside native tool calls, such a thought becomes
  `nil`; the calls still run.
- When a streamed ReqLLM request fails, ReqLLM's own warning log prints the
  error with its response headers. Imp strips them from the error it returns,
  but cannot change that log line.
- In command output, a `Bearer` token of 12 to 15 characters, or one with no
  digit, is shown when more text or a newline follows it. 0.5.0's command
  pipeline hid any such token of 12 or more characters.
- A GEPA checkpoint taken between preparing and starting a full validation
  resumes by rejecting that candidate, as before.

The [CHANGELOG](CHANGELOG.md) records every user-visible change in this
release. Generated module documentation is the complete API reference. Start
with `Imp`, `Imp.Signature`, `Imp.Module`, `Imp.Evaluate`, `Imp.Optimizer`,
`Imp.ACP`, `Imp.MCP`, and `Imp.Telemetry`.

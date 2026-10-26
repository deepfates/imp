# Imp v0.18.1

Imp is a framework for typed, optimizable language-model programs on the BEAM.
Imp 0.18.1 is the 0.18.0 library as published to Hex (only the deployment
example's lock differs): 0.18.0 was tagged but never published, because a release gate failed on the tag (the deployment
example's lock did not match what `mix deps.get` writes). Everything below
describes the upgrade from 0.17.0.

This release changes the shape of the ATIF document's `extra.model_requests`,
so that an export of a long run no longer grows as the number of requests
times the length of the history. It also puts every resend of a model call
through `Imp.Clients.ReqLLM` in the run's record, changes the default wait for
a non-streamed call from 30 seconds to 10 minutes, and fixes redaction, task
pool timeouts, stream cleanup and an export that refused some runs. It
requires ExMCP 1.7.2, since every earlier release is retired for security
fixes. The ATIF change and the ExMCP requirement alter what a caller
receives, so under Imp's versioning rule this is a minor release.

## Install

```elixir
{:imp, "~> 0.18.0"}
```

`~> 0.18.0` takes later 0.18 patch releases and nothing newer. The two-part
form, `~> 0.18`, means `>= 0.18.0 and < 1.0.0` in Mix, so `mix deps.update
imp` under it takes every later 0.x release, including minor releases that
change what callers receive.

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.17.0

Change the Imp dependency to `{:imp, "~> 0.18.0"}`, run `mix deps.update imp`,
and commit `mix.lock`. No data migration is needed. Code that reads
`extra.model_requests[n]["messages"]` from `Imp.Trajectory.to_atif/2` must
read `message_ids` instead, and an application must resolve ExMCP 1.7.2 or
later (below).

- **Breaking: ATIF lists each message once.** `extra.model_messages` holds
  each distinct message the run sent, once, and each entry of
  `extra.model_requests` names its messages in order as `message_ids`,
  positions in `extra.model_messages` counted from 0, in place of `messages`.
  Request N sent exactly the messages at its `message_ids`. Since a request
  repeats the history before it, the old lists made the document, and the
  redaction over it, grow as requests times history: on a synthetic
  65-request run, `to_atif` went from 4.2 s to 0.41 s and the encoded
  document from 29 MB to 2.2 MB. Read the ids through a tuple
  (`elem(List.to_tuple(model_messages), id)`); `Enum.at/2` per id is
  quadratic on a long run. A request whose input was not a list keeps
  `messages`.
- **Fixed: ATIF keeps a tool call whose arguments are not a JSON object.**
  `to_atif` raised `ArgumentError` on such a run. The call is now kept with
  empty `arguments` and the recorded input in `extra.raw_arguments`.
- **Changed: resends are Imp's and are recorded.** `Imp.Clients.ReqLLM`
  turns ReqLLM's own retries off, for streamed and non-streamed calls, and
  sends a failed attempt again itself, up to `max_retries:` (3) times: a
  closed or refused connection at once, and a 429 or 529 after its
  `retry-after`. A request that timed out is never sent again. A stream is
  opened again only after a refused connection, a 429 or a 529, and only
  before its first chunk; one whose connection closed is not. Inside an
  `Imp.Run`, each resend is a new `:model_resend` event naming the call's
  `model_call_id`, so one `:model_request` no longer stands for several
  requests sent. A `retry-after` over a minute is not slept on: the call
  fails with the 429 or 529. Under a deadline, a resend that must wait is
  made only if 5 seconds would be left after the wait. A host that matches
  run event kinds exhaustively should accept `:model_resend`.
- **Changed: a non-streamed call with no deadline waits up to 10 minutes.**
  With no deadline and no `receive_timeout:`, a non-streamed
  `Imp.Clients.ReqLLM` call waited ReqLLM's 30 seconds; it now waits 10
  minutes. Set `receive_timeout:` or run under a deadline to wait less. A
  `ReqLLMBatch` dispatch gets the same `receive_timeout`, but is still ended
  by the batch's own `:timeout`, 30 seconds by default.
- **Fixed: a row's `:timeout` counts from when it has a pool place.** A row
  queued behind other Imp work was killed with `{:task_exit, :timeout}`
  without having run.
- **Fixed: streams inside rows.** A provider stream read by a row with
  `timeout: :infinity` inside another Imp task, or by an
  `Imp.Predict.Avatar` tool, no longer waits forever for a second place
  under `async_max_workers: 1`, and a stream whose reader is killed stops
  its program.
- **Fixed: redaction of session fields.** A key named `session` or ending in
  `_session` is redacted only when it holds a token-shaped string, so ids,
  titles and maps under it now survive in events, traces and reports. A
  framework session cookie held under its cookie name as a map key
  (`JSESSIONID`, `PHPSESSID`, `connect.sid`, `ASP.NET_SessionId`) is now
  redacted, and so is `session_key`.
- **Breaking: Imp requires ExMCP `~> 1.7 and >= 1.7.2`** (was `~> 1.5`).
  Every ExMCP release before 1.7.2 is retired on Hex for security fixes. An
  application that uses ExMCP directly should read ExMCP's 1.6.0 changelog.
  ExMCP now implements `Inspect` for its client and HTTP transport itself,
  and Imp defines none for them unless ExMCP is overridden with an earlier
  release. ExMCP's prints the transport's `base_url` whole, so a key in a
  server URL's query or userinfo shows when such a struct is inspected.
- **Changed: a refused opening probe shares one dial.** With ExMCP 1.6.0 and
  later, a server that refuses ExMCP's opening probe with HTTP 400, 404 or
  405 is sent `initialize` within the same dial, so in `Imp.MCP.connect/2`
  the probe and `initialize` share that dial's `:timeout`. Before, a 404 or
  405 got a second dial with a `:timeout` of its own.
- **Fixed: `Imp.MCP.Trust`** logs no error when a connection ends during VM
  shutdown.

Rollback means restoring `{:imp, "~> 0.17.0"}` and `0.17.0` in the lock,
with ExMCP back on 1.5.0: Imp 0.17.0 defines its own `Inspect` for ExMCP's
client and transport, which redefines ExMCP 1.6.0's and later. Exports then
list every request's messages again, resends go back to ReqLLM, unrecorded,
and a non-streamed call with no deadline waits 30 seconds again. See the
[changelog](CHANGELOG.md) for every change.

## Known limits

- The usage map (`:usage` on the `:model_response` event, `Imp.Usage`,
  `Imp.Prediction.get_lm_usage/1`) is ReqLLM's, with `input_includes_cached`
  added. Its `:cost` and `:total_cost` are ReqLLM's catalog estimate, not a
  charge, for streamed and non-streamed calls alike, and OpenRouter's charge
  is its `"cost"`.
  Read money from `cost` and `estimated_cost`.
- An error the provider sends inside a stream has `status` `nil` and
  `retryable: true`, because ReqLLM's stream decoder keeps only its message;
  the same error in a non-streamed response may carry a status that says not
  to retry.
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
- Tool images reach the model as user messages after the turn's tool
  responses, labelled with the call, not nested in the tool result, even for
  providers that accept images in tool results. Only MCP text and image
  blocks are converted; other block types stay text, image URLs in text are
  never fetched, and the selected model must accept image input of that
  format and size.
- ATIF's `extra.seen_by_model` and the read-as `content` come from matching
  a tool message in the next captured request. A result that request does
  not carry, including one that ended the run, keeps the tool's own output
  and is marked unseen. `agent.tool_definitions` comes only from `:tools_sent`
  events, and `final_metrics` totals are left out when any response lacks
  that figure.
- A streamed completion that the provider's content filter stops still ends
  as a completion: the stream's `finish_reason` is `:content_filter` and the
  filter's text has already arrived as chunks. Only non-streamed requests
  turn it into an `Imp.LMError`.
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

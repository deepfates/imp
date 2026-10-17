# Imp v0.16.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release adds `request_retry:` to `Imp.Run.start/3`, which sends a model
request the provider failed in a way that may pass again in the same run, after
a wait. It also changes two things a caller may rely on: an LM client other
than ReqLLM reports its charge as metadata `:cost`, because `Imp.Core` no longer
reads it from the usage map; and a ReActV2 forced `submit` with invalid
arguments goes to the extractor. A new option and changed behaviour make this
a minor release under Imp's versioning rule.

## Install

```elixir
{:imp, "~> 0.16.0"}
```

`~> 0.16.0` takes later 0.16 patch releases and nothing newer. The two-part
form, `~> 0.16`, means `>= 0.16.0 and < 1.0.0` in Mix, so `mix deps.update
imp` under it takes every later 0.x release, including minor releases that
change what callers receive.

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.15

Change the Imp dependency to `{:imp, "~> 0.16.0"}`, run `mix deps.update imp`,
and commit `mix.lock`. No data migration is needed. Check the second item if
you use an LM client of your own, or build response envelopes by hand.

- **Added: `request_retry:` on `Imp.Run.start/3`.** `request_retry: [waits:
  [ms, ...], reserve: ms]` sends a model request that failed with an error
  `Imp.Errors.retryable?/1` accepts (408, 425, 429, 5xx, a failed connection)
  again inside `Imp.LM.request/2`, after each wait in turn. Under a deadline
  the last wait repeats while it leaves `reserve` (60 s by default) of the
  deadline; without one, the list is the bound. A provider's `retry-after`
  longer than the wait is waited instead. Each attempt is its own
  `:model_request` and `:model_response`, and a failed response followed by
  another attempt carries `retry_in_ms`. Only the outermost request in a
  process retries, so an LM that wraps an LM does not multiply attempts.
  Streamed requests are not sent again. `waits` must not be empty. Off unless
  given. A timed-out attempt may have been finished and billed by the
  provider without a response to record, so a retry can be billed twice;
  under a deadline each attempt is capped to the time left.
- **Changed: where a call's charge is read.** OpenRouter bring-your-own-key
  billing moved into `Imp.Clients.ReqLLM`, which records the charge it
  resolves as `:charge` in its `req_llm` response metadata. `Imp.Core` reads
  `LMResponse.cost` from that `:charge` (final when present, `nil` included),
  and otherwise from metadata `:cost`; it no longer reads usage `"cost"` or
  `"is_byok"`. An LM client other than ReqLLM, or a hand-built response
  envelope, must report its charge as `:cost` in its metadata (or
  `req_llm.charge`), or its cost is `nil`.
- **Fixed: a forced `submit` with invalid arguments is extracted.** A ReActV2
  forced `submit` whose arguments fail validation now goes to the typed
  extractor and ends `:extracted`, where it ended `:incomplete` with no
  outputs. If that extraction request fails with an LM error, the call
  returns `{:error, %Imp.Predict.ReActV2.StepError{}}`, where it returned
  `{:ok, prediction}` ending `:incomplete`. A forced `submit` the tool policy
  refuses still ends `:incomplete`.

Rollback means restoring `0.15.0` in the lock and removing `request_retry:`.
See the [changelog](CHANGELOG.md) for every change.

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

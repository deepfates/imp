# Imp v0.13.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release changes what a tool loop's model reads. A ReActV2, ReAct or
Avatar history keeps each input, tool call and tool result exactly as it was,
where before anything credential-shaped in them was replaced by
`"[REDACTED]"` on every later step. A ReActV2 step whose answer is its plain
reply no longer presents that answer as a named output field. It also adds
three things a host can use: a ReActV2 call can give its own tool runners,
tool results record when they came back, and usage says whether a call's
input token count already includes the cached prompt. A caller's model
reads different requests, and a host that stores histories stores different
data, so under Imp's versioning rule this is a minor release.

## Install

```elixir
{:imp, "~> 0.13.0"}
```

`~> 0.13.0` takes later 0.13 patch releases and nothing newer. The two-part
form, `~> 0.13`, means `>= 0.13.0 and < 1.0.0` in Mix, so `mix deps.update
imp` under it takes every later 0.x release, including minor releases that
change what callers receive.

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.12

Change the Imp dependency to `{:imp, "~> 0.13.0"}`, run `mix deps.update imp`,
and commit `mix.lock`. No data migration is needed.

- **Histories keep what the model read.** `Imp.Predict.ReActV2`,
  `Imp.Predict.ReAct` and `Imp.Predict.Avatar` no longer run `Imp.Redaction`
  over each input, tool call and tool result as they add it to the history.
  Before, a result that only contained something credential-shaped, such as
  a quoted `curl -H "Authorization: Bearer ..."` or a JWT under discussion,
  was replaced whole by `"[REDACTED]"`, and the model read that placeholder
  on every later step instead of what the tool returned. Run events,
  telemetry, traces, `Imp.inspect_history/2` and saved artifacts still redact
  their own copies. Migration: a host that stores a history now stores what
  the model read. Store it privately, and use `Imp.History.redact/1` or the
  run's events for anything shown or shipped elsewhere. A history stored
  before this release keeps its `"[REDACTED]"` strings; the original text is
  not recoverable from it.
- **A plain-text ReActV2 step does not present its answer as a field.** In a
  ReActV2 step with one unconstrained text output and natively held tools,
  the answer is the message the model sends without a tool call. The Chat
  adapter's system message no longer lists that output under "Your output
  fields are:" or "The outputs to produce are:", and its agent and finish
  lines no longer name it. The finish line reads "When the final answer is
  ready, reply without calling a tool.", followed by the field's description
  if it has one. Models had been writing the field's name into the reply as
  a label, and the label became part of the answer. Parsing is unchanged, so
  a reply written in markers is still read. Signatures with `submit`,
  written tool calls, and the JSON and XML adapters are unchanged. A
  signature with no instructions of its own still opens with the default
  "Given the fields ..., produce the fields ...". Migration: a test that
  compares that system message exactly expects the new text.
- **Added: a ReActV2 call can give its own tool runners.** `Imp.call(react,
  %{..., tools: [tool, ...]})` uses, for that call only, the runners of the
  given tools in place of the program's, as a call can already give its own
  `max_iters`, `last_request_note` and `config`. Each tool must be one the
  program holds, with the same name, description and schema, so the request
  and its cacheable prefix are unchanged; anything else is refused before
  any request with `{:error, {:invalid_react_v2_tools, message}}`. The
  program value is not changed, and `with_tools/2`, the path an optimizer's
  updates take, still refuses a changed runner. A host can keep state that
  belongs to one call in that call's runners, so copies of one program
  called at once (by an optimizer, `Imp.parallel` or evaluation) never share
  it. See "One call's own tool runners" in the ReAct guide.
- **Added: tool results carry when they came back.** ReActV2 records
  `returned_at` (ISO 8601, UTC) beside each tool result in the history, and
  the Chat adapter passes it to a `:tool_result_renderer` as
  `%{id:, name:, returned_at:}` (`nil` for a result recorded without one,
  such as one in a history saved by an earlier release). Nothing is shown by
  default. A host that wants the model to know the time during a tool loop
  renders it there. The stamp is recorded once, so every later request
  carries the same bytes and a cached prompt prefix survives. GEPA leaves
  these times out of what its reflection model reads. Two runs of the same
  program no longer return equal histories.
- **Added: usage says whether input includes cached tokens.** A call through
  `Imp.Clients.ReqLLM`, streamed or not, carries `input_includes_cached` in
  its `usage`. OpenAI-style usage, as OpenAI and OpenRouter report it,
  counts cache reads inside the input tokens (`true`). Anthropic-style usage
  counts them apart (`false`). The flag is ReqLLM's own answer, the one it
  prices the call by, and a flag the provider's usage already carries is
  kept. The ATIF export's `prompt_tokens` for an Anthropic-style call now
  counts its cache reads and writes; before, it was only the tokens after
  the last cache breakpoint. A caller that matches a usage map exactly sees
  the new key.

Rollback means restoring `0.12.3` in the lock. Histories are then redacted as
they are built again, the plain-text step lists its output field again,
`returned_at` is no longer recorded (a renderer receives `nil`), usage
loses `input_includes_cached`, and a call that passes `tools` is not given
its own runners. Provider-free tests check that
the next request carries a tool result as the tool returned it, for each of
the three loops, along with the exact system message of a plain-text step,
the time a renderer receives, a call's own runners and the refusals of
tools shown differently, and the flag and ATIF prompt count for both
usage shapes. This release does not establish how any particular model
responds to the new system message.
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

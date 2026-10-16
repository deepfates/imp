# Imp v0.15.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release adds two ReActV2 options a caller opts into: `finish: :tools`,
which ends a turn only through a `finish_on` tool, for a program that acts
only through its tools, and `history_replay: :actions`, which shows earlier
turns without the text and reasoning written beside their calls. Programs that
use neither send byte-for-byte the requests 0.14.1 sent and save as before.
New options make this a minor release under Imp's versioning rule.

## Install

```elixir
{:imp, "~> 0.15.0"}
```

`~> 0.15.0` takes later 0.15 patch releases and nothing newer. The two-part
form, `~> 0.15`, means `>= 0.15.0 and < 1.0.0` in Mix, so `mix deps.update
imp` under it takes every later 0.x release, including minor releases that
change what callers receive.

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.14

Change the Imp dependency to `{:imp, "~> 0.15.0"}`, run `mix deps.update imp`,
and commit `mix.lock`. No code or data migration is needed: saved programs
without the new options load with their defaults.

- **Added: `finish: :tools`.** Only a `finish_on` tool ends a ReActV2 turn.
  There is no `submit`; the outputs come from the `finish_on` functions. A
  step that writes text and calls no tool is a thought, followed by one
  ordinary step and a line naming the ending tools (`unsent_note:` replaces
  it). Nothing is forced and no last request is made: a failed request gets
  one more ordinary step, once per turn and not on the last allowed step; a
  second thought in a row, a step that says nothing, the step limit or a
  second failure ends the turn `:incomplete`, with the request's error in
  `termination_error`, or `:deadline_exceeded` when the deadline has passed.
  A program with `finish: :tools` needs a `finish_on` tool and refuses
  `last_request_note` and `last_request_tools`. A call may give its own
  `finish:` (when the task has no input of that name), so a `:tools` program
  can ask for one text answer, such as a summary, with `finish: :auto`.
- **Added: `history_replay: :actions`.** Earlier turns are shown as their
  inputs, the calls with their results, and their outputs; the text and
  reasoning written beside the calls, and steps that only wrote text, are left
  out. The current turn is shown whole: it starts with the call's new inputs
  or its own `last_request_note`, or, on a resume with neither, at the last
  step that carries inputs. The returned history keeps every step. This
  diverges from DSPy's ReActV2, which replays every step whole; the default,
  `:trajectory`, still does. Some thinking APIs reject an earlier tool-call
  message without its reasoning content; check your provider.
- **Added: `unsent_note:`.** The line shown after each thought-only step, in
  place of Imp's. A blank line is refused.

Rollback means restoring `0.14.1` in the lock and removing the new options.
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

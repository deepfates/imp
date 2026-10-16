# Imp v0.14.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release adds two ReActV2 options a caller opts into: `last_request_tools`,
which lets an interrupted turn's last request still run named tools, and
`finish: :submit`, which ends a plain-text turn through `submit` as DSPy's
ReActV2 does. It also changes requests every ReActV2 program with one plain
text output sends: the finish line is worded differently, a forced `submit`
request no longer ends on the model's own message, and an extracted turn's
history now holds its answer. New options and a change to what callers'
models read and what hosts store make this a minor release under Imp's
versioning rule.

## Install

```elixir
{:imp, "~> 0.14.0"}
```

`~> 0.14.0` takes later 0.14 patch releases and nothing newer. The two-part
form, `~> 0.14`, means `>= 0.14.0 and < 1.0.0` in Mix, so `mix deps.update
imp` under it takes every later 0.x release, including minor releases that
change what callers receive.

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.13

Change the Imp dependency to `{:imp, "~> 0.14.0"}`, run `mix deps.update imp`,
and commit `mix.lock`. No data migration is needed: saved programs without
the new options load with their defaults.

- **Added: `last_request_tools`.** ReActV2 takes a list of tools whose calls
  run in the last request of an interrupted turn, for a signature with one
  unconstrained text output. Those calls run as any step's do, under the same
  tool policy and run authorization, and are recorded in the history; the
  turn then ends with the request's text as the answer. Calls to other tools
  are listed in `unexecuted_tool_calls` and not run. A program that acts
  through a tool and reports in text what it did can still take that action
  when a turn is interrupted. Each name must be a tool the program holds; a
  signature with `submit`, or `finish: :submit`, refuses the option. The
  default, `[]`, changes nothing. A call may give its own list, which replaces
  the program's for that call. A one-request call (`max_iters: 0`) is a last
  request, so a host asking for a summary gives `last_request_tools: []`.
- **Added: `finish: :submit`.** A one-unconstrained-text-output ReActV2 turn
  can end through `submit`, as DSPy's ReActV2 ends every turn, so text the
  model did not mean as its answer is not published as one. A step that
  writes a thought and calls no tool is followed by an ordinary step in which
  the thought stays the model's own message and a user message after it says
  "Your message above was not sent. To reply, call `submit` with `answer`; to
  keep working, call a tool." (naming the signature's outputs). A second
  thought-only step in a row, an empty step, or `max_iters` forces `submit`.
  The default, `finish: :auto`, keeps the current rule.
- **Changed: the plain-text finish line.** A plain-text ReActV2 step's system
  message now reads "When the final answer is ready, write it as plain text
  without calling a tool." where it read "... reply without calling a
  tool.", which a program holding a `reply` tool read as being about that
  tool. A provider's prompt cache for those programs misses once. Migration:
  a test that compares that system message exactly expects the new text.
- **Changed: a forced `submit` request no longer ends on the model's
  message.** When the step before it wrote a thought and called nothing, the
  request ended on an assistant turn, which Mistral and Gemini refuse. The
  request now shows that thought as its last user message under its field's
  marker; the history still records it as the model's step. A provider's
  refusal of the named `tool_choice`, including one OpenRouter relays, now
  gets the `"required"` retry and then the extractor instead of failing the
  call.
- **Changed: an extracted turn's history holds its answer.** An `:extracted`
  ReActV2 turn's history ends with the extracted outputs, recorded as a step
  that called no tool. Replaying such a history shows the model nothing for
  that step. A host that stores histories stores one more step for such
  turns.
- **Changed: no requests after the deadline.** Once the process's
  `Imp.Deadline` has passed, ReActV2 sends no forced `submit`, no
  `"required"` retry and no extraction request; the turn is `:incomplete`
  with `termination_cause: :deadline_exceeded`.
- **Fixed: a resume with no new inputs.** A ReActV2 call that resumes a held
  history with no new inputs, such as `max_iters: 0` with a
  `last_request_note`, and whose forced `submit` gets no `submit` back, now
  gets its answer from the extractor instead of failing with
  `{:missing_input_fields, [...]}`.

Rollback means restoring `0.13.0` in the lock. 0.13.0 loads a program
saved with `last_request_tools` or `finish: :submit` without those options,
so it runs with none and with `finish: :auto`.
This release does not establish how any particular model responds to the new
wording. See the [changelog](CHANGELOG.md) for every change.

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

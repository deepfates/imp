# Imp v0.10.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release shows the model the turns it actually had, keeps images that MCP
tools return, makes the ATIF export read as the model saw the run, and counts
streamed calls in `Imp.Usage`. What the model receives changes (history
turns, the system message's field list, and opt-in tool images), and so do
the meanings of ATIF fields, so this is a minor release rather than a patch.

## Install

```elixir
{:imp, "~> 0.10"}
```

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.9

Change the Imp dependency to `{:imp, "~> 0.10"}` (`~> 0.9` does not take
0.10), run `mix deps.update imp`, and commit `mix.lock`. No data migration is
needed: stored history, saved programs and run events are read as before and
rendered in the new form. Each change below says what a caller has to
change, if anything.

- **History turns are shown as recorded.** A stored turn no longer gives an
  output it did not record the filler "Not supplied for this conversation
  history message."; it leaves that output out, and a turn that recorded no
  output is its user message alone. A predictor that names a tool-calls
  output, but is not a tool loop, now keeps its recorded outputs as the
  assistant text when its history is replayed with native tool calls, where
  it showed an empty message. With native tool calls, a tool call whose
  result renders as blank text keeps its tool message instead of being left
  without an answer. Migration: a test, fixture or scripted response that
  matched the filler, or the empty message, must expect the turn without it.
- **No history input in the system message.** In every format, the system
  message no longer lists a history input or shows a `[[ ## history ## ]]`
  section, since history arrives as earlier turns. This covers a field typed
  `history` and any input the call supplies as an `Imp.History`. Migration:
  a test or custom renderer that matched the old field list or structure
  must match the new one; a custom `:system_renderer` receives the signature
  without those inputs. Both history changes alter the request, so a
  provider prompt cache keyed on the old system message misses once after
  the upgrade.
- **Images from MCP tools (opt-in).** Import a server with
  `result_mode: :multimodal` to keep its image content as
  `Imp.Adapter.Types.Image` values beside the result's text. The Chat adapter
  keeps the text in the tool message and sends the images in user messages
  after all of the turn's tool responses, each labelled with the tool name
  and call ID as tool data. `Imp.Adapter.Chat.format_tool_content/1` is new
  and is the default tool-result renderer; `format_tool_result/1` stays
  textual. Migration: none for the default `:text` and `:structured` modes.
  A custom `:tool_result_renderer` that should pass images through calls
  `format_tool_content/1` and bounds only the strings. Any tool, not only an
  MCP one, whose result is a list of strings and images with at least one
  image now has those images sent; such a list was rendered as text before.
- **ATIF shows a run as the model saw it.** In `Imp.Trajectory.to_atif/2`
  each model response is one agent step (`llm_call_count: 1`, null when
  served from Imp's cache) carrying `model_name`, `metrics`, the provider's
  own reasoning as `reasoning_content` and the tool calls run for it. A tool
  result's `content` is the tool message the model read next, with the
  tool's own output in `extra.output` when it differs and
  `extra.seen_by_model` saying whether a later request carried it. Replayed
  history keeps its tool calls, results and reasoning; `agent.model_name`,
  `agent.tool_definitions` and `final_metrics` are filled in. Migration: a
  reader that took `reasoning_content` as the visible thought reads
  `extra.next_thought`; one that expected each tool call as its own
  `llm_call_count: 0` step reads `tool_calls` on the response step (only a
  call a host dispatched itself is still its own step); one that read a
  call's `extra.outcome` on the step reads it on the call; and one that
  displayed `content` as the tool's raw output reads `extra.output` when
  present. An `:agent` option is now merged over the computed agent rather
  than replacing it. (On main this entry had been filed under 0.9.0 after
  that release was tagged; 0.9.0 does not contain it.)
- **Streamed calls are counted in `Imp.Usage`.** `Imp.Usage.track/1` now
  counts a streamed call (`Imp.collect/3`, `Imp.stream/3` with
  `provider_stream: true`), successful, failed or halted, and a call made by
  `Imp.Predict` with `track_usage` on, including a failed one. A streamed
  call has ReqLLM's `estimated_cost` when ReqLLM prices the model, as a
  non-streamed call does. Migration: a host that worked around the 0.9 limit
  by adding usage from `:model_response` events, or a prediction's
  `get_lm_usage/1`, into its own tracker now counts those calls twice and
  must stop.

Rollback means restoring the previous dependency requirement, lock and
application release; it brings back the filler text, the history section,
dropped tool images, the 0.9 ATIF shape and uncounted streamed usage.
Provider-free tests assert the new request messages, the image bytes and
their order on the provider wire, the ATIF projection, and usage counted
across processes; this release does not establish how any particular model
responds to the revised prompts or whether it perceives the images. See the
[changelog](CHANGELOG.md) for every change.

## Known limits

- The usage map (`:usage` on the `:model_response` event, `Imp.Usage`,
  `Imp.Prediction.get_lm_usage/1`) is ReqLLM's, unchanged. Its `:cost` and
  `:total_cost` are ReqLLM's catalog estimate, not a charge, for streamed
  and non-streamed calls alike, and OpenRouter's charge is its `"cost"`.
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

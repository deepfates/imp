# Imp v0.12.3

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release adds three things a caller opts into. An MCP tool can return
the text its server wrote for a model while a host still reads its structured
result (`result_mode: :content`, `Imp.MCP.call/3`). A ReActV2 call can give
its own request options (`config`). A ReActV2 text answer says why the
provider stopped its reply (`:finish_reason`). Calls and connections that do
not use the new options send and receive what they did in 0.12.2, apart from
one new metadata key on such predictions. Under Imp's versioning rule this is
a patch release.

## Install

```elixir
{:imp, "~> 0.12.0"}
```

`~> 0.12.0` takes later 0.12 patch releases and nothing newer. The two-part
form, `~> 0.12`, means `>= 0.12.0 and < 1.0.0` in Mix, so `mix deps.update
imp` under it takes every later 0.x release, including minor releases that
change what callers receive. Earlier install lines used the two-part form.

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.12.2

Under `{:imp, "~> 0.12.0"}`, run `mix deps.update imp` and commit `mix.lock`.
No code or data migration is needed. A caller that uses any of the additions
below should require `{:imp, "~> 0.12.3"}`, since earlier 0.12 releases do not
have them.

- **Added:** `Imp.MCP.connect(..., result_mode: :content)`. An imported tool
  returns what the server wrote in `content` for a model: its text, or its
  text and typed images as `:multimodal` returns them. Where that text only
  repeats `structuredContent` as JSON, or there is no content, it returns
  `structuredContent`, as `:multimodal` does. `Imp.MCP.call(tool, arguments,
  result_mode: :structured)` calls the same tool with its result read in
  another mode. Existing modes are unchanged.
- **Added:** an `Imp.Predict.ReActV2` call can pass `config` beside its
  inputs, as it can `max_iters` and `last_request_note`: request options
  merged over the program's `:config` for every request of that call only,
  such as an output budget for one last request on a history. A value that is
  not a keyword list, or that names `:tools` or `:tool_choice`, is refused with
  `{:error, {:invalid_react_v2_config, value}}` before any model call.
- **Added:** a ReActV2 prediction whose answer is a reply's text
  (`termination_reason: :answered` or `:last_text`) carries that reply's
  `:finish_reason` in its metadata, as the LM client reports it (`:stop`,
  `:length`, ...). `:length` means the provider's output limit cut the answer
  short. The termination itself is unchanged: a cut answer is still the text.

Rollback means restoring `0.12.2` in the lock. A call that passes `config`
then has it read as an extra input and ignored, with a warning; a caller that
reads `:finish_reason` finds it absent; `result_mode: :content` is refused at
connect. Provider-free tests check the request options a call sends, the
refusal of a bad `config`, the finish reason on both kinds of text answer, and
an HTTP MCP server read in `:content` and `:structured` modes; this release
does not establish what any particular provider reports as a finish reason
beyond what its LM client passes through.
See the [changelog](CHANGELOG.md) for every change.

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

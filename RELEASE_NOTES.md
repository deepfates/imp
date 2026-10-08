# Imp v0.12.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release makes a failed completion the provider billed count as spending.
Since 0.11.0 a completion the content filter stopped is an error, and that
error carried no usage or cost, so a host that caps spending from recorded
cost undercounted. Its usage and cost are now recorded. A filtered ReAct step
no longer sends a second, equally filtered request, and a completion that
finished with `finish_reason: :error` is now a failed request. What a caller
receives changes in each case, so under Imp's versioning rule this is a minor
release.

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

## Changes and upgrading from 0.11

Change the Imp dependency to `{:imp, "~> 0.12.0"}`, run `mix deps.update imp`,
and commit `mix.lock`. No data migration is needed.

- **A billed failed completion records its usage and cost.** When
  `Imp.Clients.ReqLLM` turns a non-streamed completion into an error (the
  content filter stopped it, or it finished with `:error`), the failed call's
  `:model_response` event now carries the same `usage`, `cost`,
  `estimated_cost` and `billing` metadata a completed call's does, beside
  `error`, and the usage is added to `Imp.Usage`. A streamed call that failed
  after reporting usage already worked this way. `Imp.LM.generate/3` still
  returns `{:error, reason}`. Migration: a host that summed `cost` only over
  `:model_response` events without an `error` should sum it over all of them.
- **A filtered ReActV2 step ends the turn.** An `Imp.Predict.ReActV2` step the
  content filter stopped fails the turn at once with
  `{:error, %Imp.Predict.ReActV2.StepError{}}`. Before, the turn made its
  usual last request (`:last_text` or the forced `submit`) with the same
  history, which was filtered and billed again. DSPy's ReAct also makes no
  further request after a step's LM error. Other failed steps still get the
  last request. Migration: a host that read a filtered turn's `:incomplete`
  prediction, or a `StepError` from its last request, receives the step's
  `StepError` instead.
- **`finish_reason: :error` is a failed request.** `Imp.Clients.ReqLLM`
  returns `{:error, %Imp.LMError{retryable: false}}` whose message is "API
  request failed: the completion finished with reason error: " followed by
  the response's text. It returned `{:ok, completion}`, so that text could
  become a prediction or a ReAct answer. ReqLLM gives this finish reason when
  the provider reports a generation failed partway, and for any finish reason
  it does not recognise. Migration: a caller sees a failed LM call where it
  saw a completion, and should not retry it.
- **Added:** `Imp.LMError` has a `content_filtered` field, `true` when the
  provider's content filter stopped the completion, so a caller can tell that
  case from other non-retryable failures without reading `reason`. The type
  `t:Imp.Clients.TRLTrainer.t/0` is now public; `Imp.Clients.TRLDeployment`
  specs already referred to it.

Rollback means restoring the previous dependency requirement, lock and
application release; failed billed calls then record no cost again.
Provider-free tests against a local HTTP server answering in OpenRouter's
response shape cover each of the three changes; this release does not
establish which providers send which finish reasons.
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

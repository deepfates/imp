# Imp v0.11.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release stops Imp from returning a provider's content-filter message as
if the model had written it. A completion the filter stopped is now a failed
request, so what a caller receives for that response changes from a
completion to an error. Under Imp's versioning rule that makes it a minor
release rather than a patch, even though it is a fix.

This is also the first release published to Hex by CI from its tag, after
every gate passed on the tagged commit.

## Install

```elixir
{:imp, "~> 0.11"}
```

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.10

Change the Imp dependency to `{:imp, "~> 0.11"}`, run `mix deps.update imp`,
and commit `mix.lock`. (A two-part requirement such as `~> 0.10` allows any
later 0.x version, so `mix deps.update imp` under it also takes 0.11. To stay
on 0.10 releases only, write `~> 0.10.0`.) No data migration is needed.

- **A content-filtered completion is a failed request.** When a provider
  ends a non-streamed completion with `finish_reason: :content_filter`,
  `Imp.Clients.ReqLLM` returns `{:error, %Imp.LMError{retryable: false}}`
  instead of `{:ok, completion}`. Some providers put the filter's own
  message in the content (OpenRouter, for example, sends "The request was
  rejected because it was considered high risk"), and before this release a
  program read that text as the model's answer: a prediction could parse
  it, a ReAct loop could finish with it, and an optimizer could score it.
  The error's message is "API request failed: the provider's content filter
  stopped the completion: " followed by the provider's text, and its
  `reason` is a `ReqLLM.Error.API.Request` whose `response_body` holds
  `"finish_reason"` and `"content"`. Migration: `Imp.Predict`, ReAct and
  other callers now handle a failed LM call where they handled a completion.
  A host that recognised the filter by its text, or by `finish_reason` on
  the completion, matches the `Imp.LMError` instead and can remove its own
  check. A host that retries every `Imp.LMError` should honour `retryable`,
  since the same request is likely to be filtered again.

Rollback means restoring the previous dependency requirement, lock and
application release; it brings back the filter's text returned as a
completion. A provider-free test with a ReqLLM stub asserts the error for
a `:content_filter` response; this release does not establish which
providers send `:content_filter` or what text each one puts in the content.
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

# Imp v0.8.1

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This patch makes ACP tool results readable and truthful about omitted content,
and fixes local socket framing for large permitted JSON messages. It changes
neither model-facing behavior nor MCP, dependency pins, or stored schemas.

## Install

```elixir
{:imp, "~> 0.8"}
```

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

## Changes and upgrading from 0.8.0

- ACP now labels tool output omitted by the capture limit instead of printing
  `nil`. Genuine nil renders as `null`; empty results, failures and completed
  calls remain distinct. Structured output is JSON and errors use the same
  readable wording the model receives. A preview exceeding 32,768 UTF-8 bytes
  is explicitly cut; capture limits are unchanged. A host with full native
  records can supply its own bounded view and recovery coordinates.
- Local ACP listener and connecting sockets keep valid large JSON lines whole.
  The socket buffer follows the existing frame cap, including the newline;
  frames above the configured cap are still refused. This fixes frames split
  at the default driver buffer even though they were within the cap.

Keep `{:imp, "~> 0.8"}`, run `mix deps.update imp`, and commit `mix.lock`.
No data migration is needed. This does not reconstruct content omitted from
historical ACP transcripts, and does not add a full-result retrieval endpoint.
Rollback means restoring the previous dependency lock and application release;
it restores the old display/framing defects too. Provider-free tests cover
capture distinctions, UTF-8 bounds, real socket fragmentation, consecutive
frames and oversize refusal. See the [changelog](CHANGELOG.md) for older changes.

## Known limits

- `Imp.Usage` does not see streamed calls: they run in a separate process,
  so usage tracked around `Imp.collect` or a streamed `Imp.call` is empty.
  Read usage from the run's `:model_response` events.
- The usage map (`:usage` on the `:model_response` event, `Imp.Usage`,
  `Imp.Prediction.get_lm_usage/1`) is ReqLLM's, unchanged. For a
  non-streamed call its `:cost` and `:total_cost` are ReqLLM's catalog
  estimate, not a charge, and OpenRouter's charge is its `"cost"`. Read money
  from `cost` and `estimated_cost`.
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

# Imp v0.8.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
This release makes a ReActV2 agent's text completion field match its task,
preserves omitted output limits on OpenRouter requests, and includes the Finch
connection-timeout fix. The model-facing completion contract changes, so this
is a minor release rather than a patch.

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

## Changes and upgrading from 0.7

- For a task with one unconstrained text output, ReActV2 now asks the model
  for that output by name and carries its description into the step signature.
  A task whose output is `answer` asks for `answer` instead of `next_thought`.
  Update scripted model responses and custom step renderers to use the task
  output name. Typed and constrained tasks still complete through `submit`.
  Saved step history and legacy demonstrations keep working; a loaded agent
  derives the new contract from its task signature. The stored internal step
  fields remain compatible. A nonempty answer still means completion; prose
  such as "No reply" is not interpreted as silence.
- OpenRouter requests with no explicit output-token limit omit that limit on
  the wire, rather than reserving the model catalog's maximum output. This
  avoids rejecting usable prompts for exceeding the total context window.
  Both ordinary and streamed requests retain caller-supplied limits. Other
  providers are unchanged.
- Imp now requires Finch 0.24, which closes an HTTP/1 connection after a
  request timeout. Its lock uses Mint 1.11.0, removing the three Mint
  advisories that accompanied the previous 1.10.1 hold. Remove any application
  dependency added solely to hold Mint at 1.10.1, then update Finch, Mint and
  hpax along with Imp. The reason for that hold no longer applies.

Change the Imp dependency to `{:imp, "~> 0.8"}`, resolve dependencies and commit
`mix.lock`. See the [changelog](CHANGELOG.md) for earlier migration notes.
Provider-free tests exercise these mechanics; this release does not establish
how any particular model will respond to the revised completion contract.

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

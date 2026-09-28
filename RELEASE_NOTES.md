# Imp v0.6.0

Imp is a framework for typed, optimizable language-model programs on the BEAM.
Declare a task as named inputs and outputs, call it like any other Elixir
program, measure it on examples, compile it with an optimizer, and run the
selected program under OTP.

This release fixes bugs found after 0.5.0: failures that were reported as
success, credentials that reached reports and checkpoints, requests that could
be sent twice, and checkpoints that could not be resumed. It is `0.6.0` rather
than a patch because several of those fixes change what a caller receives:
`Imp.collect/3` returns a prediction; a ReActV2 turn whose model fails returns
a `StepError`; examples without declared inputs are refused; a reply that
answers no output is a parse error; `ReqLLMBatch` no longer resends a request
that may have run; an MCP 503 or 529 is `:refused`; `Imp.Datasets.csv/3`
refuses some files 0.5.0 loaded; an `Imp.react` signature may not have a
`tools` field; and GEPA and `Imp.Observability` report errors where they
reported `:ok` or `:failed`.

## Install

```elixir
{:imp, "~> 0.6"}
```

Every dependency comes from Hex. Use a path dependency only while developing
against a local checkout.

ExMCP and erlexec are declared `runtime: false`, so an OTP release that uses
`Imp.ACP` or `Imp.MCP` must list `applications: [ex_mcp: :load, erlexec: :load]`
in its release definition; see [releases that use MCP or
ACP](docs/production.md#releases-that-use-mcp-or-acp).
Ordinary Imp startup starts no protocol endpoint.

`mix deps.get` and `mix hex.audit` report two cowlib advisories
(CVE-2026-43966, CVE-2026-43969). cowlib arrives only through ExMCP's
Cowboy server, and Imp's HTTP goes through Req, Finch and Mint. The first is
fixed one layer up: Cowboy 2.16.0 and later refuse a response header
containing CR or LF, and a fresh `mix deps.get` resolves Cowboy 2.19.0. The second is in the encoder
for an outgoing `Cookie` request header, which nothing in Imp's dependency
tree calls, and no cowlib release fixes it yet.

## Headline changes

- An agent's step prompt asks for one format, as DSPy's does. With an LM that
  calls tools natively, the step no longer also asks for a `tool_calls` field;
  an LM that cannot is shown each tool's description and arguments in the
  prompt and writes its calls in `tool_calls`.
- Failures are reported instead of passing as success. A ReActV2 turn whose
  model fails returns `Imp.Predict.ReActV2.StepError` with the history as far
  as it got; a GEPA run that continued past failed proposals reports
  `:with_errors`; the Chat, JSON and XML adapters report a reply that answers
  no output as a parse error; and evaluation and optimizers refuse examples
  that never declared their inputs, whose labels were passed to the program
  as inputs.
- Redaction runs before a term is converted, in reports, results, GRPO
  checkpoints, session records and saved programs, so a client, retriever or
  OAuth store in them is no longer written with its secrets. The SIMBA,
  MIPROv2, InferRules, random-search and GEPA checkpoints redact their failure
  reasons. Redaction still replaces the whole string, as in 0.5.0, and
  recognizes more credential shapes.
- Renderers (`:system_renderer`, `:output_renderer`) shape the JSON fallback
  and every JSON or XML request, so a fallback sends the request the host
  shaped.
- `Imp.Clients.ReqLLMBatch` never sends again a request that may have run, and
  waits for the provider's `retry-after` before a retry.
- A streamed call is recorded in its run like any other, and a reply with text
  and tool calls keeps all of them, streamed or not.
- GEPA checkpoints resume: from a pending proposal batch, from a program that
  is an agent, and in a fresh VM.
- Imp's lock file takes `mint` 1.11.0, which fixes three advisories
  (EEF-CVE-2026-91043, EEF-CVE-2026-92103, EEF-CVE-2026-94194). That lock
  does not reach your application, and Imp sets no `mint` floor: update your
  own lock (Upgrading, step 1).

## Upgrading from 0.5

1. Change the dependency to `{:imp, "~> 0.6"}`, run `mix deps.get` and
   `mix deps.update mint hpax`, and commit `mix.lock`. `nimble_csv` is a new
   dependency.
2. `Imp.collect/3` returns `{:ok, prediction}` or `{:error, reason}`; read
   fields with `Imp.get(prediction, :answer)` instead of matching a string.
3. Where you checked `Imp.Prediction.complete?/1` after a ReActV2 model
   failure, match `{:error, %Imp.Predict.ReActV2.StepError{reason: reason,
   history: history}}` and store `history` as you store a finished turn's. A
   step refused by an `Imp.OperationalSafetyError` ends the turn this way at
   once; where you call the program yourself, match
   `{:error, %Imp.Predict.ReActV2.StepError{reason:
   %Imp.OperationalSafetyError{}}}`. `Imp.Evaluate` and the optimizers
   already raise it.
4. Call `Imp.with_inputs/2` on every example you evaluate or optimize on, and
   build evaluation rows with `Imp.example/1 |> Imp.with_inputs(...)` rather
   than plain maps or pair lists. Give each field of an example or prediction
   once, under one spelling. To keep a signature's instructions, pass it to
   `Imp.Signature.new/2` without instructions.
5. A field called `tools` in an `Imp.react` task signature is refused, and a
   saved program with one no longer loads. Rebuild the program with the field
   renamed and save it; to keep a saved program's optimized instructions and
   demos, rename the field in the saved file, or optimize again.
6. Match `%Imp.AdapterParseError{kind: :missing_fields}` where you relied on a
   prediction of defaults, or on ProgramOfThought's `:missing_program`, for a
   reply that answered no output.
7. Compare `Imp.Clients.ReqLLM` clients by `model`, not by the whole struct,
   which now carries `:tool_calling`; `%Imp.Predict.ReActV2{}` likewise
   carries `:tool_order`.
8. Treat a `ReqLLMBatch` request that ends `:ambiguous` as possibly run, and
   check it with the provider before sending it again. A 0.5.0 checkpoint's
   `:transient_failure` requests become `:ambiguous` on resume.
9. An MCP call answered with 503 or 529 is `:refused`, not `:unknown`.
10. Quote CSV fields that hold a quote (`"12"" pipe",1`) and remove spaces
    between a comma and a quoted field; `Imp.Datasets.csv/3` refuses both.
11. Match `Imp.Observability.Status`'s new `:succeeded_with_errors`, which an
    optimizer report with errors gives where it gave `:failed`. Read GEPA's
    `report.errors` rather than expecting `status: :ok`: a run that went on
    past failed proposals reports `:with_errors`. Review `:beam_native`
    stoppers built on `consecutive_outcome/2`, which now counts an iteration
    that raised as `:proposal_error` instead of `:none`.
12. Keep 0.5.0 away from files 0.6.0 writes: it cannot read a trajectory with
    atom keys (in a GEPA or Playbook checkpoint, or saved with `Imp.dump/1`),
    an optimizer report that holds an `Imp.History`, or a `ReqLLMBatch`
    checkpoint.
13. A ReActV2 turn that reaches `max_iters` with text beside tool calls it
    did not run now answers with that text, where it answered `nil`; the calls
    are still listed as unexecuted. A host that publishes every non-empty
    answer should decide whether to publish such a turn's text.
14. Re-evaluate saved agents on held-out data: the step prompt and tool roster
    order changed, so they send different prompt text.
15. A `:system_renderer` or `:output_renderer` now also shapes the JSON
    fallback and JSON and XML requests. Build on `opts[:default_system]` and
    `opts[:default_outputs]` rather than ignoring the options, or the fallback
    sends a Chat-shaped prompt.

## Known limits

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

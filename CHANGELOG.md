# Changelog

User-visible changes to Imp are recorded here.

## Unreleased

### Added

- `t:Imp.Clients.TRLTrainer.t/0`, the struct type that
  `Imp.Clients.TRLDeployment` specs already referred to.

## 0.11.0 — 2026-10-08

### Fixed

- A non-streamed completion that the provider's content filter stopped
  (`finish_reason: :content_filter`) is a failed request:
  `Imp.Clients.ReqLLM` returns `{:error, %Imp.LMError{retryable: false}}`,
  whose message is "API request failed: the provider's content filter
  stopped the completion: " followed by the response's text. It returned
  `{:ok, completion}` with that text as the content, so a caller read the
  filter's message (OpenRouter's, for example, "The request was rejected
  because it was considered high risk") as the model's answer. Migration:
  `Imp.Predict`, ReAct and every other caller now see a failed LM call where
  they saw a completion. A host that detected the filter by matching the
  text, or by reading `finish_reason` on the completion, matches the
  `Imp.LMError` instead. A host that retries every `Imp.LMError` should
  check `retryable`, because sending the same request again is likely to be
  filtered again. Streamed completions are unchanged; see Known limits in
  the release notes.

## 0.10.0 — 2026-10-08

### Added

- Opt-in MCP `result_mode: :multimodal` keeps MCP image content as typed
  images alongside the result's text. ReAct and saved-history replay send the
  images as call-labelled user attachments after the turn's tool responses.
  `Imp.Adapter.Chat.format_tool_content/1` lets host renderers keep images
  while bounding text; `format_tool_result/1` remains textual.
  `format_tool_content/1` is now the Chat adapter's default tool-result
  renderer, so a result from any tool that is a list of strings and
  `Imp.Adapter.Types.Image` values with at least one image is sent the same
  way; every other result renders as `format_tool_result/1` rendered it. In
  this mode an MCP image block without string `data` and `mimeType`, or whose
  data is not base64, raises `ArgumentError` in the tool call; it is not sent
  to the model.

### Changed

- `Imp.Trajectory.to_atif/2` now shows a run as the model saw it. Each model
  response is one agent step with `model_name`, `metrics` (tokens and cost),
  `llm_call_count: 1`, the provider's own reasoning as `reasoning_content`,
  and the tool calls the loop ran for it. A tool result's `content` is the
  tool message the model read next; the tool's own output is kept in
  `extra.output` when it differs, and `extra.seen_by_model` says whether the
  model read it at all. History replayed in the first request keeps its tool
  calls, results and reasoning. `agent.tool_definitions`, `agent.model_name`
  and `final_metrics` are filled in. A loop's `:reasoning` event (the
  visible thought beside a tool call) is `extra.next_thought` on its response
  step instead of a separate step. Migration: a reader that took
  `reasoning_content` as the step's visible thought, or expected tool calls
  as separate `llm_call_count: 0` steps, should read the new fields.
  Also: a response served from Imp's cache has `llm_call_count` null; a tool
  call no response asked for (one a host dispatched) is still its own
  `llm_call_count: 0` step; a call's `extra.outcome` is on the call in
  `tool_calls`, and on the step only for such a host-dispatched call; a user
  or system message a later request appends is a step of its own; a
  `:reasoning` event that follows no response to its request is a
  diagnostic; an `:agent` option is merged over the computed `agent` instead
  of replacing it; and `extra.capture` no longer says inference counts are
  unknown. This entry was listed under 0.9.0 on main after that release was
  tagged; it shipped in no release before this one.

### Fixed

- A stored history turn no longer shows "Not supplied for this conversation
  history message." for an output it did not record: missing outputs are
  left out, and a turn with none is its user message alone. A predictor
  that names a tool-calls output keeps its recorded outputs when its history
  is replayed with native tool calls; it showed an empty message. Migration:
  a test that matched the filler must expect the turn without it.
- The system message no longer lists a history input or shows a
  `[[ ## history ## ]]` section, in any format. History arrives as earlier
  turns, never as that section. A field typed `history` is left out, and so
  is any input the call supplies as an `Imp.History`; a custom
  `:system_renderer` receives the signature without them. Migration: a test
  or custom renderer that matched the old field list must match the new one.
- With native tool calls, a tool call whose result renders as blank text
  keeps its tool message, in a loop's earlier steps and in replayed history.
  The message was dropped, leaving the assistant's call with no answer.
- `Imp.Usage.track/1` counts streamed calls (`Imp.collect/3`, a stream with
  `provider_stream: true`), successful or failed, and a call made by
  `Imp.Predict` with `track_usage` on, including a failed one. A streamed
  call has ReqLLM's `estimated_cost` when ReqLLM priced it, as a
  non-streamed call does: ReqLLM's stream-level usage now fills the fields
  the chunks lack, and the chunks' figures stand where both report one.
  This retires the 0.9.0 Known limit on streamed usage. Migration: a host
  that worked around that limit by adding streamed usage, or a
  `track_usage` prediction's `get_lm_usage/1`, to its own tracker counts
  those calls twice and must stop.
- In a ReActV2 step with one unconstrained text output and native tool
  calls (no `submit` tool), the system message's opening line no longer
  says to use the tools to produce the answer, which contradicted the later
  line that the answer is the reply without a tool call. It now reads
  "You are an Agent. Produce `answer` from `intent`, using the supplied
  tools to gather information and take actions." Steps with `submit`,
  written tool calls, or the JSON and XML formats are unchanged. Migration:
  a test that matched the old opening line for this mode must match the
  new one.

## 0.9.0 — 2026-10-07

### Fixed

- A ReActV2 step with one unconstrained text output, for an LM that calls
  tools natively, no longer asks for `[[ ## answer ## ]]` and
  `[[ ## completed ## ]]` markers while also saying the answer is the text of
  the message without a tool call. The Chat adapter's system message lays out
  the inputs alone (without a `history` placeholder), and the loop line reads
  "When the final answer is ready, reply without calling a tool: that message
  is `answer`." Step demos and stored turns are shown as that plain text.
  Replies that still use markers parse as before. Written tool calls and
  signatures with `submit` are unchanged. Migration: a test or custom
  renderer that matched the old system message text must match the new one.

## 0.8.1 — 2026-10-02

### Fixed

- ACP tool results distinguish capture omission from a genuine null or empty
  result, render structured data and failures readably, and explicitly mark
  previews cut at the presentation byte bound. Tool-call identity and outcome
  remain intact; capture limits are unchanged.
- Local ACP sockets retain permitted large JSON frames instead of splitting
  them at the driver's default line buffer. Listener and client buffers follow
  the existing frame limit, and oversized frames remain refused.

## 0.8.0 — 2026-10-01

### Changed

- ReActV2 with one unconstrained text output now asks for that task field
  directly, carrying its description into the step signature. A task named
  `answer` no longer asks the model to put it in `next_thought`. Typed and
  constrained tasks still complete through `submit`. Stored step history and
  legacy step demonstrations keep working; loaded agents derive the new
  contract from their task signature. Migration: scripted model responses and
  custom step renderers must use the task output name. This changes the
  model-facing contract, not the interpretation of nonempty prose as an answer.

### Fixed

- OpenRouter requests without an explicit output-token limit leave it to the
  endpoint instead of reserving the model catalog's full output maximum. The
  inherited maximum could make otherwise usable prompts exceed the total
  context window. Ordinary and streamed requests preserve explicit limits.

### Security

- Imp requires `finch` `~> 0.24`, and its lock file and the example projects'
  take `finch` 0.24.0 with `mint` 1.11.0. Finch 0.24.0 closes an HTTP/1
  connection a request timed out on, so `mint` 1.11.0 no longer makes the
  next request on that connection fail, and the lock no longer holds `mint`
  1.10.1. That removes the three `mint` advisories (EEF-CVE-2026-91043,
  EEF-CVE-2026-92103, EEF-CVE-2026-94194) from `.audit_ignore` and the
  Known limits entry from the release notes. Migration: an application that
  added `{:mint, "~> 1.10.1"}` for this removes it; one whose lock has
  `finch` below 0.24 runs `mix deps.update finch mint hpax`.

## 0.7.0 — 2026-09-28

### Changed

- Breaking: `Imp.Core.LMResponse.cost`, and the `:cost` on a
  `:model_response` event, is what the provider reported charging, as its
  docs said, and `nil` when the provider reported no charge. It was ReqLLM's
  catalog estimate for every model in ReqLLM's catalog, so every spend total
  built on it counted an estimate as money spent, and OpenRouter's own charge,
  which OpenRouter responses carry unasked, was overridden by it. OpenRouter
  calls now report OpenRouter's charge; one made with the caller's own
  provider key reports OpenRouter's fee plus the upstream charge, or `nil`
  when the upstream charge is missing. A call to any catalog-priced provider
  that reports no charge (Anthropic, OpenAI, Google, Groq, xAI and others)
  now has a `nil` cost where it had the estimate. The estimate is the new
  `estimated_cost` field on `Imp.Core.LMResponse` and `:estimated_cost` on
  the `:model_response` event, `nil` for a streamed call; `billing` is the
  breakdown behind that estimate, as it always was, and its docs now say so.
  Migration: a host that sums `cost` treats `nil` as an unknown charge, not a
  free one; a host that wants the old number for calls with no reported
  charge reads `estimated_cost` for them, knowing it is an estimate.
- Breaking: a stream from `Imp.Clients.ReqLLM` that did not complete ends in
  `{:error, %Imp.LMError{}}`, not in a completion of whatever text arrived
  first: one that carries a provider error, finishes with reason `:error` or
  `:cancelled`, or is incomplete, its body ending with no finish and no
  `[DONE]` (reason `{:stream_finished, :incomplete}`). The error event
  carries the usage and other metadata that arrived before it. Migration: a
  caller of `Imp.stream/3` with `provider_stream: true` handles that error as
  any failed call; the request reached the provider, so it may have been
  charged.
- Breaking: a call streamed through `Imp.Clients.ReqLLM` records the
  configured model id without its provider prefix (`gpt-test`, where it
  recorded the whole `openai:gpt-test`) in the `req_llm` metadata of its
  `:model_response` event's `:response`, and its `Imp.Usage` entry is keyed
  `"openai/gpt-test"`. In 0.6.0 a real streamed call had no `Imp.Usage`
  entry at all.
  A call to a client built from a string-keyed spec map or a
  `{provider, opts}` or `{provider, model, opts}` tuple, streamed or not,
  records its provider, where it recorded none, so its `Imp.Usage` key gains
  the `"provider/"` prefix. Migration: a host that matched the
  provider-prefixed model of a streamed call matches the model id, and one
  that reads `Imp.Usage` by key for such
  a client uses the prefixed key.
- Breaking: `Imp.Predict.ReActV2`'s `:last_request_note` reaches the model
  as a user message with no assistant reply after it, as documented, in the
  last request and whenever the returned history is passed back. It was
  stored as a history entry with inputs and no outputs. The chat adapter
  renders that as a finished exchange, so the note was followed by an
  assistant message the model never gave, each field reading "Not supplied
  for this conversation history message." Using that filler for history is
  Imp's; DSPy 3.2.1
  renders a missing history output as `None`. The note, and the entry for
  inputs no step spent that comes before it when the first step failed, now
  carry `tool_calls: %Imp.Adapter.Types.ToolCalls{tool_calls: []}` and
  `tool_call_results: []`, like every other step the loop records. Migration: a
  host that recognises the note in `metadata.history` by its shape (only the
  first input's key) matches it by that key with an empty `tool_calls` list,
  or by its text. A note recorded by an earlier version keeps the old
  shape and still renders with the filler; to render it as this release
  does, add `tool_calls: %Imp.Adapter.Types.ToolCalls{tool_calls: []}` and
  `tool_call_results: []` to that entry. `History` entries a host writes
  keep Imp's rendering.
- In written tool mode (an LM that cannot call tools natively, where earlier
  steps replay as text), a stored step that recorded no call and no other
  output replays as its user message alone, as native replay already did. A
  ReActV2 step that answered with nothing no longer replays as an assistant
  message of filler. A turn that recorded any output, an answer included,
  keeps its assistant message.

### Fixed

- A call streamed through `Imp.Clients.ReqLLM` records the usage
  and the cost the provider reported at the end of the stream. ReqLLM's
  stream is a `Stream.resource`, which reports its end as halted rather than
  done, and Imp ended such a stream without its terminal event, so every
  streamed call was recorded with no usage and no cost. The stream now ends
  with exactly one terminal event, `done: true` with the provider's usage
  (including its `"cost"`), model and finish reason, taking the finish
  reason, and usage no chunk reported, from ReqLLM's metadata handle.
- A streamed call that fails after the provider reported usage records that
  usage and cost on its failed `:model_response` event, since the provider
  may have charged for it. The caller still
  receives `{:error, reason}`.
- A streamed call to a client built from an inline spec map, with atom or
  string keys, or a `{provider, opts}` or `{provider, model, opts}` tuple no
  longer fails with
  `{:lm_stream_failed, "protocol String.Chars not implemented ..."}`.
- `:reasoning_effort` accepts `max`, when an LM is built, on a call and in a
  saved program. Imp's accepted efforts are read from ReqLLM's own
  `reasoning_effort` option, so they are every effort ReqLLM accepts, on every
  provider. ReqLLM's provider translates it where it has a translation
  (Anthropic and Google turn it into a thinking budget); OpenAI, OpenRouter,
  Groq and xAI receive the effort as written, and it is the provider's to
  accept. OpenRouter receives `"max"` in either wire field.
- A string effort such as `"high"` reaches ReqLLM as its atom. ReqLLM checks
  the effort against its atom list before any provider sees it, so in 0.6.0 a
  string effort, including every effort loaded from a saved program, failed
  every call on most providers: OpenRouter without
  `openrouter_reasoning_wire: :nested`, Anthropic, Google and Groq among
  them. OpenAI and xAI were not affected.

## 0.6.0 — 2026-09-28

### Security

- Imp's lock file and the example projects' keep `mint` 1.10.1, which has
  three advisories that `mint` 1.11.0 fixes: EEF-CVE-2026-91043 and
  EEF-CVE-2026-92103 are in Mint's HTTP/2 client, and EEF-CVE-2026-94194 is
  in HTTP/1 chunked framing and needs an intermediary between the client and
  a malicious server. `mint` 1.11.0 leaves an HTTP/1 connection open after a
  receive timeout, and Finch 0.23.0 reuses it, so requests after a timeout
  fail (see Known limits in the release notes). `.audit_ignore` lists the
  three advisories with the reason and the condition that removes them: a
  Finch release that includes https://github.com/sneako/finch/pull/397,
  which is open and unreleased.
- `Imp.Redaction` redacts a string that holds a PEM private key of any type,
  a PGP private key block or a PuTTY key file; a Stripe (`sk_live_`,
  `rk_live_`), GitHub, GitLab (`glpat-`), Hugging Face (`hf_`), Slack
  (`xox?-`), SendGrid (`SG.`), npm (`npm_`), PyPI (`pypi-AgE`), Google OAuth
  (`ya29.`) or Vault (`hvs.`) token, or a JSON Web Token; an AWS access key id
  longer than 20 characters; a URL with a password in its user info; or a
  signed URL's `X-Amz-Signature`, `X-Amz-Security-Token`, `X-Goog-Signature`
  or Azure `sig`. It passed these unchanged into run events, traces,
  trajectories and saved programs. As before, the whole string is replaced,
  and every shape it caught before is still caught. It tries 22 patterns
  where 0.5.0 tried 7, so it is slower on text that holds no credential.
- A `Bearer` token of 16 or more characters with a digit in it is found
  wherever it ends: mid-line (`Bearer <token> https://…`) or before a newline
  (`"Authorization: Bearer <token>\nmachine …"`). Both were missed. A word
  without a digit after `Bearer`, followed by more text, is still read as
  prose and left alone.
- Near misses for `Bearer` or `Basic` in one letter case (`BEARER x` lines)
  are redacted in linear time; they took quadratic time.
- `Imp.ExternalCommand` redacts captured output with the same rules, in
  place of its own `sk-` and `Bearer` patterns: output that holds a
  credential is `"[REDACTED]"` whole, so the credentials printed beside a
  recognized one (`env | grep AWS`, a credentials file) go with it. A
  `Bearer` token of 12 to 15 characters, or one with no digit, followed by
  more text or a newline is shown, where 0.5.0's own `Bearer` pattern hid any
  such token of 12 or more characters. The optimizer's pricing URL check uses
  the same rules instead of its own.
- Writers redact a term before converting it: optimizer reports
  (`Imp.Optimizer.Report.dump/1`, `json_safe/1`, `json_projection/1`),
  experiment results, `Imp.Evaluate.Result.save_as_json/2` and
  `save_as_csv/2`, BetterTogether's bootstrap diagnostics, optimizer artifact
  candidates, GRPO session checkpoints, Optimize Anything results, ACP session
  records and saved programs (a Predict's demos and metadata, KNN examples,
  memory retriever documents). They converted first, so a client, retriever
  or MCP OAuth store in them was written with its header values, URL query
  secrets or store key, and a secret in a map key that is a tuple, a list or
  a struct was written as it was. `Imp.Redaction.drop_credentials/1` redacts
  such structs too. The SIMBA, MIPROv2, InferRules and random-search
  checkpoints redact their failure reasons; the instructions, demos and scores
  a resumed run continues from are kept as they are. Output that holds no
  secret is unchanged.
- `Imp.Redaction.redact/2` hides a connection struct's header values and the
  query, fragment and user info of its URLs, as `inspect/1` already did:
  `Imp.Clients.ReqLLM`, `Imp.Retrievers.HTTP`, `Imp.Tracking.MLflow`,
  `Imp.Tracking.WandB`, `Imp.Optimize.Anything.Config.Tracking`,
  `ExMCP.Client` and `ExMCP.Transport.HTTP`. A retriever in a tool result kept
  an `X-Subscription-Token` header, a cookie and a `?key=` URL in
  `render_inspection/2`, run-event JSON and ATIF.
- `Imp.Redaction.redact/2` redacts the secrets in `Imp.MCP.OAuth.Store` (the
  derived key), `Imp.MCP.OAuth.Pending` (the authorization URL and `state`)
  and `Imp.MCP.OAuth.Flow` (the authorization URL, PKCE transaction and
  registered client), keeping each struct and its other fields. They were
  walked as plain maps, so the store's key reached any redacted output that
  held a store. `code_verifier` is a credential name, so a PKCE transaction
  map is redacted on its own too.
- An error about a devset, evaluation row, field entry or demo that is not
  an example names its type and key names, never its values.
- A map key that is a string shaped like a credential is redacted.
  `Imp.Optimizer.Trajectory` names a key it refuses (one that is not an atom
  or a string) by its type; it printed the key, credential included.
- The `ReqLLM.Error.API.Request` inside an `Imp.LMError` from
  `Imp.Clients.ReqLLM` carries at most one response header, `retry-after`.
  Any other header ReqLLM left on the error is removed, so cookies, account
  identifiers and request ids no longer reach logs, checkpoints or run events
  through `inspect/1` of the error.
- An ACP session store redacts the history and transcript it writes, except
  the provider's `reasoning_content` and `reasoning_details`. A resumed
  session therefore replays a user message or tool result that held a
  credential as `"[REDACTED]"`, both to the client and in the model's
  history. The session's `_meta` is stored as sent; Imp never reads it.
- A two-element list with a name first is a key and its value only when it is
  an element of a list, as JSON writes config, headers and tool results
  (`[["api_key", key], ["model", "gpt"]]`); held directly as a field or map
  value, it is data. Saving and `Imp.Redaction.drop_credentials/1` read every
  such list as a pair, so a saved program whose example had an input named
  like a credential (`with_inputs([:api_key, :question])`), or whose metadata
  held such a list, did not load back as it was; `Imp.Redaction.redact/1`
  rewrote an Avatar tool schema's `"required" => ["api_key", "query"]`; and
  `Imp.Optimizer.Parameter` refused input keys `["api_key", "question"]`. One
  divergence from 0.5.0 follows: a flat two-element name-first list that is
  not itself an element of a list (at the top level, in a tuple, or under a
  key that is not a credential name), such as `["password", "hunter2"]`, is
  not redacted, since it has the shape of a list of two names.

### Changed

- Breaking: `Imp.Observability.Status` has a new state,
  `:succeeded_with_errors`, and `Imp.Observability.status/1` gives it, where
  it gave `:failed`, for every optimizer report whose `errors` is not empty:
  an optimizer that returned a report returned a program. Migration: code that
  matches every `Status` state adds the new one; code that treated `:failed`
  as "the report has errors" matches `:succeeded_with_errors`.
- Breaking: `Imp.collect/3` returns `{:ok, prediction}` or
  `{:error, reason}`, as `Imp.call/2` does, instead of a string that joined
  every output field's value with no separator (`question -> reasoning,
  answer` collected as `"Because.Paris"`). Migration:
  `{:ok, prediction} = Imp.collect(program, inputs)`, then
  `Imp.get(prediction, :answer)`.
- Breaking: an `Imp.Predict.ReActV2` turn whose last request (made after a
  step failed or the turn was interrupted) also fails returns
  `{:error, %Imp.Predict.ReActV2.StepError{}}`, where it returned
  `{:ok, prediction}` with no outputs and `termination_reason: :incomplete`.
  `:reason` is that request's error unchanged: an `Imp.LMError`,
  `{:lm_failed, client, exception}` or
  `{:adapter_format_failed, adapter, exception}`, which
  `Imp.Errors.retryable?/1` and `context_window_exceeded?/1` read through the
  struct. `retryable?/1` says whether the last model request may be sent
  again, not the turn: its tools have run. `:history` is the turn's
  `Imp.History` as far as it got, with every tool call that ran and its
  result; inspecting the error shows the history's size, not the history.
  A turn whose last request is answered still ends `:last_text`,
  `:forced_submit` or `:extracted`, and `:incomplete` is kept for one answered
  without a valid answer or out of time or context window. `Imp.ACP` saves
  the history to its session before failing the turn. Migration: where you
  checked `Imp.Prediction.complete?/1` after a model failure, match
  `{:error, %Imp.Predict.ReActV2.StepError{reason: reason, history:
  history}}` and store `history` as you store a finished turn's.
- Breaking: an `Imp.Predict.ReActV2` step refused by an
  `Imp.OperationalSafetyError` (a route, cost, transport, budget or
  cancellation guard) ends the turn at once with a `StepError` whose `:reason`
  is that error. The turn made its last request instead, and an answer to it
  passed the guard by. `Imp.Evaluate` and the optimizers find the guard inside
  the `StepError` and raise it. Migration: where you call the program
  yourself, match `{:error, %Imp.Predict.ReActV2.StepError{reason:
  %Imp.OperationalSafetyError{}}}`.
- Breaking: an `Imp.react` task signature cannot have a field named `tools`,
  which is now the step's tool list, and loading a program saved with one
  raises the same `ArgumentError`. Migration: rebuild the program with the
  field renamed and save it; to keep a saved program's optimized instructions
  and demos, rename the field in the saved file, or optimize again.
- Breaking: `Imp.Clients.ReqLLM` has a `:tool_calling` field: whether the
  model calls tools natively, read from the registry once when the client is
  built or loaded, and kept with the model it was read for. A client whose
  model is swapped looks the new model up. A client built by `Imp.req_llm/2`,
  or loaded, therefore no longer equals a bare `%Imp.Clients.ReqLLM{}` for the
  same model. Likewise `%Imp.Predict.ReActV2{}` has a `:tool_order` field,
  the tools' declared order. Migration: compare clients by `model`, not by
  the whole struct.
- Breaking: in `Imp.Adapter.Chat`, `Imp.Adapter.JSON` and `Imp.Adapter.XML`,
  a reply that answers none of the requested outputs (no
  `[[ ## field ## ]]` section, no output key, no output tag) is an
  `Imp.AdapterParseError` of kind `:missing_fields` naming every output, so
  the JSON fallback or a retry runs. When every output was optional or
  defaulted, as a ReActV2 step's are, such a reply parsed as defaults and
  `nil`s, so an XML agent given prose finished with `answer: nil`. DSPy 3.3.1
  fills defaults there; Imp does not. For a signature that names an output in
  `metadata[:text_field]`, Chat and XML read prose as that field (so a
  ReActV2 step's prose under XML is its `next_thought`), and a blank
  completion, the one exemption, as a step that said nothing. A reply that
  writes fields in some format (a JSON object with an output's key, a
  `[[ ## field ## ]]` line, an output's tag) is not prose: Chat and XML parse
  it or report it, so a step that spelled out a tool call as JSON runs that
  tool instead of answering with the JSON text. So a step whose prose quotes
  its own field names goes to the JSON fallback, which usually costs one more
  call; beside native tool calls such a thought becomes `nil`, and the calls
  still run. A JSON `{}` for a ReActV2
  step is `:missing_fields`, where it was a step with `nil` fields.
  `Imp.Predict.ProgramOfThought`, whose outputs are all optional, sends prose
  to the JSON fallback instead of regenerating with a missing-program error.
  Migration: match `%Imp.AdapterParseError{kind: :missing_fields}` where you
  relied on a prediction of defaults, or on ProgramOfThought's
  `:missing_program`, for a reply that answered nothing.
- Breaking: `Imp.Clients.ReqLLMBatch` never sends a request again when it may
  already have run. A dispatch that timed out, crashed, threw or exited was
  retried as transient, so one request could run and be billed several times;
  it is now `:ambiguous` and final, and a dispatcher may return
  `{:ambiguous, reason}` itself. `req_llm_dispatcher/2` makes every call with
  `max_retries: 0` (ReqLLM's own retry step could send a request four times in
  one batch attempt); retries only a request that never reached the provider
  (connection refused, or no pooled connection free, as Req reports it) or
  that the provider answered with 408, 425, 429, 503 or 529; treats any other
  4xx as terminal; and treats any other 5xx, and a timeout or closed
  connection with no response, as `:ambiguous`, where a 5xx was retried. On
  resume, a checkpoint written by 0.5.0 is rewritten at schema version 2 and
  its `:transient_failure` requests become `:ambiguous`, since 0.5.0 recorded
  timeouts and dispatcher crashes that way, and a `schema_migration` event
  records each. Migration: check an `:ambiguous`
  request with the provider before sending it again.
- Breaking: an MCP call the server answers with HTTP 503 or 529 is
  `:refused`, like a 429, where it was `:unknown`: RFC 9110 defines 503 as the
  server being unable to handle the request, and providers answer overload
  with 503 or 529. MCP calls and `Imp.Clients.ReqLLMBatch` read a status the
  same way. Migration: code that treated a 503 or 529 as possibly run
  matches `:refused` for them.
- Breaking: `Imp.Datasets.csv/3` parses RFC 4180 CSV with NimbleCSV, a new
  dependency (`nimble_csv ~> 1.3`); it raised `FunctionClauseError` on any
  quoted field and could not read a quoted line break. A line break may be
  CRLF, LF or a bare CR, and a leading byte order mark is dropped, where it was
  read into the first column's name. A blank line is skipped, but a `""` line
  is a row with one empty value, so a file with more than one column refuses
  it (`invalid CSV row at <path>:<line>: expected N fields, got 1`). A
  malformed file raises `Imp.Datasets.Error` naming the line its record starts
  on, with that record's first 200 characters as `record`. Some files 0.5.0
  loaded are refused:
  - a quote inside an unquoted field, such as an inch mark (`12" pipe,1`):
    `invalid CSV at <path>:<line>: a quote opened on this line is never
    closed`, or, when the line holds two (`12" by 3" board,1`),
    `invalid CSV at <path>:<line>: unexpected escape character " in "..."`.
  - a space between a comma and a quoted field (`x, "y"`):
    `invalid CSV at <path>:<line>: unexpected escape character " in "..."`.
  Migration: quote the whole field and double the quotes inside it
  (`"12"" pipe",1`), or remove the space.
- Breaking: `Imp.Example.inputs/1` and `labels/1` raise `ArgumentError` when
  the example never declared its inputs, as DSPy raises `ValueError`. They
  returned every field as inputs, labels included, so a program was given the
  answer and scored on it. `Imp.evaluate/4`, `Imp.Evaluate.run/2`,
  `Imp.Experiment.Data.new/1` and every optimizer that runs a program on
  examples check each dataset before any model call, and the error names the
  function, the dataset and the row. To check it, `Imp.Evaluate`, MIPROv2,
  `Imp.Optimizer.InstructionSearch` and `Imp.Optimizer.SignatureOptimizer`
  read a lazy dataset once and hold it in memory, so a one-shot stream is no
  longer found empty on a second pass (every InstructionSearch candidate
  scored 0.0 on one). Migration: call `Imp.with_inputs/2` on every example
  you evaluate or optimize on.
- Breaking: `Imp.Evaluate` and `Imp.Experiment.Data` refuse a row that is a
  plain map or a field pair list, which cannot declare its inputs; Evaluate
  turned it into an example whose labels reached the program. Migration:
  build the row with `Imp.example/1 |> Imp.with_inputs(...)`.
- Breaking: `Imp.Example.new/1` and `Imp.Prediction.new/2` raise when a field
  is given twice, as an atom and a string or as a repeated key; one value was
  silently dropped. Migration: give each field once, under one spelling.
- Breaking: `Imp.Signature.new/2` (and `Imp.signature/2`) applies new
  instructions to an existing signature; it returned the signature unchanged.
  Migration: to keep a signature's instructions, pass it without
  instructions.
- Breaking: a GEPA run that continued past failed proposals reports them, so
  it reports `status: :with_errors` where it reported `:ok` with no errors.
  Each failure is an entry in `report.errors` with its `iteration`, its
  `diagnostics` and its `candidate_id` (the rejected candidate in
  `candidates`, or `nil` when the failure left none there);
  `metadata.failed_proposals` counts them. With `raise_on_exception: false`
  that is any failure: a reflection call, reflection strategy, evaluation or
  validation that raised, threw or exited, or an iteration that did. With the
  default, `true`, it is the failures GEPA already recorded and went on from:
  a reflection that returned no usable instruction, a failed reflective
  dataset in a parallel slot, and a reflection interrupted before a resume.
  The program returned is still the best candidate found, the baseline when
  every proposal failed, as DSPy's GEPA returns it. A slot cancelled because
  a sibling failed first is rejected, not counted as failed. Migration: code
  that checked `status == :ok` reads `report.errors`.
- Breaking: under GEPA's `execution_profile: :beam_native` with
  `raise_on_exception: false`, an iteration that raised is recorded as a
  rejection with a `{:proposal_error, reason}` reason, so
  `Stopper.consecutive_outcome/2` counts it as `:proposal_error`, as the
  default profile already did, where it counted `:none`. When evaluating the
  first two proposals raises and the third solves the task,
  `consecutive_outcome(:proposal_error, 2)` now stops after two iterations
  with the baseline, where the run went on and returned the solving
  candidate, and `consecutive_outcome(:none, 2)` no longer stops it after the
  first. An iteration that threw or exited, which crashed the run, is recorded
  the same way.
  Migration: review stoppers built on `consecutive_outcome(:none, _)` or
  `(:proposal_error, _)` for `:beam_native` runs.
- `Imp.Clients.ReqLLM` marks `context_window_exceeded` on more providers'
  length refusals, streamed or not: Anthropic's "prompt is too long: N tokens
  > M maximum" and "input length and `max_tokens` exceed context limit",
  Google Gemini's "The input token count (N) exceeds the maximum number of
  tokens allowed" (including a `streamGenerateContent` error sent as a JSON
  array) and Vertex AI's "the input token count is N but model only supports
  up to M", Mistral's "Prompt contains N tokens, too large for model with M
  maximum context length", and OpenRouter's `error_type:
  "context_length_exceeded"` from an OpenRouter model. Only OpenAI's
  non-streamed `context_length_exceeded` was marked, so the others failed the
  call instead of letting `Imp.Predict.ReActV2` leave out older episodes or
  end the turn `:incomplete`.
- Imp 0.5.0 cannot read some files this release writes:
  - a trajectory with a map that has an atom key, which GEPA checkpoints,
    Playbook checkpoints and `Imp.dump/1` write through
    `Imp.Optimizer.Trajectory`;
  - an optimizer report (`Imp.Optimizer.Report.encode_term/1`, `dump/1`)
    that holds an `Imp.History`, now written under a `"history"` tag where it
    was a plain map;
  - an `Imp.Clients.ReqLLMBatch` checkpoint, now at schema version 2.
- Imp declares the dependencies whose modules it names, which reached it only
  through its other dependencies: `finch` `~> 0.21` (`Imp.Clients.ReqLLM`
  matches its error structs) and `decimal` `~> 2.0 or ~> 3.0` as an optional
  dependency (`Imp.Core` reads a reported cost given as a `Decimal`). It
  declares `plug` and `plug_cowboy` with `runtime: false` for the demo MCP
  servers, which the package leaves out: Imp starts neither, and no Imp code
  that ships uses them. It declares `mint` `~> 1.8`, since it matches Mint's
  error structs to tell a request that was never sent from one that may have
  run. Every one of these requirements is one Finch, Req or ExMCP already set
  (ExMCP requires `decimal` `~> 3.0`), so none moves an application's lock.
- Imp no longer depends on `jsv`, which nothing in Imp uses. ReqLLM still
  requires it.

### Fixed

- `Imp.inspect_history/2` renders any history. A turn holding a term JSON has
  no encoding for, such as the `{:error, {:unknown_tool, name}}` result a
  ReActV2 history keeps for a call to a tool that does not exist, raised
  `Protocol.UndefinedError`. Turns render through the conversion
  `Imp.Observability.render_inspection/2` uses: tuples become lists, structs
  become maps, and pids, references and functions become their `inspect/1`
  text. Redaction runs first, as before.
- A binary that is not valid UTF-8 renders as
  `%{"__imp_type__" => "binary", "bytes" => size}`, never as its content or a
  digest of it; a map key that is not valid UTF-8 takes the same form inside
  the map's `entries`. This applies to `Imp.inspect_history/2` and
  `Imp.Observability.render_inspection/2`, which raised `Jason.EncodeError` on
  such a binary, and to `Imp.Run.Event.to_map/1` and
  `Imp.Trajectory.to_atif/2`, which returned the raw bytes, so encoding their
  result raised. Output for values without such binaries is unchanged, and a
  request's `tools_hash` is identical.
- A call streamed with `Imp.stream(program, inputs, provider_stream: true)`
  is recorded in its run like any other model call: a `:model_request` event
  with the request's `:purpose`, and a `:model_response` event with the usage
  and cost the provider reported. It recorded neither, so a streamed turn left
  no model record, no cost and no ATIF model step. A `stream/3` that raises
  before returning a stream is recorded too and returns
  `{:error, {:lm_failed, lm, error}}`, as a raising `generate/3` does.
- A model turn that says something and calls tools keeps both. Through
  `Imp.req_llm/2` the text was dropped whenever the reply had tool calls, so a
  ReActV2 step's `next_thought` was empty; streamed with `provider_stream:
  true`, the text was kept but the tool calls were lost, all of them when text
  arrived and all but the last otherwise. The raw LM output for such a reply
  is `%{text: text, tool_calls: calls}` (`:text` only when it is not blank),
  unstreamed and streamed. Keeping the text is what DSPy does; the adapter
  then reads it as it reads a text reply, into `next_thought` for ReActV2,
  where DSPy's Chat adapter leaves the field empty. So when a
  ReActV2 run reaches `max_iters` and its last reply has text beside tool
  calls it did not run, that text is now the answer, where the answer was
  `nil`; the calls are still listed as unexecuted. The text also appears in
  history turns and in the ATIF model step.
- An `Imp.react` step asks for one thing, whichever adapter formats it, as
  DSPy's does. With an LM that calls tools natively, the tools are sent
  natively and the prompt (Chat, JSON or XML, their demos and the JSON
  fallback) no longer also describes `tool_calls` as a field to write; a model
  that followed that description wrote a JSON object, which for a signature
  with one text output became the answer. An LM whose client says it cannot
  call tools (a ReqLLM model the registry lists without tool calling,
  `Imp.Clients.TRLLM`) is sent no tools. Its step has a `tools` input listing
  every tool, `submit` included, in DSPy's words: name, description, and
  arguments as JSON (the schema's properties, in its order when it is a
  `Jason.OrderedObject` and by name otherwise, its `required` list and its
  `$defs`). It writes its calls in `tool_calls`, whose description shows a
  call's shape with an example, and its earlier steps are replayed as text,
  not as tool blocks a provider without declared tools may refuse. The
  guidance says the same in every format: a text answer goes in
  `next_thought`, with `tool_calls` left empty when the model writes its
  calls. It no longer asks for plain text beside a structure that asks for
  fields; a plain-text reply to a Chat step is still read as the answer. A
  stored turn that carries only the task's answer is replayed as that answer,
  not as step fields marked "Not supplied", by the adapter itself, so a host
  `:output_renderer` is not consulted for it. `Imp.LM.Budgeted` and
  BootstrapFewShot's rollout LM answer for the LM they wrap, for tool calling
  as for reasoning and response-format support.
- `Imp.react` sends its tool roster in declared order, then `submit`, and a
  saved agent keeps that order. It was the order of the tool names' atoms,
  which can differ between runs of the VM and changed the prompt a provider
  caches.
- The JSON fallback after an unparseable Chat or XML reply sends the same
  request in JSON: the program's `adapter_opts` renderers (`:system_renderer`,
  `:output_renderer`), an agent loop's guidance and the demos go with it. It
  sent the stock JSON prompt, so a host that shapes its prompt with renderers
  got a different prompt on every fallback, and an `Imp.react` step lost its
  tool guidance. `Imp.Adapter.JSON` and `Imp.Adapter.XML` honor
  `:system_renderer`, `:output_renderer` and `:guidance` whenever they are
  used, and end a request whose inputs are all in the history with the output
  requirements as a user message of their own instead of appending them to
  the last tool result. A renderer receives the formatting adapter's own
  rendering in its options, as `:default_system` and, for an
  `:output_renderer` that takes the options as a fourth argument,
  `:default_outputs`, so one that builds on the default builds on the format
  of the request. A renderer now shapes the JSON fallback and every JSON or
  XML request; one that ignores its options sends a Chat-shaped prompt in the
  fallback.
- The `[:imp, :adapter, :parse, :json_fallback]` event names the adapter whose
  reply failed as `:adapter` (it always said `Imp.Adapter.Chat`, also for
  XML) and the adapter that retried as `:fallback_adapter`.
- Repairing a Python-style completion keeps its text and gives the value
  DSPy parses: `{'answer': 'caf\u00e9'}` reads as `café`, not `cafu00e9`.
  Escapes are read the way `json_repair`, which DSPy runs first, reads them:
  `\t`, `\n`, `\r`, `\b`, `\\`, escaped quotes, `\u` with four hex digits and
  `\x` with two decode, and every other escape (`\d`, `C:\path`, `\a`, `\0`,
  `\U`, `\N{…}`, a backslash before a newline) keeps its backslash. A `\u`
  surrogate pair reads as the character it spells; a lone surrogate, which
  an Elixir string cannot hold, makes the parse an `Imp.AdapterParseError`.
  This reaches the Chat, JSON and XML adapters and GEPA's instruction
  proposal.
- Before a retry, `Imp.Clients.ReqLLMBatch` waits for the provider's
  `retry-after` (seconds, or an IMF-fixdate, RFC 850 or asctime date) when it
  sent one, otherwise with exponential backoff and jitter capped by the new
  `:max_retry_wait` option (default 60 s). `Imp.Clients.ReqLLM` keeps
  `retry-after` on its errors for this; ReqLLM's own decoding dropped it. A
  waiting request takes no dispatch slot from the others. When the provider
  asks for longer than `:max_retry_wait`, or the wait would pass the
  `Imp.Deadline` in force, the request is not retried in that run: it stays
  `:transient_failure`, the summary is not `complete?`, and `resume/3`
  retries it. The checkpoint keeps the time each such request may be sent
  again (`not_before`, UTC) and records a `retry_stopped` event, and
  `resume/3` waits for it under the same rules or stops the retry again
  without sending. A process that traps exits and is
  stopped by its parent during the wait exits at once with the parent's
  reason; a dispatch wave in progress is still waited for, up to `:timeout`,
  and a process started with bare `spawn` has no parent to listen for and
  sleeps uninterrupted.
- An Avatar tool ends with its caller. Its task kept running after the caller
  was killed, after `Imp.Run.cancel/3` and after the run's owner died. It
  still runs unlinked, so a crash is an observation, and takes no place in the
  task pool. It sees the caller's `Imp.context/2` settings, run context and
  deadline, which it did not, and parallel work it starts runs on the
  caller's place in the pool when the caller has one. A tool that timed out,
  or whose task exited, reads as `:unknown` in `Imp.Tool.outcome/1` rather
  than `:result`, since it may have acted. Inside a run, Avatar records each
  tool call as `:tool_call` and `:tool_result` events with
  `metadata.outcome`, and arguments that fail the tool's schema are refused
  before the tool starts.
- An RLM call made outside a run no longer leaves its model or tool call
  running, holding a place in the task pool, when the calling process is
  killed. An RLM call no longer leaves the pool place of one of its own tasks
  recorded in the calling process, which made parallel work that process
  started afterwards (`Imp.Predict.Parallel.map/3`, `Imp.Evaluate.run/2`) run
  one item at a time.
- The package ships the TRL worker that `Imp.Clients.TRLTrainer` starts by
  default: `priv/trl_worker/worker.py`, its `pyproject.toml` and `uv.lock`, and
  the default contract. In 0.5.0 the defaults named files the package did not
  contain, so GRPO training from Hex needed a source checkout. The default
  contract pins transformers 5.10.1, the version the lockfile installs; it
  named 5.5.0, which the worker refused at startup.
- `Imp.Optimizer.Report.load!/1` and `Imp.Optimizer.GRPO.Checkpoint.load!/1`
  read the `"[REDACTED]"` atom marker in a VM that has not loaded
  `Imp.Redaction`, and a MIPROv2 checkpoint resumes in a fresh VM: its loader
  loads the modules whose atoms it decodes. They failed with "not an already
  existing atom".
- `Imp.Evaluate.Result.save_as_csv/2` writes with the same CSV module that
  `Imp.Datasets.csv/3` reads with, so what it writes reads back unchanged.
  The bytes it writes are the same as before.
- A signature field written as `nil`, `true` or `false` keeps that name as
  text, so `"nil: string -> a"` saves and loads with a field named `"nil"`.
  The name became the atom `nil`, which saved as `""`. A field given the atom
  `nil`, `true` or `false` as its name raises `ArgumentError`.
- An instruction an optimizer sets on `Imp.Predict.ProgramOfThought` or
  `Imp.Predict.CodeAct` reaches the extraction step, which kept the old
  instructions when GEPA, MIPROv2, COPRO, SIMBA or InferRules set it, and such
  a program saves and loads: `Imp.Saving.load!/1` raised "saved
  ProgramOfThought planner instructions must match task instructions".
  `Imp.Optimizer.InstructionSearch` sets instructions the same way.
- `examples/deployment/agent_optimization.exs` writes the optimizer's
  rejections and history with `Imp.Optimizer.Report.json_safe/1`. It passed
  them to `Jason.encode!/1`, which raised on a failure reason such as
  `{:incomplete_evaluation, 1}`, so a finished run lost its record.

### GEPA

- A GEPA report names real failures only: a row whose program call or metric
  failed, a row whose metric returned a value `Imp.Metrics` cannot read, and
  a proposal error. It treated the metric's feedback as a failure, so a run
  whose metric returned feedback reported `errors`, `status: :with_errors`
  and candidates named "Program call failed: …" when nothing had failed. A
  candidate rejected because its proposal failed is named "Proposal failed:
  …".
- A GEPA report no longer crashes when a metric throws or exits: the failure
  is shown as `{:throw, reason}` or `{:exit, reason}`, where building the
  report raised `Protocol.UndefinedError`. Every diagnostic in the report has
  its credential values redacted.
- GEPA ends the run on an `Imp.OperationalSafetyError` (a budget, cost,
  route or transport guard) whatever `raise_on_exception` says. With
  `raise_on_exception: false`, it recorded the refusal as a failed proposal
  and went on spending.
- GEPA redacts a failure reason when it records it in a rejection, the
  history or a pending proposal slot. An exception is recorded as
  `{:proposal_exception, "Module.Name", message}` (the tag names the stage
  that failed) and a throw or exit as `{:proposal_throw, term}` or
  `{:proposal_exit, term}`, so a checkpoint holding it reads back in a VM
  that has not loaded the module that raised; the parallel and sequential
  paths record the same shape. A checkpoint otherwise holds the resume state
  as it is (candidates, the evaluation cache, proposed instructions and
  reflection data), so a `:checkpoint_fn` consumer treats it as sensitive.
- GEPA with `raise_on_exception: false` no longer records an exit that asks
  the process running it to stop (`:normal`, `:shutdown`, `{:shutdown, _}`,
  `:kill`) as a failed proposal when a module selector, a reflection
  strategy, or the adapter's evaluation or reflective dataset raises it in
  that process: the exit goes on up, as it must from a process that traps
  exits and turns its owner's shutdown into an exit.
- `Imp.Optimizer.Trajectory.dump/1` and `load!/1` round-trip a trajectory:
  a map with an atom key is written as its entries, each key tagged as an
  atom, so a prediction's metadata, a trace step (`%{predictor: :main}`) and
  metric metadata such as Optimize Anything's `objective_scores` load with the
  keys they had. Every map key was written as a string, so a trajectory whose
  prediction had metadata failed to load (`Imp.Prediction.new/2: invalid map
  in :metadata … got: "trace"`), and resuming GEPA from a checkpoint whose
  pending proposal batch held a result from an `Imp.predict` program raised
  that error. Loading never creates an atom: a key written as an atom the
  loading VM does not have loads as its name, a string. A prediction's string
  metadata keys become their atoms when those exist, so
  `Imp.Prediction.get_lm_usage/1`, `complete?/1` and readers of `:trace` find
  them. A map that holds a key as both an atom and a string is refused on
  load, as on dump. A trajectory written by 0.5.0 still loads, including one
  whose prediction has metadata; its other map keys load as the strings they
  were written as.
- GEPA checkpoints an agent. A trajectory, and the report codec GEPA uses for
  a pending batch's reflective dataset and a result's outputs, write an
  `Imp.History` with `Imp.History.dump/1` and read it with
  `Imp.History.load!/1`; the trajectory codec also carries
  `Imp.Adapter.Types.ToolCalls` and `ToolCallResults`. The first checkpoint
  that held an `Imp.react` program's trajectories raised
  `Trajectory.DecodeError: trajectory contains an unsupported struct:
  Imp.History`, under either profile.
- A GEPA checkpoint resumes in a fresh VM: the loader loads the GEPA modules
  whose atoms a checkpoint holds before decoding it.
  `Imp.Optimizer.GEPA.compile_with_report/5` given a checkpoint in a VM that
  had not yet run GEPA raised `not an already existing atom` on names like
  `:cache_hits` and `:no_strict_improvement`.
- The checkpoint GEPA writes after a sequential reflection holds the proposed
  candidate, as the parallel path's does, so a resume from it, or from a
  checkpoint taken while that candidate was being evaluated, evaluates that
  candidate on the same minibatch. It held no proposal, so the resume started
  the iteration over on the next minibatch and asked for a new reflection.
- Under `:proposal_concurrency` above 1, GEPA evaluates a proposed candidate
  on its minibatch without capturing traces, as the sequential path and
  DSPy's GEPA do: the metric is called without a trace, an
  `:acceptance_policy` sees `after.trajectories == %{}`, and the child's
  `on_evaluation_end` carries no trajectories.
- `Imp.Optimizer.GEPA.compile_with_report/5` no longer raises `KeyError` when
  it resumes from a checkpoint taken during a full validation; the
  interrupted validation's rejected candidate is in the report.

### Documentation

- The install instructions ask for a C and a C++ compiler: jaxon builds native
  code from C and erlexec from C++. They asked for a C++ compiler only. They
  also say the first compile needs network access, for erlexec's rebar3
  plugins.
- The package's Changelog link opens the changelog on HexDocs, and the 0.4.0
  entry links the benchmark pages as they were at v0.4.0, not on `main`.
- Each Livebook's setup cell only installs Imp: from Hex, or from the
  checkout `IMP_PATH` names. It no longer searches for a source checkout.
- The MCP example on the Tools and agents page defines its server and its
  imported tools, where it used an undefined `imported`, and closes the
  server when the call fails.

## 0.5.0 — 2026-09-26

### Security

- An LM client, the HTTP, Databricks and Weaviate retrievers and the MLflow
  and W&B trackers print with their credentials redacted, and so does a
  program holding one. `Imp.req_llm(model, api_key: key)` printed the key in
  IEx, in log lines and in crash reports, and a RAG program printed its
  retriever's bearer token. Refusing to save a retriever that is not portable
  names its module instead of printing it.
- A client, retriever or tracker prints every header value as `[REDACTED]`,
  whatever the header is called (`X-Subscription-Token`, `Cookie`), and the
  query, fragment and user info of every URL, given as a string or a `%URI{}`.
  A saved program holds no header at all, so an LM with custom headers has to
  be rebound after loading, and `Imp.save!` refuses an LM whose `base_url` has
  a query, fragment or user info. Option errors, including those for the
  options passed to a call, name a credential-bearing option without printing
  its value. The ExMCP client's state, which a crash report prints, is redacted
  the same way. Before, a header was hidden only when its name looked like a
  credential, and `Imp.save!` wrote other headers' values to disk.
- RLM controller code cannot make a struct. A map literal that named
  `__struct__` was dispatched by every protocol as that struct: a map shaped
  like a `File.Stream` sent `Enum.join` into the `Enumerable` implementation
  for `File.Stream`, which read the named file. A map literal, `submit/1` and
  the result of a library call may no longer carry the key, and a library call
  takes no struct but a range or MapSet and no Elixir module named as a value.
  A module is not a value at
  all (`m = File` fails with `{:module_value_not_allowed, "File"}`); a sorter
  is `:asc`, `:desc` or a function, since an Erlang module given as a sorter
  had its `compare/2` called, and `Map.from_struct/1` takes no module; and a
  library call that hands back a function it was given (`Map.get(m, k, f)`)
  fails the turn instead of leaving a native closure in a variable.

### Installing

- Imp is a Hex package: `{:imp, "~> 0.5"}`. Every dependency comes from Hex,
  including ExMCP (`~> 1.5`, unpatched); the `deepfates/ex_mcp` Git fork, the
  bundled `vendor/ex_mcp` path and the `EX_MCP_PATH` override are gone.
- What 0.4.0 got from the fork now lives in Imp: stdio MCP servers in their
  own process group, a `PATH` without the release's own directories, and the
  HTTP options public servers need (no `Origin` header, a written `/` path
  kept, one retry with the standard `initialize` after a non-401 4xx on the
  era probe). What an upgrader meets:
  - erlexec is a direct dependency. It builds a C++ port program, and an OTP
    release that uses `Imp.MCP` or `Imp.ACP` lists
    `applications: [ex_mcp: :load, erlexec: :load]`.
  - Imp sets `SHELL=/bin/sh` in a VM started without `SHELL`, because
    erlexec's port program does not start without it.
  - Closing a stdio connection, or the death of the process that owns it,
    sends the server's group SIGTERM and SIGKILL one second later; 0.4.0 stopped
    the group without a SIGTERM a server could handle.
  - When a stdio server exits on its own, what is left of its group gets
    SIGKILL half a second later.
  - Trust for an authorized remote server is VM-wide: while a connection to it
    is open, its exact origin is in ExMCP's `trusted_origins`, so any ExMCP
    client in the VM may send credentials to that origin. In 0.4.0 the trust
    belonged to the one connection. The origin is removed when the last
    connection to it closes, and origins the host configured are left alone.

### MCP

- An MCP tool call that got no answer from its tool returns
  `{:error, %Imp.MCP.CallFailure{}}` instead of
  `{:mcp_tool_call_failed, server, reason}` or
  `{:mcp_connection_unavailable, server, reason}`. Its `outcome` says whether
  the call was refused before anything ran, its credential was refused (an
  HTTP 401 or a failed OAuth flow), it was never sent, or it was sent with no
  trustworthy answer (`:refused`, `:auth_refused`, `:not_sent`, `:unknown`);
  `reason` keeps ExMCP's error unchanged, and an exit is kept as
  `{:exit, reason}`.
- `Imp.Tool.outcome/1` gives the outcome of a tool call's value: `:result`
  when the tool answered, MCP error results included, unless the error result
  declares `structuredContent.outcome` as `"refused"`, `"auth_refused"` or
  `"unknown"`, which it then is (a server marks a write that may have been
  applied `"unknown"`). A value alone never reads as `:refused`, because a tool can
  return any term: ReActV2 and RLM decide a refusal where they refuse the call
  (an unknown tool, a malformed call, arguments that fail the schema, a tool
  policy, a host's authorization, submit outputs that do not fit) and record
  every call's outcome on its `:tool_result` event as `metadata.outcome`.
  `Imp.Tool.outcomes/0` lists the five.
- A failed tool call reaches the model as plain text instead of an Elixir
  term. An MCP error result is the text of its content, the tool's own words,
  after `Error: ` unless the text already begins with "error"; a JSON-RPC
  error is the server's message; a call that got no answer says why in one
  sentence, and unless the request was never sent, that it may have been
  carried out (a timeout, a closed or failed connection, a broken stream, a
  server that stopped waiting for its tool or a tool that crashed). An
  unknown tool, missing or invalid arguments, a denied tool and a tool that
  exits or throws are sentences too; a tool that exits may have been carried
  out. `Imp.Adapter.Chat.format_tool_result/1`
  renders these, `Imp.Adapter.Chat.tool_error_text/1` gives the words without
  `Error: `, and `Imp.MCP.failure_text/1` gives the MCP ones. The recorded
  error term is unchanged. `Imp.Predict.ReAct`'s `:dspy` observations
  use the same words after `Execution error in <tool>: `, where they showed
  `inspect/1` of the reason.
- `Imp.MCP.connect/2` takes `pool_size:` (1 by default): that many
  connections are opened to each `http` or `sse` server, and each tool call
  borrows an idle one for the length of the call, so up to `pool_size` calls to
  one server run at once. One ExMCP client sends one HTTP request at a time, so
  without it a quick call waits behind a slow one to the same server. A call
  that finds every connection busy until its `:timeout` fails as `:not_sent`
  (`reason: :no_idle_connection`), and a call on a closed HTTP import fails as
  `:not_sent` with `reason: :not_connected` rather than a process exit. A
  `stdio` server keeps one connection whatever `pool_size` says: ExMCP already
  sends it several calls at once, and another connection would be another
  server process. The extra connections are dialed at once, so a server costs
  the import at most about three `:timeout`s. A connection whose call timed
  out, or whose caller died during the call, is replaced in the background
  rather than lent again while ExMCP still waits on that request, and is
  closed once that request is done, so the server finishes what it was doing;
  a replacement that cannot be dialed leaves the server a connection fewer.
- A call to an HTTP MCP server that asks for progress (`call_meta` with a
  `progressToken`) no longer loses its server-side work when the caller's
  `:timeout` passes. ExMCP ended such a request's stream a second after the
  call's timeout, and its server ended the tool with it: a 3 s write under a
  300 ms timeout never finished. The caller is answered at its
  `:timeout`, `:unknown` with `reason: :timeout`, and the request runs on to
  the connection's limit.
  `:call_meta` is still called in the process that makes the call.
- An HTTP MCP call can take as long as the import's `:timeout` allows. ExMCP
  ended every HTTP request at its own 30 s default whatever `:timeout` said,
  so a call to a tool that takes 33 s failed at about 30 s under
  `timeout: 45_000`. ExMCP's `request_timeout` is now the import's `:timeout`,
  and never less than 30 s.
- `"type" => "sse"` now means MCP's deprecated HTTP+SSE transport (2024-11-05):
  the descriptor's `"url"` is the event stream's (`https://host/sse`), and
  requests go to the URL the server names on it. Before, `sse` was Streamable
  HTTP with a standing GET stream, so a server that speaks only the old
  transport answered its first request with 405. It works with servers that
  name the session `sessionId` (the TypeScript SDK's, ExMCP's), not with the
  Python SDK's SSE servers (`session_id`): their dial fails with
  `:sse_endpoint_without_session_id` and a message saying to use `"http"`. A
  server that speaks Streamable HTTP is reached as `"http"`. An `sse`
  descriptor with `"headers"` or `"auth"` is refused
  (`:mcp_sse_credentials_refused`): the server names where requests go, and
  its credentials would go there whatever origin it named. Under
  `on_failure: :drop` only that server is left out, with a warning, and so is
  an `sse` URL with a query string (`:mcp_sse_url_refused`), which ExMCP would
  dial without it. An `sse` connection whose event stream ends (ExMCP ends it
  after a stretch with nothing on it, and does not reopen it) is replaced,
  rather than kept and lent; the stretch is at least 60 s and longer than a
  request can take.
- A caller of `Imp.MCP.connect/2` that dies while its import is connecting no
  longer leaves the connections already made open. They close with the import's `:owner`, which
  is the caller unless another process was named.
- `Imp.MCP.OAuth.begin/3` runs its own browser flow on ExMCP's public OAuth
  functions. Its `:flow` option is replaced by `:client_registration`
  (`:auto`, `{:pre_registered, client_id, client_secret}` or `{:cimd, url}`);
  a pre-registered client also names its `:client_issuer`, and the flow
  refuses to begin when the server names a different authorization server. A
  server with neither protected-resource nor authorization-server metadata is
  refused rather than given guessed `/authorize` and `/token` endpoints.
- A tool's name keeps the type it was given. `Imp.Tool.new/4` no longer turns a
  string into an atom that happens to exist, and tools imported from an MCP
  server are always named by the server's string. Lookups (`resolve_name/2`,
  tool policies) already compare names by text; code that matched an imported
  tool's name against an atom matches the string now.
- `Imp.ACP.start_link/1`, `Imp.ACP.run/1` and `Imp.ACP.Local.start_link/1`
  raise `ArgumentError` for an option they do not know, before anything
  starts; `Imp.ACP.Local` checks its `:agent_options` before it listens. In
  0.4.0 a key Imp did not know went to ExMCP, which handed it to the
  transport, so a misspelled `:permission_policy` or `:session_store` was
  silently ignored. The options are declared once and `Imp.ACP.start_link/1`
  documents them. A transport's own options go in `:transport_options`
  (`Imp.ACP.Local` passes its socket there), and `:capabilities` is no longer
  accepted beside `:agent_capabilities`.

### Runs

- A run no longer outlives its control process, and a cancellation that
  never returns no longer holds a run. When the control ends (its event
  sink's process died, or `Imp.Run.stop/1` was called while the run was still
  going), every cancellation registered by work in flight (an authorization
  decision being waited on, an RLM budget, an ACP terminal command) is called
  with `{:run_control_ended, reason}`, and then the task is killed; its
  monitor reports `:killed`. In 0.4.0 the task ran on until its next event and
  those effects were never cancelled. `Imp.Run.cancel/3` and
  `cancel_with_events/3` give the registered cancellations the cancel's
  `timeout` (5 s by default) and then end the task; the control ending, its
  owner going down, and work registered after a cancel give them 5 s. The
  cancellations are called at once, each in its own process, and one still
  running at the end of that time is abandoned. In 0.4.0 they were called one
  after another inside the control, so one that never returned held the run
  and made the cancel exit after 30 s. `Imp.Run.cancel/2` on a run whose
  control has already ended still exits (`:noproc`).
- `Imp.Run.start/3` takes `admission: {pool, limit}`: the run holds a place in
  the host's named pool instead of the machine-wide `:async_max_workers` pool,
  at most `limit` runs hold places in that pool at once, and a full pool
  returns `{:error, :busy}` without waiting. Runs started without it wait for
  the machine-wide pool as before.
- An `Imp.Deadline` reaches the work Imp starts in other processes. Every
  `Imp.Tasks` task, and so `Imp.parallel/3`, `Imp.best_of_n/3` attempts and
  `Imp.Run`, runs under the deadline of the process that started it, so
  requests made through `Imp.Clients.ReqLLM` inside are cut to the time left.
  In 0.4.0 only a model call made in the process that bound the deadline was
  cut; the same call through `Imp.parallel/3` or a run kept its full receive
  timeout. `Imp.Run.start/3` takes `deadline:` (milliseconds, `:infinity` or
  `{:deadline, absolute}`), capped by the caller's own, and returns
  `{:error, :deadline_exceeded}` without starting the run when the deadline
  passed while it waited for a place in the pool. A deadline does not bound
  that wait.
- An `Imp.Run` event sink that raises, throws or exits is no longer ignored.
  The run's owner is sent
  `{:imp_run_event_sink_failed, run_id, %{sequence: _, kind: _, reason: _}}`,
  and delivery goes on with the next event. Stopping or cancelling a run
  reports the event the sink was holding the same way (`reason:
  :in_sink_when_stopped`, since it may have been stored), and each event after
  it, which the sink never received, as
  `{:imp_run_event_undelivered, run_id, %{sequence: _, kind: _}}`. Run owners
  receive these messages where they received nothing before; an owner with a
  strict `handle_info/2` needs clauses for them.
- `Imp.Run.start/3` raises `ArgumentError` for an option it does not know. In
  0.4.0 it ignored one, so a misspelled `:authorize` started a run whose tool
  calls nobody was asked about. Its options are declared once, and its
  documentation lists them; an invalid capture bound now raises from
  `start/3` instead of returning `{:error, {%ArgumentError{}, stacktrace}}`.
- `Imp.Run.Event.kinds/0` lists every event kind Imp emits. ReActV2 no longer
  emits a `:final` event: it carried the same prediction as the
  `:run_finished` event after it. A host may still emit kinds of its own with
  `Imp.Run.emit/2`.
- `Imp.Trajectory.to_atif/2` names the event that ended the run
  `extra.terminal_event` (it was `extra.outcome`), and a tool result's
  `extra.outcome` is the `Imp.Tool.outcome/1` its loop recorded (`"result"`,
  `"refused"`, `"auth_refused"`, `"not_sent"`, `"unknown"`) rather than
  `"returned"` or `"error"` read from whether the event carried an error. A
  stored event whose kind Imp does not know keeps its kind string instead of
  becoming `:other`.

### ReActV2, adapters and models

- Prompts name types in plain words instead of Python annotations, in every
  adapter and in ReAct: `` `team` (one of: atlas, harbor, beacon, quill) ``
  where 0.4.0 wrote `` `team` (Literal['atlas', 'harbor', 'beacon', 'quill']) ``,
  and "string", "integer", "number", "true or false", "list of strings",
  "object", "code in python" for `str`, `int`, `float`, `bool`, `list[str]`,
  `dict[str, Any]` and `Code_python`. "(must be formatted as a valid Python
  int)" is "(must be formatted as an integer)", and ReAct's `:dspy`
  mode lists tool arguments as JSON. Fields, order, constraints and parsing
  are unchanged. A saved program's prompt text changes with this, so an
  optimized program may be worth re-evaluating.
- Values in prompts take their JSON spelling: `null`, `true` and `false`
  where 0.4.0 wrote `None`, `True` and `False`, in inputs, demos, ReAct
  observations and field constraints. The structured-output schema sent to a
  provider is named `outputs` (title `Outputs`) instead of
  `DSPyProgramOutputs`. The MIPROv2 proposer's dataset summary shows each
  example as `{"inputs": {...}, "outputs": {...}}` instead of
  `Example({...}) (input_keys={...})`. GEPA's reflective dataset and SIMBA's
  program listing use the same words, so an enum shows its allowed values.
- A non-string answer for a string field is kept as its JSON text (`"true"`,
  `"[\"x\", \"y\"]"`) where 0.4.0 gave Python's `"True"` and `"['x', 'y']"`;
  a `null` is no value, so a required field reports it missing and an
  optional one is `nil`, where 0.4.0 gave the string `"None"`.
- A `null` answer for any output field with a declared default takes the
  default, as an omitted one does; 0.4.0 kept the null and failed "is
  required". A present non-null value, `""` and `[]` included, still wins
  over the default.
- InferRules shows the rule model each example's values as JSON text
  (`null`, `{"k": 1}`, `1500000.0`) instead of Elixir's `inspect` output, and
  a `Jason.OrderedObject` (a ReAct observation, for one) renders as JSON in
  its own order instead of as the struct.
- Each ReActV2 step lists the task's output fields with their types and
  descriptions ("The outputs to produce are: ..."). Before, a model saw an
  output's description only inside `submit`'s parameter schema.
- `Imp.Adapter.SingleField` names an untyped input's type (`- ticket
  (string)`), where it wrote empty parentheses.
- The names follow the glossary: a step answered in text ends as `:answered`,
  the last request of an interrupted turn as `:last_text` with
  `last_request_note`, the step signature declares `metadata[:text_field]`, and
  the tool list sent to a provider is the `:tools_sent` event.
- A ReActV2 or ReAct prediction's fields are the signature's outputs and
  nothing else. `history`, `termination_reason`, `termination_cause`,
  `termination_error`, `finished_by_tool`, `unexecuted_tool_calls` and
  `context_projection` are in `prediction.metadata`; in 0.4.0 they were
  fields, so an output named `history` collided with the loop's own. Read
  `prediction.metadata.history` where `Imp.get(prediction, :history)` was
  read.
- `termination_reason` says only how the turn ended: `:answered`, `:submit`,
  `:finished_by_tool`, `:last_text`, `:forced_submit`, `:extracted` (the
  tools-disabled extractor wrote the outputs; it was `:forced_submit` with
  `completion_mode: :typed_extraction`, and `completion_mode` is gone), or
  `:incomplete` (no answer; it was the failure itself, such as `:max_iters`
  or `:context_window_exceeded`). `termination_cause` is set whenever the turn
  was interrupted, including a forced submit that answered, where 0.4.0 left
  it out: the interruption that led to the last request. An `:incomplete`
  turn names the same interruption, unless its context window was full or
  its `Imp.Deadline` had passed, which are named instead, so a turn that hit
  `max_iters` and then ran out of time is `:deadline_exceeded`. `Imp.Predict.ReAct`
  follows the same rule: `:dspy` mode's extraction after `max_iters`, a
  parse failure or an empty step is `:extracted` with that cause, spelled
  `:parse_error` (it was `:parse_failure`), and `:provider_native` mode's
  `:direct` is `:answered` with `termination_cause: :empty_tool_calls`.
  `Imp.Prediction.complete?/1` is false exactly for `:incomplete`, and
  `Imp.Observability` reads it.
- `ReActV2` offers `submit` only to a signature that needs it. A task
  signature with exactly one output of type `:string` and no constraints gets
  no `submit` tool:
  a step that comes back as text with no tool call is the answer, in that
  one request, with `termination_reason: :answered`, which is how Anthropic's
  tool runner, the OpenAI Agents SDK, LangGraph's ReAct and Pydantic AI end a
  turn. Its history event carries the output, as a `submit`'s does, and the
  answer is not also emitted as a `:reasoning` event. A signature with several
  outputs, one non-text output, or one constrained text output (an `enum`, a
  pattern, an answer shape) keeps DSPy's `submit` unchanged, so the allowed
  values reach the model in its schema; a step of such a signature that
  writes text instead of calling `submit` is the `:empty_tool_calls`
  interruption, and a turn that ends without a valid `submit` is
  `:incomplete`.
- A step of a one-text-output signature that calls nothing and says nothing
  is an empty answer: the turn ends there with `termination_reason:
  :answered` and no further request, because saying nothing is how a model
  declines to answer.
- An interrupted turn of a one-text-output signature (the step limit, a
  failed request) makes one more
  request with the same tools as every step and `tool_choice: "auto"`, and its
  text is the answer, with `termination_reason: :last_text`
  and `termination_cause` naming the interruption (`:max_iters`,
  `:prediction_error`, `:parse_error`). A completion that says nothing is an empty answer rather
  than an error. A tool call the model makes on that request anyway is not
  run; the text is the answer and the calls are listed in
  `unexecuted_tool_calls`. If the process's `Imp.Deadline` has already
  passed, no request is made and the turn ends `:incomplete` with
  `termination_cause: :deadline_exceeded`.
- `last_request_note`, a string, puts one line of host text in front of the
  last request of an interrupted turn, the text-only request or the forced
  `submit`, as a user message, keeps it in the returned history, and is saved
  with the program. Imp writes no sentence of its own.
- `ReActV2` gains `finish_on`, a map from tool name to
  `fn arguments, result, inputs -> {:finish, outputs} | :continue end`. A tool
  named there ends the turn with the outputs the function returns, which are
  validated against the signature exactly as a `submit`'s are, with
  `termination_reason: :finished_by_tool` and `finished_by_tool` (in the
  prediction's metadata) naming the tool. This is the shape Pydantic AI calls an output tool: one call both does
  the work and carries the answer. `:continue` leaves the loop running. When a
  step calls several terminal tools, the first in call order finishes the run
  and the rest still execute and are recorded; a `submit` in the same step
  still wins. The functions persist by registry name, like a tool runner.
- A `ReActV2` step answered in plain text with no tool call is now a thought
  that called nothing, not a parse failure. It used to fail the chat parse and
  re-ask the whole prompt through `Imp.Adapter.JSON`, which doubled the cost of
  the step and broke the provider's prefix cache; the text is now
  `next_thought` and `tool_calls` is empty, which is what the turn-ending rule
  above then reads. The text is
  recorded as that turn's thought in the history and shown back to the model as
  a plain assistant turn in any next request. `Imp.Adapter.Chat` reads a
  marker-free completion this way only for a signature that declares
  `metadata[:text_field]`; every other signature parses exactly as before, JSON
  fallback included.
- ReActV2 preserves provider-native reasoning text and opaque reasoning details
  across tool calls and saved-history reloads. ReqLLM receives the original
  continuation data, including provider extension fields and signatures, instead
  of losing it while rebuilding assistant messages. Operational history must be
  stored privately; run events and explicit diagnostic redaction still redact
  credential-shaped values.
- A `:model_request` event now records the whole request, not only its
  messages. Its metadata carries `:options`, the request options with the tool
  definitions removed, and `:tools_hash`, a SHA-256 of the canonical JSON of
  those definitions or `nil` when the request offered none. The definitions
  themselves are emitted once per run per distinct hash, as a new
  `:tools_sent` event whose input is the tool list as sent. A recorded run
  can now be reproduced call for call, without repeating an unchanging roster
  on every one. Both payloads are redacted like every other event.
- `Imp.LM.generate/3` takes `purpose:`, a name for what kind of call this is.
  It is recorded on the `:model_request` event's metadata as `:purpose` and is
  never sent to the provider, so a caller that makes more than one kind of model
  call can tell them apart on the record.
- The chat adapter's format options gain the `:history_note_renderer` seam,
  `fn signature, turn -> nil | String.t()`. It is consulted for every stored
  history turn, native tool turns included, after that turn's own messages, and
  its text becomes one user message immediately behind them. Before it, a host
  had no way to say anything *about* a turn that carried tool calls: those
  turns route through the native replay path, which consults neither
  `:output_renderer` nor `:input_section_renderer`. A note is data about the
  turn — the answer was never delivered, the account's allowance ran out — so
  the model reads it as the next thing after the turn, and the record the loop
  keeps is untouched.
- A signature field's description now reaches the provider in the JSON schema
  Imp builds for it (`Imp.Schema.json_schema/1`), so `ReActV2`'s `submit` tool
  declares each output field's own words about itself in its parameter schema.
  A field without a description still emits no `description` key. This is the
  only place a field description reaches a host that replaces the chat
  adapter's rendered system section.
- `Imp.Adapter.Types.ToolCall.from_map/1` accepts `tool` as a spelling of the
  tool name, beside `name` and `recipient_name` (the arguments already accepted
  `arguments`, `args` and `parameters`). `%{"tool" => ..., "arguments" => ...}`
  is what a model emits when it writes a tool call as JSON instead of calling
  natively, and `Imp.Predict.ReActV2` now executes such a call instead of
  recording a malformed-call observation and spending another iteration on it.
- `Imp.Clients.ReqLLM` returns a response whose body carries a provider error
  as a failed request (`Imp.LMError`, below). OpenRouter relays an upstream
  provider's refusal as a successful HTTP response with an error object and no
  choices, which ReqLLM decodes to an empty message; read as a completion, a
  refused request was a model that said nothing.
- `Imp.Predict.ReActV2.new/3` documents its options.
- `Imp.predict/2`, `Imp.chain_of_thought/2` and `Imp.configure/1` raise
  `ArgumentError` for an option or setting they do not know, and document the
  ones they take. In 0.4.0 `Imp.predict(sig, temperature: 0)` built a program
  that ignored the temperature; a request option given at the top level (such
  as `:temperature`, `:max_tokens` or `:n`) is now refused with a message that
  says to put it under `config:`. Settings of a caller's own, such as a request
  id, go through `Imp.context/2`. Both check Imp's own settings the same way,
  so `:track_usage` and `:warn_on_type_mismatch` must now be booleans. ReAct,
  ReActV2, Avatar, CodeAct, ProgramOfThought, MultiChainComparison and
  `Imp.Optimizer.Avatar` give the same `config:` message.
- `:max_errors` and `:retriever` are no longer settings. Nothing read
  `:retriever`; give a retriever to the program (`Imp.rag/3`). `:max_errors`
  was read only by BootstrapFewShot, RandomSearch and COPRO, as the fallback
  for their own `:max_errors`; given none, they now use 10, the setting's old
  default, and their reports say `max_errors_source: :default` where they said
  `:settings` or `:teacher_settings`. `Imp.configure/1`, `Imp.context/2` and an
  optimizer's `:teacher_settings` refuse either key with a message naming where
  it belongs.
- `ReActV2`'s `submit` and a `finish_on` callback's outputs find a field by
  the text of its name. A string signature keeps a field name as a string
  when its atom did not exist yet, so outputs keyed by that atom were never
  found and the turn ended `:incomplete` with `missing_output_fields`.
- RLM controller code may call every function of `Enum`, `Keyword`, `List`,
  `Map` and `String` except `String.to_atom`, `List.to_atom`,
  `String.splitter`, `Enum.random`, `Enum.shuffle` and `Enum.take_random`, and
  may pass them anonymous functions and captures, which the interpreter runs
  under the cell's step and value budgets. Registered tools, `llm_query` and
  `submit` stay outside such functions; a function's patterns may pin a
  variable (`fn ^target -> ... end`). Without a module, the Kernel data
  functions `elem/2`, `to_string/1`, the `is_*` type checks, `length/1`,
  `map_size/1`, `tuple_size/1`, `byte_size/1`, `abs/1`, `round/1`, `trunc/1`,
  `div/2`, `rem/2`, `max/2` and `min/2` are available. Other calls return
  `{:function_not_allowed, ...}`. Assignment takes the same patterns as a
  function clause (`{a, b} = pair`, `[first | rest] = lines`), `[x | acc]`
  builds a list, and a `for` generator takes a pattern and a map
  (`for {key, n} <- counts`) and the `into:` and `uniq:` options. `into:` and
  `uniq:` were ignored, and `reduce:` is refused with
  `{:unsupported_for_option, :reduce, ...}`. A function held in a variable or
  written in place can be called directly (`f.(x)`,
  `(fn x -> ... end).(x)`), under the same rules as one a library call runs.
- RLM controller code that calls a value that is not a function (`g = 1;
  g.(1)`) fails that turn with `{:not_a_function, "g", 1}`, which the
  controller reads and repairs. It ended the whole call with
  `{:module_call_failed, Imp.Predict.RLM, ...}` whenever the variable's name
  was not already an atom. An unexpected error inside the interpreter now
  fails the turn the same way, as `{:interpreter_error, message}`.
- The RLM controller prompt names one reply shape, `{"reasoning", "code"}`,
  for every turn including the last, which calls `submit/1` from code. It
  also offered a bare JSON object of the outputs as a final answer, which a
  text reply never in fact got. The controller's first reply almost always
  failed to parse: gpt-5.4 sends several JSON objects in one reply (its
  action twice, or several actions written ahead of their outputs). Such a
  reply now runs the first object that carries code, as a REPL would.
- `max_preview_chars` bounds every RLM variable preview in characters. A
  list was previewed as its first `max_preview_chars` items, so after
  `lines = String.split(log, "\n")` on a 20,000-line log the controller's
  turn message grew from 2,351 to 89,312 bytes. A list, map, tuple or other
  term is now previewed as the first `max_preview_chars` characters of its
  printed form, with `length` or `size` beside it, as upstream previews
  `str(value)`; a map's preview shows its values, not only its keys. A
  variable holding a tuple, which could not be encoded into the turn message
  and ended the call, is previewed the same way, and so is an integer too
  long for the preview.
- RLM `max_recursion_depth` is one rule: the number of levels of child RLMs
  below the root. `recurse/2` already allowed a child at depth
  `max_recursion_depth`, but `rlm_query*` started one only below it, so the
  default of 1 gave `recurse/2` a child and `rlm_query` none. Both now allow
  one level by default; `max_recursion_depth: 0` makes `rlm_query*` a one-shot
  sub-LM query, as the standalone runtime's `max_depth=1` does.

### Signatures

- Numeric bounds are `minimum` and `maximum`, JSON Schema's names, in
  validation, in the JSON schema and in the rendered prompt, and a validation
  error's rule is `:minimum` or `:maximum`. `min` and `max` raise an
  `ArgumentError` naming the key to use; before, the documented
  `minimum`/`maximum` were ignored. Pydantic's `ge` and `le` still mean the
  same bounds.
- Constraint keys are read by one normalizer for validation, the JSON schema
  and the rendered prompt, so `"min_length"`/`"max_length"` given as strings
  now constrain validation and the schema too, as they already did the
  prompt.
- An `enum` constraint with atom members raises `ArgumentError` when the
  field is built, showing the string members to write instead. An answer
  arrives as text and a signature saves as JSON, so `enum: [:atlas]` failed
  every parse ("must be one of [:atlas, :harbor]"), and returning the atom
  would have made a program answer differently after `Imp.save!`/`Imp.read!`.
- A signature refuses a repeated field name, on one side or across the arrow,
  and names it: the string form raises a signature parse error, the map
  form and `Imp.Signature.extend/3` raise `ArgumentError`, and `:a` and `"a"`
  are the same name. Before, only a name on both sides of the arrow raised,
  and `"q -> a, a"` built two fields called `a`.
- `json_retries: n` makes up to n retries of a parse failure, each the
  original request plus the latest failure's message, and stops at the first
  reply that parses. Before, any n above 0 made one.
- An arity-3 metric receives `nil` as its trace from `Imp.evaluate/4` and the
  optimizers' validation scoring, and the program's trace while an optimizer
  bootstraps demos, as DSPy's `trace=None` has it. Before, evaluation passed
  the trace too, so a ported metric that scores continuously when evaluated
  and passes or fails when compiling gave its compile-time answer.
- `Imp.read!/2` and `Imp.load!/2` load a saved program in a VM that never
  created the atoms it names: a demo's field names, a RAG program's `query_field` and
  `context_field`, a memory retriever's document keys, tool names and tool
  policies, and any atom tag in saved metadata load as strings when the atom
  does not exist, and no atom is created. `Imp.Example`, `Imp.Prediction` and
  the tool index look them up by text; a caller reading saved metadata
  directly may find `metadata["my_flag"]` where it expected
  `metadata[:my_flag]`, which is `nil` in a VM where `:my_flag` does not
  exist yet. It raised `ArgumentError` ("not an already existing
  atom"), so a router saved by one process failed to load in a fresh one.

### Errors and shapes

Every change here is breaking for code that matches on the old shape.

- A failed request from `Imp.Clients.ReqLLM` is
  `{:error, %Imp.LMError{}}`, whatever failed: an HTTP error status, an error
  relayed inside a successful response, a connection that failed, or an
  exception raised inside ReqLLM, or a response or stream of a shape ReqLLM
  never returns. It carries `status`, `retryable` and
  `context_window_exceeded`, with ReqLLM's own error unchanged under
  `reason`. `retryable` is `true` for a 408, 425, 429 or 5xx status, for a
  request that never reached the provider (connection refused, no free
  pooled connection, closed or timed out before sending), for any other
  status whose ReqLLM error says `retryable: true`, and for a timeout while
  waiting for the answer or a stream that failed after it started; those
  last two may have run and been billed, and a retried stream repeats chunks
  the caller already has. A 409 is never retryable. In 0.4.0 these reached
  the caller as ReqLLM's structs, as `{:req_llm_generate_failed, text}`,
  `{:req_llm_stream_failed, text}`, `{:invalid_req_llm_response, text}` or
  `{:invalid_req_llm_stream, text}`, or, for a context-length refusal, as
  `Imp.ContextWindowExceededError`, which is gone. An option the client refuses raises `ArgumentError` before the
  request, as every other option error does.
- `Imp.Errors.retryable?/1` reads `Imp.LMError`'s `retryable`, and the new
  `Imp.Errors.context_window_exceeded?/1` its `context_window_exceeded`, each
  through `{:error, _}` and `{:lm_failed, _, _}`. In 0.4.0 `retryable?/1` was
  true only for an `Imp.LMError` that nothing built.
- An LM client that raises is `{:lm_failed, client, exception}` with the
  exception struct, and one that throws or exits is
  `{:lm_failed, client, {kind, value}}`. In 0.4.0 both were the message text.
  The same holds for `{:module_call_failed, module, reason}` from
  `Imp.call/2`, `{:retriever_failed, _, reason}`, `{:tool_error, tool,
  reason}`, `{:tool_policy_error, tool, reason}`, `{:parallel_program_failed,
  reason}`, `{:ensemble_program_failed, reason}`, `{:optimizer_failed,
  optimizer, reason}` and `{:optimizer_capabilities_failed, optimizer,
  reason}`, the MCP import's `:mcp_connection_failed` and
  `:mcp_tool_import_failed`, and `Imp.ACP`'s `:program_factory_failed`,
  `:input_mapper_failed`, `:output_renderer_failed`, `:before_turn_failed`,
  `:permission_policy_failed` and `:host_request_failed`, and for
  `{:http_transport_failed, transport, reason}` from `Imp.HTTP` (and so the
  training clients' `:training_transport_failed`, `:training_refresh_failed`
  and `:training_cancel_failed`, and `Imp.Retrievers.HTTP`'s
  `{:transport, reason}`),
  `{:embedding_provider_failed, provider, reason}` from `Imp.Embeddings`, and
  `Imp.Predict`'s `{:adapter_format_failed, adapter, reason}` and
  `{:adapter_lm_opts_failed, adapter, reason}`, and
  `{:program_runtime_error, reason}` from `Imp.Predict.ProgramOfThought` and
  `Imp.Predict.CodeAct`, whose model still reads the exception's message.
  Several of these carried text on one path and a term on another.
- A completion that cannot be read as the outputs is always
  `%Imp.AdapterParseError{}`, with a `kind`: `:malformed`, `:missing_fields`
  (`reason` is the missing names), `:invalid_fields`, `:unsupported_output`
  or `:other`; `kind` is required. In 0.4.0 an adapter could return the struct,
  `{:missing_output_fields, names}` or `{:unsupported_lm_output, raw}`, and
  `Imp.Adapter.TwoStep` `{:two_step_extraction_failed, reason, completion}`.
  `Imp.Predict.ReAct`'s final outputs follow the same rule: in 0.4.0 a missing
  output was `{:missing_output_fields, names}` and one of the wrong type an
  `%Imp.AdapterParseError{}` with no `kind`.
- `Imp.Predict` returns that struct, with `trace` (the redacted
  messages, the raw completion, and which output fields were read) and, for
  `n > 1`, `completion_index`. In 0.4.0 it returned
  `%{reason: {:error, reason}, trace: trace}`, and an `n > 1` failure
  `{:completion_parse_failed, index, reason}` inside it. Because of that map,
  a `ReActV2` step that could not be parsed was recorded as
  `termination_cause: :prediction_error`; it is now `:parse_error`.
- When the chat or XML adapter's JSON fallback makes its request and that
  request fails, `Imp.Predict` returns the LM's error. In 0.4.0 it
  returned the original parse failure with the LM error inside it.
  `Imp.Adapter.TwoStep`'s extraction request does the same: when it fails,
  the call returns that `Imp.LMError` (or `{:lm_failed, _, _}`), so a 429
  from the extraction model reads as retryable. In 0.4.0 it was
  `{:two_step_extraction_failed, reason, completion}`.
- A failure reason that holds a pid, port or reference, such as a
  `GenServer.call` timeout, is written to JSON (optimizer checkpoints and
  reports, `Imp.History.dump/1`) as its inspected text. Before, the write
  raised `Protocol.UndefinedError`.
- `Imp.Predict.Refine` and `Imp.Predict.Assertions` return
  `{:error, reason}` like every `Imp.Module`: `:no_attempts` with `n: 0`
  (`max_attempts: 0` for `Assertions`), `{:refine_fail_count_exceeded, reason}`,
  or the last
  attempt's reason. In 0.4.0 they returned `{:error, reason, history}`, which
  `Imp.call/2` reported as `{:invalid_module_result, module, text}`.
- A tool a tool policy does not allow is `{:tool_denied, tool, :tool_policy}`,
  and a tool a run's `:authorize` callback refuses is
  `{:tool_denied, tool, reason}` with the callback's reason. In 0.4.0 they
  were `{:tool_denied, tool}` and `{:tool_authorization_denied, tool, reason}`.
- MCP import refusals: a tool named after one in `:reserved_tool_names` is
  `{:mcp_tool_name_reserved, tool, servers}` (it shared
  `:mcp_tool_name_collision` with two servers offering one name); an
  unauthorized descriptor is `{:mcp_server_not_authorized, server, answer}`,
  where `answer` is what `:authorize` returned or `:not_trusted`; a descriptor
  that cannot be addressed is `{:invalid_mcp_server, index, %ArgumentError{}}`
  (it was `:mcp_connection_failed` with the message and no name); and a
  server left out under `on_failure: :drop` carries the same reason term the
  import would have refused with, where 0.4.0 shortened its detail to text.
- `Imp.HTTP.request/6` and `Imp.Retrievers.HTTP` refuse a method they cannot
  send as `{:http_method_not_supported, refuser, method}`; one of them said
  `{:unsupported_http_method, method}`.
- `Imp.stream/3` without `provider_stream: true` ends a failed call with
  `%Imp.Streaming.Messages.StreamResponse{chunk: {:error, reason}, done: true}`,
  as a provider stream does; it yielded a bare `{:error, reason}`.
- An `Imp.Telemetry` span's `[:exception]` event carries `:kind`, `:reason`
  and `:stacktrace`, as `:telemetry.span/3` does; it carried `:error` as text.
  `Imp.Redaction` keeps an exception's type while redacting its fields.
- `Imp.optimize!` raises `Imp.Error` with the reason `Imp.optimize` would
  have returned when optimization fails, and `ArgumentError` only for a call
  that could never run (including options the optimizer refused). In 0.4.0
  every failure was an `ArgumentError` carrying text. `Imp.Error` is now that
  exception; nothing raised it before.
- `Imp.Example` and `Imp.Prediction` keep each key as the atom or string it
  was given, and look keys up by their text. In 0.4.0 a string key became an
  atom whenever that atom already existed in the VM, so the same data could
  come back keyed either way. Data read from JSON now keeps its string keys:
  a history turn loaded with `Imp.History.load!/1`, or a demo field a
  signature does not declare in a saved optimizer artifact.
- A tool receives its arguments as a map with string keys, from every runtime
  (ReActV2 and its `finish_on` callbacks, ReAct, Avatar, CodeAct, RLM) and
  from `Imp.Tool.call/2`, which turns atom keys into strings at every depth.
  In 0.4.0 a key became an atom when that atom already existed in the VM, so
  the same tool could see either shape. Match on strings: `fn %{query: q}`
  becomes `fn %{"query" => q}`. Tool policies and `unexecuted_tool_calls` see
  the same string keys. The built-in tools follow: `Imp.ACP.Host`'s
  `fetch` tool and `Imp.Optimizer.Playbook.EquationSearch.solve_tool/0` read
  string keys only.

### Public surface: what is exported

- Gone, with what to use instead:
  - `Imp.MCP.Client`, `Imp.MCP.HTTPClient`, `Imp.MCP.StreamableHTTPClient`,
    `Imp.MCP.StdioClient`, `Imp.MCP.Catalog` and `Imp.MCP.import_tools`:
    `Imp.MCP.connect/2`, which returns the tools and one `cleanup`. A tool
    schema spelled `:input_schema` is no longer accepted; MCP's
    `"inputSchema"` is.
  - `Imp.ACP.MCP` and `Imp.ACP.MCP.Import`: `Imp.MCP.connect/2`, and
    `Imp.ACP.ToolKind.derive_all(import.annotations)` for `:tool_kinds`.
  - `Imp.Core.ToolCall` and `Imp.Core.ToolResult`, which nothing built, and
    `Imp.MCP.json_rpc_result` and `Imp.MCP.initialize_params`, which
    nothing called.
- No longer documented, because they are Imp's own machinery:
  `Imp.Clients.TRLProtocol`, `Imp.Optimizer.Utils`,
  `Imp.Telemetry.execute` and `span`, `Imp.Prediction.set_lm_usage`,
  `Imp.MCP.Connections.import_tools` (use `Imp.MCP.connect/2`), the
  transition functions of `Imp.Training.FastSlow.State`, and the `validate_*`
  option validators. `compile/N` on an optimizer that `Imp.optimize/3,4,5` or
  `Imp.train/4` runs is no longer documented either: call those, which take
  the same datasets and invocation options with one argument order.
  `KNNFewShot`, `Ensemble`, `Playbook` and `InstructionSearch` keep
  `compile`, because the facade does not run constructors or workflows.
- Now documented: `Imp.Deadline`, `Imp.Observability.Inspection` (what
  `Imp.Observability.inspect_artifact/2` returns, with `json_safe/1`),
  `Imp.Run.barrier/3`, `Imp.Run.new_event_id/1`,
  `Imp.Run.register_cancellable/1` and `unregister_cancellable/1`,
  `Imp.Tasks.async/1` and `async_nolink/1` (tasks that carry the caller's
  settings, run and telemetry context), and the modules public
  functions return or call: `Imp.Predict.RLM.SandboxSerializable`,
  `Imp.Optimize.Anything.Result`, `Imp.Optimizer.Parameter.Set` and
  `Imp.Optimizer.Parameter.Change`, and `Imp.Optimizer.GEPA.Callback`.
- `Imp.MCP`, `Imp.MCP.Connections`, `Imp.MCP.Import`, `Imp.MCP.CallFailure`,
  `Imp.ACP` and `Imp.ACP.ToolKind` are stable, and so are the LabeledFewShot,
  BootstrapFewShot, random search, KNNFewShot, COPRO, MIPROv2, GEPA, SIMBA,
  InferRules and Ensemble optimizers, `Imp.Optimizer.Artifact` and
  `Imp.Optimizer.Report`: stable means they do not break within 0.x without a
  deprecation. `Imp.ExternalCommand` and `Imp.Tasks` are experimental. The
  documentation lists the MCP
  and ACP modules in a group of their own instead of under experimental
  optimizers.
- An ACP agent started without `:agent_info` introduces itself as `imp` at
  Imp's version, not as `imp-acp` `0.1.0`.
- Plug is no longer a dependency of Imp. The demo MCP servers, its only user,
  are not in the package.

### Public surface: facade and behaviours

- `Imp.load/2` takes the map `Imp.dump/1` returns and gives `{:ok, program}`
  or `{:error, %ArgumentError{}}`; `Imp.load!/2` is its raising form.
  Reading a file `Imp.save!/2` wrote is `Imp.read!/2`, which was
  `Imp.load!/1`. `Imp.Saving` has the same four functions.
- `Imp.react/3` builds `Imp.Predict.ReActV2`, and `Imp.react_v2` is gone.
  `Imp.Predict.ReAct`, the earlier loop, has no facade name; its port of
  DSPy's `dspy.ReAct` is `mode: :dspy`, which was `:dspy_3_2_1`. A program
  saved with `"dspy_3_2_1"` still loads.
- `Imp.Predict.Predict` is `Imp.Predict`. It, `Imp.Predict.ChainOfThought`
  and `Imp.Predict.ReActV2`, which `Imp.react/3` builds, are stable.
- `Imp.Signature.ParseError`, which every signature constructor raises, is
  documented, with its `:input` and `:position` fields.
- `Imp.Retrievers.KNN` is deleted. It did not implement `Imp.Retrieve`, and
  `Imp.Retrieve.Memory` is the token-overlap retriever.
- The `compile` function of `Imp.Optimizer.BootstrapFewShotWithRandomSearch`
  is hidden, like the other optimizers'; `Imp.optimize/4` runs it.
- `Imp.Adapter.Types.Document`, `History`, `Citation` and `Type`, and
  `Imp.Datasets.Error`, are documented. `priv/public_api.json` now lists every
  packaged module, the `@moduledoc false` ones among `excluded_modules`.
- `Imp.LM` declares `generate(lm, messages, opts)`, where `lm` is the struct
  or the module it was given; `request/2` and `stream/3` stay optional. An LM
  is a struct or module implementing it. The `%{module: module, opts: opts}`
  map and a bare two-argument function, both deprecated in 0.4.0, are
  refused: at construction with the `:lm` option's error, and by
  `Imp.LM.generate/3` as `{:error, {:not_an_lm, lm}}`. The clients'
  `generate/2` is gone; call a client through `Imp.LM.generate/3`, as
  `Imp.LM.generate(Imp.Clients.ReqLLM.new(model), messages)`. `Imp.LM.Static.new/1` takes
  `:model`, the model a static client stands in for.
- `Imp.Retrieve` declares `retrieve(retriever, query, opts)`; a module
  retriever receives itself first, as an LM does. A two-argument function is
  still a retriever.

### Public surface: one name per idea

- MCP names a server descriptor a descriptor and a server's name
  `server_name`. `Imp.MCP.CallFailure` has `server_name`, `tool_name` and the
  descriptor's `index` where it had `server` and `tool`; an `unavailable` entry
  has `server_name` where it had `server`; `tool.metadata.mcp` gains `index`;
  `:authorize`'s two-argument context is `%{cwd:, descriptor:}`.
- One allow/deny vocabulary: `:allow` or `{:deny, reason}`, as `Imp.Run`'s
  `:authorize` and `Imp.ACP`'s `:permission_policy` already answer.
  `Imp.MCP.connect/2`'s `:authorize` returned `:ok` or `true`; a refused
  descriptor is now `{:mcp_server_not_authorized, server_name, reason}`, with
  `:not_trusted` for one outside `:trusted_servers`. A `:tool_policy` function
  returned `true`, `:ok` or `false`; a refused call is now
  `{:tool_denied, name, reason}`, where `reason` names what denied it:
  `:tool_policy` for a name or list policy, or the function's own reason.
  Any other answer refuses with `{:invalid_decision, answer}`.
  `Imp.ToolPolicy` is documented.
- DSPy's names for DSPy's ideas. `num_threads` is the concurrency option of
  `Imp.Evaluate`, `Imp.evaluate/4`, `Imp.Predict.Parallel`,
  `Imp.Predict.Search`, `Imp.Experiment`'s evaluation options,
  `Imp.Clients.ReqLLMBatch`, and the GEPA, MIPROv2, SIMBA, BetterTogether and
  BootstrapFinetune optimizers, where it was `max_concurrency`; COPRO, InferRules
  and random search already said `num_threads`. COPRO's
  `proposal_max_concurrency` is `proposal_concurrency`, as GEPA's is. `Imp.Predict.Refine` counts its attempts in `n`,
  as `Imp.Predict.BestOfN` and DSPy's `Refine` do, where it had `max_attempts`;
  a Refine saved with `"max_attempts"` still loads. `Imp.Predict.RLM` takes
  `max_iterations` only, DSPy RLM's name; `max_iters` was a second spelling.
- `Imp.Optimizer.RandomSearch`, `Imp.Optimizer.BootstrapRS` and
  `Imp.Optimizer.BootstrapFewShotWithRandomSearch` were three names for one
  optimizer; it is `Imp.Optimizer.BootstrapFewShotWithRandomSearch`, DSPy's
  class name. Its `candidates` and `demos_per_candidate` options, second names
  for `num_candidate_programs` and `max_bootstrapped_demos`, are gone.
- The ReActV2 loop's guidance key `finish_tool` is `submit_tool`, the tool it
  names. The step signature's `metadata[:text_step]` is
  `metadata[:text_field]`: it names the output field a text reply fills.
- A ReActV2 `:reasoning` event says `forced: true` where it said `forced?`,
  and names its step as `step:` where it said `turn:`: a turn is one call of
  the agent, and a step is one request inside it.
- `Imp.MCP.connect/2`'s `:credentials` option is `:credential_store`, the
  `Imp.MCP.OAuth.Store` a descriptor's `"credential"` is looked up in.
  `Imp.MCP.OAuth.Pending` has `server_url` where it had `resource_url`, the
  name `begin/3` and `authorization_header/3` give the same URL. Credentials
  already on disk load unchanged.
- An `Imp.Clients.MLXLMTrainer` `:runner` is called with `cwd:` where it was
  called with `cd:`, the name ACP, MCP and `Imp.MCP.connect/2` use.
- `Imp.Optimizer.GEPA.Callback` hooks take `(event, context)` only; a bare
  callback module's context is `nil`. A bare module's one-argument hooks were
  called and its two-argument ones were not.
- A ReActV2 agent loaded from a saved program asks the model what the agent it
  was saved from asked. Loading lost the step predictor's loop guidance, its
  request shape (`response_instruction: false`, `omit_empty_request: true`)
  and its tool roster's atom keys; they are rebuilt from the signature and
  tools. A host's own `:adapter_opts`, such as renderers, are functions and
  are not saved; pass them again.
- `Imp.load/2` given a string says to read a file with `Imp.read!/1`.
- One `load` contract: `load` returns `{:ok, value}` or `{:error, reason}`,
  `load!` raises, and `read!` reads a file. The `load` of `Imp.Signature`,
  `Imp.History` and `Imp.Optimizer.Report` raised, so each is now
  `load!/1`. `Imp.Clients.TrainingJob`'s `load` is `load!/2`, and its old
  `load!`, which read a checkpoint file, is `read!/2`.
  The dataset loaders that read a file are `read!`:
  `Imp.Datasets.GSM8K.read!/1`, `Imp.Datasets.HotPotQA.read!/1`,
  `Imp.Datasets.MATH.read!/1` and `Imp.Datasets.DataLoader.read!/3`.
  The `load` of `Imp.Datasets.Colors`, which builds examples from records and raises,
  is `load!/1`.

### GEPA

- `Imp.Optimizer.GEPA` is DSPy's GEPA unless told otherwise: with no
  `:execution_profile` it runs `:gepa_v0_1_4_merge` (merge on, perfect
  minibatches skipped, no evaluation cache, the pinned RNG and budget), or
  `:gepa_v0_1_4` with `use_merge: false`. The old default is
  `execution_profile: :beam_native`, which a run using ComBee, parallel
  proposals, `:feedback_fn`, `:reflection_strategy`, a module selector other
  than `:round_robin`, a parent selector other than `:pareto`, or another
  option the DSPy profile fixes now has to name; without it, those options
  raise.
- Under the DSPy profiles, `:max_full_evaluations` is converted to a metric
  budget as DSPy converts `max_full_evals` (times the training plus validation
  set sizes) instead of being counted beside it, and giving it together with
  `:max_metric_calls` raises. `:max_reflection_calls` raises in `new/2` under
  the default profile, whose reflection limit is derived from the budget.
- GEPA optimizes agents. For `Imp.react/3` the reflection model reads the
  whole run of each example as `Context` (every thought, tool call and tool
  result, and the outputs, except when `finish_on` or the extractor ended the
  turn) and the
  loop's tools by name, description and arguments. It used to read only the
  first step, with an empty history.
- A predictor called several times in a run is reflected on at one call drawn
  at random with the optimizer's seed, not always its first call.
- Under the DSPy profiles, a metric that returns only a score gives the
  reflection model "This trajectory got a score of X." with the row's score,
  as DSPy does, instead of `improve` or `successful`.
- An iteration whose chosen component has no reflection records ends without
  a reflection call.
- A program with an `Imp.History` input, or any struct among its inputs, no
  longer crashes the reflection prompt under `reflection_record_mode:
  :beam_native`; the history is shown as its turns.
- A predictor with two `Imp.History` inputs raises when GEPA builds its
  reflection records, as DSPy's GEPA asserts there is one.

### Retrieval

- `Imp.Retrieve.Memory` (`Imp.memory/2`) returns only documents that share a
  word with the query, up to `k`. It returned `k` documents whatever they
  scored, so a document with no word in common came back with `score: 0`
  because it came first in the list.

## 0.4.0 — 2026-09-17

- `Imp.ACP` and `Imp.MCP.connect/2` are part of Imp. The separate `imp_acp`
  package is retired: `Imp.ACP.start_link/1` and `Imp.ACP.run/1` expose an
  ordinary Imp program to an ACP host, and `Imp.MCP.connect/2` imports
  authorized MCP servers through ExMCP as ordinary tools with explicit
  connection cleanup. There is no compatibility shim; a consumer that depended
  on `imp_acp` depends on `imp` alone and changes the module prefix. ExMCP is
  declared `runtime: false`, so an OTP release that uses either must list
  `applications: [ex_mcp: :load]` in its release definition. Ordinary Imp
  startup still starts no protocol endpoint.
- A map or list value in a prompt, including a structured tool result, now
  renders the way DSPy renders a dict: `json.dumps(..., ensure_ascii=False)`
  with Python's default separators, complete. It was `inspect/1` at its
  default limit, which cut any structured value past fifty elements to an
  ellipsis the model could not count and no host bound could measure. A term
  JSON cannot carry renders as a complete `inspect`.
- ReActV2 sends the tool roster once, natively, and never renders it as text;
  it no longer declares a `tools` input field or writes "You are an Agent..."
  into `signature.instructions`. The loop's guidance (`finish_tool`,
  `input_names`, `output_names`, `tool_names`) travels to the adapter as data
  through the new `:adapter_opts` on `Imp.Predict.Predict` and
  `Imp.Predict.ReActV2`. Each step's request is now the previous step's request
  plus the newest exchange, which is what a provider's prompt cache is keyed
  on; before, the first user message changed shape between steps one and two
  and the roster was re-sent after the history on every call.
- The chat adapter's format options (`Imp.Adapter.Chat`) gain `:system_renderer` (a function of the
  signature and the format options, default the DSPy system message),
  `:guidance` (rendered by the default system renderer the way ReAct's
  instructions used to read), and `:omit_empty_request` (end the request on
  the newest history message rather than an empty user message; off by
  default, so the JSON and XML adapters keep DSPy's shape).
- `:reasoning_effort` is the one reasoning option on `Imp.Clients.ReqLLM`, at
  construction or per call, and `:openrouter_reasoning` is gone. A call naming
  `reasoning_effort: nil` spends no reasoning on that call, which is what
  ReAct's forced submit asks for; previously that nil, combined with a
  configured OpenRouter effort, raised and ended the turn without an answer.
  Which OpenRouter wire field carries the effort is a separate switch,
  `openrouter_reasoning_wire: :top_level | :nested` (default top-level, as
  ReqLLM sends it); it names an encoding, never a value. Saved programs
  allowlist both in place of `openrouter_reasoning`.
- Changed the cost a host reads off a model call to a plain number. The
  `:model_response` event's `metadata.cost` is now the provider's reported
  total in USD as a non-negative float, or `nil` when the provider reported
  nothing Imp can read as a number; it was whatever the provider library put
  there, most recently ReqLLM's private billing breakdown map. When the
  provider reported a breakdown, the whole map is on the event as
  `metadata.billing`, untouched; when it reported none, there is no
  `:billing` key. `Imp.Core.LMResponse` carries the same pair as `:cost` and
  the new `:billing` field, and reads a total given as a number, a string, a
  `Decimal`, or a breakdown map. A host summing spend reads the number and no
  longer has to know a provider library's internal shape.
- Added `Imp.MCP.OAuth`, a credential store for remote HTTP MCP servers that
  require a browser-authorized OAuth grant. It begins the flow, listens on
  `127.0.0.1` for the redirect, stores the grant encrypted as one file per
  credential under a directory the host names, and refreshes it without the
  person. A grant is bound to the URL it was authorized for, so a descriptor
  cannot point another server's credential at itself. A refresh the
  authorization server answers with `invalid_grant` is reported as
  `{:mcp_oauth_reauthorization_required, credential}` rather than as a
  retryable failure.
- Added two server descriptor auth forms that `Imp.MCP.connect/2` resolves to
  headers at connect time: `%{"type" => "oauth", "credential" => ref}`, which
  reads the store passed as the new `:credentials` option, and
  `%{"type" => "bearer_env", "variable" => name}`, which reads the host's
  environment and connects with no `Authorization` header (logging one
  warning) when the variable is unset, unless `"required" => true`. Static
  `"headers"` are unchanged.
- Added `on_failure: :drop` to `Imp.MCP.connect/2`. Under it a server whose
  transport or `initialize` fails, which accepts the connection and never
  answers, or which cannot answer `tools/list`, is left out with its client
  closed instead of failing the whole import: the tools of the servers that did
  connect are returned, and the new `unavailable` field of `Imp.MCP.Import`
  names each dropped server with a short reason and with the `index` of its
  descriptor in the list that was passed in. The default `on_failure: :refuse`
  keeps the previous all-or-nothing behaviour, except that a transport that
  refuses the connection is now reported as `{:mcp_connection_failed, reason}`
  rather than as the import helper's exit. A descriptor `:authorize` refused,
  one whose declared `auth` cannot produce a header, a malformed one, and
  anything raised by the caller's own `:tool_filter` refuse the import under
  both settings.
- Each MCP dial is now bounded by `:timeout` on its own rather than sharing one
  budget with the whole list. A host that accepts the connection and answers
  nothing returns within neither `:handshake_timeout` nor `:era_probe_timeout`,
  so two of them used to exhaust the shared budget and refuse the import as
  `{:error, :mcp_import_timeout}` whatever `:on_failure` said; now each costs
  its own timeout and is reported as `{:mcp_connection_failed, :timeout}`.
- An abandoned dial no longer leaks its client. `ExMCP.Client` traps exits and
  ignores the `EXIT` from the process that started it, so killing the import
  helper at a timeout left every half-open client alive, holding its socket,
  for the life of the node.
- A `tools/list` body that is not a catalog is now reported as
  `{:mcp_tools_list_failed, server, {:invalid_mcp_tools_response, shape}}`
  rather than as a bare `{:invalid_mcp_tools_response, shape}` that named no
  server.
- The repository is public. Installing at a tag needs no credentials, and the
  README, docs, and livebooks no longer describe a private source release.
- Removed the evidence-certification bookkeeping from the source checkout. It
  never shipped in the package, so a consumer sees no change; the benchmark
  harness it wrapped is unchanged.
- Added [Benchmarks](https://github.com/deepfates/imp/blob/v0.4.0/docs/BENCHMARKS.md)
  and its [results table](https://github.com/deepfates/imp/blob/v0.4.0/benchmarks/RESULTS.md).
  Every number this repository publishes is one row in that table, carrying
  the dataset and its license, the model, the provider, the date, the commit,
  and the command that produced it; prose elsewhere cites a row rather than
  restating a number. The benchmarks page says what each command needs from
  you — key, Python environment, time, rough cost — and separates a row a
  stranger can re-measure with an API key from one that only recomputes
  statistics from committed rows, and from the claims that cannot be
  re-measured at all. Neither page publishes an aggregate or a release score.
  The tutorial's rows were re-measured live for this release, a month after the
  first run, and both runs are recorded. They live in the repository, not in
  the installed package.

## 0.3.2 — 2026-09-01

- Made the RLM controller prompt describe the restricted language actually
  accepted by its interpreter, including supported repair paths and explicit
  unsupported forms.
- Preserved explicit no-retry provider policy across Req function, module, and
  `{module, function, args}` adapters.

## 0.3.1 — 2026-08-23

- Clarified the supported center versus pre-1.0 advanced workflows, the exact
  meaning of typed inputs and outputs, and the restricted-interpreter security
  boundary.
- Completed the structured signature field reference and corrected cold-reader
  prerequisites and cross-references.

## 0.3.0 — 2026-08-23

Private Git source release. Imp is not published to Hex.

### Added

- Typed code fields, richer structured signatures, and consistent Chat, JSON,
  and XML adapter validation.
- General program parameters and checksummed parameter artifacts for named
  predictors, tools, playbooks, and custom optimizable components.
- Full MIPROv2 TPE search, expanded GEPA/SIMBA/COPRO behavior, persistent
  playbook optimization, optimizer checkpoints, and Optimize Anything program
  artifacts.
- Addressable ReActV2 and RLM runs with ordered events, cancellation, explicit
  per-effect authorization, and owner-death cleanup.
- MCP stdio process ownership that reaps server process groups when a call or
  run is cancelled.
- Provider streaming for composed programs, including named-predictor field
  selection and a typed terminal prediction.
- A complete deployment example with disjoint evaluation, parameter artifacts,
  fresh-process loading, concurrent serving, hot reload, and failure
  containment.

### Changed

- `Imp.optimize/3`, `/4`, and `/5` now return `{:ok, program}` or
  `{:error, reason}`. The corresponding `optimize!` functions raise.
- Adapter types moved from `Imp.Adapters.Types` to `Imp.Adapter.Types`.
- Saved programs and parameter artifacts use atomic private writes and require
  live providers, callbacks, tools, and policies to be rebound from trusted
  application code.
- ReActV2 uses a validated `submit` tool, falls back to tools-disabled typed
  extraction when a provider cannot honor forced tool choice, and grounds that
  extraction only in successful retained observations.
- Evaluation timeouts, provider failures, metric failures, budget exhaustion,
  and cancelled work propagate as observable failures instead of silently
  becoming ordinary scores.
- The private release installs consistently from the immutable `v0.3.0` Git
  tag in the README, Livebooks, and packaged examples.

### Fixed

- Cached ReqLLM responses no longer double-count token usage.
- ReAct retains a single tool-call trajectory when context truncation cannot
  safely remove a complete turn.
- ReActV2 converts malformed provider tool calls into non-executable error
  observations so a model can recover without bypassing policy or
  authorization.
- Whole-program and optimizer-report identities survive artifact round trips.
- Composed streaming cancels provider work on early halt or consumer death.
- Batch messages retain their structured conversations after JSON transport.
- Optimizer progress subscribers receive real trial events.

### Removed

- `Imp.Agent` and `Imp.Agent.Runtime`. Use ReActV2 or RLM as the program and
  ordinary Elixir supervision as the runtime.
- `Imp.Streaming.Messages.StatusMessageProvider`, which did not implement an
  execution-stage status contract. Use stream listeners and `:telemetry`.

## 0.2.1 — 2026-07-18

### Added

- Configurable teacher and rollout timeouts for BootstrapFewShot, GRPO, and
  BootstrapFinetune.

### Fixed

- Saved Predict programs retain JSON retry and fallback configuration.
- GEPA reflection no longer sends an invalid provider connection option.
- Reasoning-model token-limit normalization is wire-neutral.
- Signature errors suggest `array[...]` when given DSPy's `list[...]` spelling.
- Global test configuration and async synchronization no longer leak across
  tests.

## 0.2.0 — 2026-07-17

### Added

- `Imp.stream/3` and `Imp.collect/3`, with provider streaming and local
  post-call chunking modes.
- Public optimizer progress subscriptions and evaluation timeout reporting.
- Deterministic LabeledFewShot selection and seeded data splitting.

### Fixed

- Batch requests preserve structured messages.
- Optimizer trial telemetry is emitted as documented.
- Timed-out evaluation rows are reported explicitly.

## 0.1.0 — 2026-07-16

Initial private Git source release of Imp's signature, program, provider,
evaluation, optimization, tool, retrieval, persistence, and Livebook APIs.

# Adapters

## Intent

An adapter turns a signature, its inputs and any demos into the messages
sent to the model, and turns the model's reply back into typed output fields.
It is the only part of Imp that knows what a prompt looks like on the wire.

Read this when you want to see the exact prompt, when a typed field parses in
a way you did not expect, or when you are choosing between the Chat, JSON and
single-field adapters.

## Design decisions

### 1. The adapter is a choice on the program, not on the signature

The same signature runs through any adapter. Models differ in what they read
and write reliably: most follow labelled sections well, a model with a native
JSON mode does best when asked for JSON, and a small local model does best
when asked for one bare value. Keeping that choice out of the signature means
you can change it, per program or per call, without touching the task.

Pass `adapter:` when you build a program. Without one, the program uses the
configured adapter, which is `Imp.Adapter.Chat` unless `Imp.configure/1` or
`Imp.context/2` says otherwise.

### 2. The prompt is built from the signature, every time

An adapter holds no state. Each call renders the signature's instructions,
its field names, types, descriptions and constraints, the program's demos,
and the call's inputs. Change the signature, or let an optimizer change the
instructions or demos, and the next prompt reflects it; there is no prompt
string to keep in sync.

### 3. Every answer is checked against the signature

Whatever shape the model replies in, the adapter extracts one value per
output field, converts it to the declared type, and validates it with the
same rules the signature declares (see [Signatures](signatures.md)). An
answer that is missing a field, or has a value that does not fit, is an
error, never a partial prediction.

### 4. A failed parse gets another chance, and says why

A model that ignores the format usually does so once. So a parse failure is
followed by one more request, not an error straight away:

- The Chat and XML adapters retry through the JSON adapter, which asks for a
  JSON object instead. This is on by default, as in DSPy; turn it off with
  `config: [json_fallback: false]`.
- The JSON and single-field adapters retry only when asked:
  `config: [json_retries: n]` makes up to `n` more requests. Each repeats the
  original request with the latest failure's message added as a user turn, so
  the model sees exactly what was wrong, and the retries stop at the first
  reply that parses.

A failure after that is returned to you. Imp does not loop on a model that
will not comply.

### 5. The Chat adapter speaks DSPy's format

`Imp.Adapter.Chat` lays out its messages the way DSPy's `ChatAdapter` does,
`[[ ## field ## ]]` markers included. Those markers rarely appear in real
text, so the reply splits cleanly into fields, and a prompt tuned in DSPy
reads nearly the same in Imp. One thing differs: Imp names each type in plain
words (`string`, `one of: atlas, harbor, ...`) where DSPy writes Python
annotations (`str`, `Literal[...]`).

## API walkthrough

### The adapters

**`Imp.Adapter.Chat`**, the default. Labelled sections in, labelled sections
out. Works with any chat model; needs no provider features.

**`Imp.Adapter.JSON`**. The same system message, but the reply is one JSON
object. When the provider supports it, Imp also sends a response format:
a JSON schema built from the signature where the provider accepts one, JSON
object mode otherwise. `config: [native_json_schema: true]` asks for the
schema explicitly. Use it when application code consumes the fields.

**`Imp.Adapter.SingleField`**. For a signature with exactly one output. The
model is asked for the bare value and nothing else, and the reply must be
exactly a valid value: `"atlas"` passes, `"The answer is atlas"` and
`"[atlas]"` do not. A signature with more than one output is refused before
any request. It suits small local models doing classification.

**`Imp.Adapter.XML`** asks for each output inside its own tag, as DSPy's
`XMLAdapter` does. **`Imp.Adapter.TwoStep`** lets one model answer in free
text and a second, configured with `two_step_extraction_lm:`, extract the
fields; it suits reasoning models that write well but format poorly.

Take the router from [Signatures](signatures.md):

```elixir
signature =
  Imp.signature(
    ~s(ticket -> team: enum[atlas,harbor,beacon,quill] "atlas: money. harbor: the platform. beacon: identity. quill: the product."),
    "Route the support ticket to the squad that owns it."
  )
```

All three of the first adapters get the same answer from `gpt-5.4-mini`; what
differs is what the model writes:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

for adapter <- [Imp.Adapter.Chat, Imp.Adapter.JSON, Imp.Adapter.SingleField] do
  {:ok, prediction} =
    Imp.call(Imp.predict(signature, lm: lm, adapter: adapter), %{ticket: "We were charged twice this month."})

  {Imp.get(prediction, :team), prediction.metadata.trace.raw}
end
#=> [
#=>   {"atlas", "[[ ## team ## ]]\natlas\n[[ ## completed ## ]]"},
#=>   {"atlas", "{\"team\":\"atlas\"}"},
#=>   {"atlas", "atlas"}
#=> ]
```

### What the prompt looks like

Every successful prediction keeps the messages that produced it, redacted of
secrets, in `prediction.metadata.trace.messages`, and the model's raw reply in
`prediction.metadata.trace.raw`. Here is the router's prompt through the Chat
adapter, with a scripted model so it runs anywhere:

```elixir
lm = Imp.LM.Static.new(handler: fn _messages, _opts -> "[[ ## team ## ]]\natlas\n\n[[ ## completed ## ]]" end)

router = Imp.predict(signature, lm: lm)
{:ok, prediction} = Imp.call(router, %{ticket: "We were charged twice this month."})

Enum.map(prediction.metadata.trace.messages, & &1.role)
#=> [:system, :user]
```

The system message says four things: which fields are inputs and which are
outputs, each with its type and description; the layout every exchange
follows, one `[[ ## field ## ]]` section per field; the constraint on each
output, here that `team` must be exactly one of the four squads; and last,
the instructions. The user message holds the inputs in the same layout and
asks for the outputs in order, each with its expected type, ending with the
`completed` marker:

```text
--- system
Your input fields are:
1. `ticket` (string):
Your output fields are:
1. `team` (one of: atlas, harbor, beacon, quill): atlas: money. harbor: the platform. beacon: identity. quill: the product.
All interactions will be structured in the following way, with the appropriate values filled in.

[[ ## ticket ## ]]
{ticket}

[[ ## team ## ]]
{team}        # note: the value you produce must exactly match (no extra characters) one of: atlas; harbor; beacon; quill

[[ ## completed ## ]]
In adhering to this structure, your objective is: 
        Route the support ticket to the squad that owns it.
--- user
[[ ## ticket ## ]]
We were charged twice this month.

Respond with the corresponding output fields, starting with the field `[[ ## team ## ]]` (must be formatted as one of: atlas, harbor, beacon, quill), and then ending with the marker for `[[ ## completed ## ]]`.
```

Demos become worked exchanges between the system message and the request:
one user message with the demo's inputs and one assistant message with its
outputs, in the same layout.

```elixir
demo = Imp.example(ticket: "Please send last month's receipt.", team: "atlas") |> Imp.with_inputs(:ticket)
{:ok, prediction} = Imp.call(Imp.with_demos(router, [demo]), %{ticket: "We were charged twice this month."})

Enum.map(prediction.metadata.trace.messages, & &1.role)
#=> [:system, :user, :assistant, :user]
```

The JSON adapter's system message is the same list of fields and
constraints, with the outputs laid out as a JSON object; its request asks for
a JSON object with the fields in order. The single-field adapter's is shorter:
the objective, the inputs, the one output with its type, and an instruction
to return only the value.

### When the answer does not fit

A reply that cannot be read as the signature's outputs, after any retry,
comes back as `{:error, %Imp.AdapterParseError{}}`. Its `kind` says what went
wrong, `message` is the text a retry would show the model, and `trace` holds
the messages and the raw reply:

| `kind` | Meaning | `reason` |
| --- | --- | --- |
| `:malformed` | not in the adapter's format at all: no JSON object, XML that does not parse, a single-field reply that is not exactly a value | the raw reply |
| `:missing_fields` | required outputs are absent | their names |
| `:invalid_fields` | every field is present, but a value does not fit its type or constraints | the fields that were read |
| `:unsupported_output` | the model returned something that is not a completion | what it returned |
| `:other` | a custom adapter returned an error of its own | that error |

```elixir
lm = Imp.LM.Static.new(handler: fn _messages, _opts -> ~s({"team": "billing"}) end)

{:error, error} =
  Imp.call(Imp.predict(signature, lm: lm, adapter: Imp.Adapter.JSON), %{ticket: "We were charged twice this month."})

error.kind
#=> :invalid_fields
```

With `json_retries: 1`, that same reply is followed by one more request whose
last message is the error's `message`:

```text
Validation failed. Retry with corrected output:
- team: must be one of ["atlas", "harbor", "beacon", "quill"]
```

A parse error is not a provider error. `Imp.Errors.retryable?/1` is false for
it: sending the identical request again is not what fixes it. A request the
provider itself failed is an `Imp.LMError`, and an adapter that makes its own
request (TwoStep) returns that request's failure as it is.

Each fallback, retry and final parse failure also emits telemetry:
`[:imp, :adapter, :parse, :json_fallback | :retry | :error]`.

### Choosing an adapter for a call

- On the program: `Imp.predict(signature, adapter: Imp.Adapter.JSON)`.
- For every program that does not name one: `Imp.configure(adapter: ...)`.
- For everything inside a function: `Imp.context([adapter: ...], fn -> ... end)`.
  A program built with an explicit `adapter:` keeps its own.

## Cross-links

- [Signatures](signatures.md): what the adapter renders and checks.
- [ReAct](react.md): how the tool loop uses the Chat adapter's history and
  native tool calls.
- `Imp.Adapter.Chat`, `Imp.Adapter.JSON`, `Imp.Adapter.SingleField`,
  `Imp.AdapterParseError`: the reference.

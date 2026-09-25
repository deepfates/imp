# Signatures

## Intent

A signature is the contract between your program and the model: the fields a
step takes, the fields it must return, their types, and the instructions for
the task. Imp writes the prompt from it, checks the answer against it, and
hands optimizers the parts of it they are allowed to change.

Read this when the one-line form stops being enough: you want descriptions,
defaults, optional fields or numeric bounds, you want to know exactly what is
validated and when, or you want to know what an optimizer may rewrite.

## Design decisions

### 1. A signature is data

`Imp.signature/2` returns an `%Imp.Signature{}` struct: a list of input
fields, a list of output fields, instructions, and metadata. The string form
and the map form build the same struct. There is no class to subclass and no
compile step, so a signature can be built at runtime, compared, stored in a
database, and written to JSON with `Imp.Signature.dump/1`. A saved program
carries its signatures as plain data for the same reason.

Changing a signature means making a new one. Programs are immutable values,
and so are the signatures inside them: an optimizer that tries twenty
instructions holds twenty programs, none of which can disturb another.

### 2. Types are spelled once, for both the prompt and the check

Imp's types are the ones JSON Schema can express: `string`, `integer`,
`float`, `number`, `boolean`, `datetime`, `object`, `array[...]` and
`enum[...]`. The same declaration renders the type hint in the prompt,
builds the JSON schema sent to providers that support structured output, and
validates the value that comes back. One declaration means the prompt, the
provider request and the check cannot disagree.

Python spellings that mean the same thing are accepted (`str`, `int`,
`bool`, `dict`). Where Imp spells something differently, the parser says so:

~~~elixir
Imp.signature("ticket -> tags: list[str]")
~~~

```text
** (Imp.Signature.ParseError) invalid signature at position 15: unknown field type "list[str]"
ticket -> tags: list[str]
               ^
did you mean "array[str]"? (Imp uses array[...] where DSPy uses list[...])
```

Unknown types and a name used on both sides of the arrow fail when the
signature is built, not when the first request goes out.

### 3. Outputs are checked strictly, inputs leniently

The model's answer is the untrusted side. Every output is parsed into its
declared type and validated against its constraints; an answer that does not
fit is an error, never a partial prediction. What happens next (a fallback, a
retry) is the adapter's business; see [Adapters](adapters.md).

Inputs come from your own code. A required input that is missing fails
before any request is made, with `{:error, {:missing_input_fields, names}}`.
An input whose value does not match its declared type logs a warning and the
call goes ahead, as DSPy does. An input key the signature does not declare
logs a warning and is ignored. Validate untrusted input at your own boundary
when you need it rejected.

### 4. Instructions belong to the signature

The second argument to `Imp.signature/2` is the task description. Without
one, Imp writes ``Given the fields `ticket`, produce the fields `team`.``
The module decides how the call is made (one request, reasoning first, a tool
loop); the signature decides what the task is. The same signature can go to
`Imp.predict/2`, `Imp.chain_of_thought/2` or `Imp.react/3` unchanged, which
makes it cheap to compare them.

### 5. Field names and descriptions are yours; instructions and examples are the optimizer's

Instruction optimizers rewrite the instructions. Few-shot optimizers choose
demos. None of them renames a field, changes a type or rewrites a field
description. Your code reads `Imp.get(prediction, :team)`, and an optimizer
that renamed `team` would break it; a type is a promise to that code. So the
description is where you put what only you know, such as what your squad
names mean, and it stays put.

### 6. Read fields by name

A field name written as an atom stays an atom. A name that arrives as text,
from the string form or from JSON, becomes an atom only if that atom already
exists in the VM, so Imp never creates atoms from data. Read values with
`Imp.get/2`, which matches a field by its name either way.

## API walkthrough

### The string form

```elixir
signature =
  Imp.signature(
    ~s(ticket -> team: enum[atlas,harbor,beacon,quill] "atlas: money. harbor: the platform. beacon: identity. quill: the product."),
    "Route the support ticket to the squad that owns it."
  )

Imp.Signature.to_spec(signature)
#=> "ticket -> team"
```

A field is `name`, `name: type`, or `name: type "description"`. Fields are
separated by commas; a signature has exactly one `->`. An untyped field is a
string.

| Type | Value |
| --- | --- |
| `string` (`str`) | text |
| `integer` (`int`), `float`, `number` | numbers; `float` accepts integers |
| `boolean` (`bool`) | `true` or `false` |
| `datetime` | a `DateTime` or `NaiveDateTime` |
| `object` (`map`, `dict`) | a map |
| `array`, `array[type]` | a list, optionally typed; nests (`array[array[integer]]`) |
| `enum[a,b,c]` (`class[a,b,c]`) | one of the listed strings |
| `yes_no` | text that is exactly yes or no |
| `short_span` | a short answer: at most 12 words, one line |
| `numeric_span` | only a number, optionally with `$`, `,` or `%` |

The last three are answer shapes for extractive question answering: the value
is text, and its shape is checked.

The description is part of the prompt. On the tutorial's 20 test tickets, the
router above without the description scored 0.25 in three runs with
`gpt-5.4-mini`, and 0.70 with it, because the squad names mean nothing to the
model until something says what they own:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

data = :imp |> Application.app_dir("priv/tutorial/support_tickets.json") |> File.read!() |> Jason.decode!()

test =
  for %{"ticket" => t, "team" => team} <- data["test"],
      do: Imp.example(ticket: t, team: team) |> Imp.with_inputs(:ticket)

router = Imp.predict(signature, lm: lm, adapter: Imp.Adapter.JSON)

Imp.evaluate(router, test, Imp.exact_match(:team)).score
#=> 0.7
```

### The structured form

Use a map when a field needs a default, needs to be optional, or carries
constraints the string form cannot say:

```elixir
triage =
  Imp.signature(
    %{
      inputs: [:ticket, %{name: :plan, type: :string, default: "free"}],
      outputs: [
        %{name: :team, type: :string, constraints: %{enum: ~w[atlas harbor beacon quill]}},
        %{name: :priority, type: :integer, constraints: %{min: 1, max: 4}},
        %{name: :reply, type: :string, desc: "One sentence to the customer."},
        %{name: :duplicate_of, type: :string, optional: true}
      ]
    },
    "Triage the support ticket."
  )

Imp.Signature.json_schema(triage)["properties"]["priority"]
#=> %{"maximum" => 4, "minimum" => 1, "type" => "integer"}
```

A field in the `inputs` or `outputs` list is an atom, a `"name: type"`
string, or a map. A map takes `name` (required), `type`, `desc`, `default`,
`optional`, `constraints`, and `metadata`. `Imp.Signature.Field` documents
each key.

- `default` fills an absent value, on either side. An input with a default
  can be left out of the call.
- `optional: true` lets the value be absent; it reads as `nil`.
- A present value is never replaced, even when it is `false`, `0`, `""` or
  `[]`.

Constraint keys:

| Key | Applies to |
| --- | --- |
| `enum` | any value: one of the list |
| `min`, `max` (inclusive), `gt`, `lt`, `multiple_of` | numbers |
| `min_length`, `max_length`, `pattern` | strings |
| `items` | the element type of an array, as a field map |
| `properties` | the fields of an object |
| `any_of` | a union: a list of field maps, one of which must match |
| `answer_shape` | `:yes_no`, `:short_span` or `:numeric_span` |

### How a value is checked

An output passes when it has its declared type and meets every constraint.
The checks are the ones in the tables above: an integer field takes only an
integer, an enum takes only a listed value, an array's items are checked one
by one, and an object's declared properties are checked recursively. A
failing answer produces a readable message, and that message is what an
adapter shows the model when it asks again:

```elixir
field = Enum.find(triage.outputs, &(to_string(&1.name) == "priority"))

Imp.Schema.validate_field(field, 9)
#=> [%{field: :priority, rule: :max, message: "must be <= 4"}]
```

### Changing a signature

Every change returns a new signature.

- `%{signature | instructions: "..."}` replaces the instructions.
- `Imp.Signature.extend(signature, fields, :input | :output)` appends fields.
- `Imp.Signature.prepend_output(signature, field)` puts a field first among
  the outputs. `Imp.chain_of_thought/2` uses it to add `reasoning` ahead of
  your outputs.
- `Imp.Signature.dump/1` and `Imp.Signature.load/1` round-trip a signature
  through JSON-friendly data.
- `Imp.Signature.input_names/1`, `output_names/1` and `to_spec/1` read it.

### What an optimizer can change

`Imp.ProgramParameters` lists what optimizers see in a program. For a single
predictor that is its instructions, its demos, and its request config:

```elixir
router = Imp.predict(signature)

Imp.ProgramParameters.snapshot(router).parameters |> Enum.map(& &1.id)
#=> ["predictor/main/config", "predictor/main/demos", "predictor/main/instruction"]
```

Field names, types, constraints and descriptions are not on that list. For a
program with several steps, each named predictor gets its own three; see
[Modules and composition](modules-and-composition.md).

## Cross-links

- [Adapters](adapters.md): how a signature becomes messages, and what
  happens when an answer does not fit it.
- [Modules and composition](modules-and-composition.md): the modules that
  take a signature, and how their predictors are named for optimizers.
- [ReAct](react.md): how a signature's outputs become the `submit` tool.
- `Imp.Signature`, `Imp.Signature.Field`: the reference.

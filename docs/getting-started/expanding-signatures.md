# Expanding signatures

## More fields

A signature can take and return as many fields as a task needs, separated by
commas. Let's have the router also say how urgent a ticket is:

```elixir
signature =
  Imp.signature(
    ~s(ticket -> team: enum[atlas,harbor,beacon,quill], urgency: enum[normal,high] "high when customers cannot work or data is at risk"),
    "Route the support ticket to the squad that owns it."
  )

urgent_router = Imp.predict(signature, lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} =
  Imp.call(urgent_router, %{ticket: "One of our users is seeing another customer's data."})

{Imp.get(prediction, :team), Imp.get(prediction, :urgency)}
#=> {"beacon", "high"}
```

The text in quotes after a field's type is its **description**. It is for the
things a name can't carry. Imp puts it beside the field in the prompt:

```text
Your output fields are:
1. `team` (one of: atlas, harbor, beacon, quill): 
2. `urgency` (one of: normal, high): high when customers cannot work or data is at risk
```

Keep descriptions short. The instruction says what the task is, names and
descriptions say what each field means, and examples teach the rest. Long lists
of rules are what optimizers are for, and we'll get there.

## Types

A field is `name`, `name: type`, or `name: type "description"`. A field with no
type is a string. The types are:

| Type | Also spelled | Value |
| --- | --- | --- |
| `string` | `str` | text |
| `integer` | `int` | a whole number |
| `float`, `number` | | a number |
| `boolean` | `bool` | `true` or `false` |
| `datetime` | | a `DateTime`, written as ISO 8601 text |
| `object` | `map`, `dict` | a JSON object |
| `array`, `array[type]` | | a list, optionally of one type; types nest |
| `enum[a,b]` | `class[a,b]` | one of the listed strings |
| `yes_no` | | `"yes"` or `"no"` |
| `short_span` | | a short answer: one line, at most twelve words |
| `numeric_span` | | a number alone, such as `42`, `$1,200`, or `15%` |

Outputs are parsed and checked strictly: a reply that doesn't fit the type is
an error, never a guess. Inputs are checked for presence before any request is
made, so a missing field costs nothing. An unknown type, or a name used twice
(on either side or on both), fails when the signature is built, not when it
runs.

## The structured form

The string form covers most fields. When a field needs a default, a nullable
value, or a constraint the string can't say, we can write the signature as
data. This is the same signature, with an optional note added:

```elixir
structured =
  Imp.signature(
    %{
      inputs: [%{name: :ticket, type: :string}],
      outputs: [
        %{name: :team, type: :string, constraints: %{enum: ~w[atlas harbor beacon quill]}},
        %{
          name: :urgency,
          type: :string,
          desc: "high when customers cannot work or data is at risk",
          constraints: %{enum: ~w[normal high]}
        },
        %{name: :note, type: :string, optional: true}
      ]
    },
    "Route the support ticket to the squad that owns it."
  )

Imp.Signature.output_names(structured)
#=> [:team, :urgency, :note]
```

Fields are required unless we say otherwise. `default:` fills a value that is
absent; `optional: true` lets the model leave it out, and it becomes `nil`.
Values that are present but falsy, like `false`, `0`, or `""`, are kept as
they are. `Imp.Signature.Field` lists every key a field accepts.

A signature is plain data either way, so it can be built at runtime from
configuration, stored, and compared.
[Signatures](../diving-deeper/signatures.md) in Diving deeper covers the rest.

---

**Next:** [Changing the module →](changing-the-module.md)

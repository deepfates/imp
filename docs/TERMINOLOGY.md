# DSEx Terminology

DSEx should read like an Elixir system, not a Python glossary with new
spelling. These are the canonical names used in guides, Livebooks, tests, and
public examples.

## Canonical Terms

| Term | Meaning |
| --- | --- |
| DSEx | The project name and public API for declarative self-improving programs in Elixir. |
| Program | A callable struct that turns declared inputs into predictions. |
| Signature | The input/output contract for a program. |
| Example | A row of training, development, or test data with explicit input fields. |
| Prediction | Structured model output plus trace, score, and metadata. |
| Adapter | The boundary that turns a signature and inputs into LM messages, then parses raw output. |
| LM | A configured language-model client implementing the `DSEx.LM` behaviour. |
| Metric | A function that scores predictions against examples. |
| Optimizer | A metric-driven compiler that improves instructions, demos, programs, or artifacts. |
| Agent | A runtime composition of tools, policy, memory/context, traces, and callable behavior. |
| RLM | A recursive controller loop for exploring context through safe actions and tool calls. |

## Namespace Policy

Use `DSEx` in beginner docs, application snippets, and operator-facing code:

```elixir
program = DSEx.predict("question -> answer")
{:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
DSEx.get(prediction, :answer)
```

Use `DSEx.*` when naming implementation modules, behaviours, and advanced
surfaces. There is no parallel legacy namespace.

## Terms To Avoid In Teaching Material

| Avoid | Prefer |
| --- | --- |
| Elixir port | DSEx, or Elixir-native system |
| legacy optimizer jargon | optimizer, or metric-driven optimizer |
| Python clone | Elixir-native implementation, or ancestry-inspired implementation |
| prompt engineering | declarative program construction |

Audit and ecosystem documents may mention other projects only when comparing
ideas, coverage, or evidence.

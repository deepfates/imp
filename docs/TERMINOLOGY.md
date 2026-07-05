# DSPEx Terminology

DSPEx should read like an Elixir system, not a Python glossary with new
spelling. These are the canonical names used in guides, Livebooks, tests, and
public examples.

## Canonical Terms

| Term | Meaning |
| --- | --- |
| DSPEx | Declarative Self-improving Programs for Elixir. The user-facing facade and project name. |
| Program | A callable struct that turns declared inputs into predictions. |
| Signature | The input/output contract for a program. |
| Example | A row of training, development, or test data with explicit input fields. |
| Prediction | Structured model output plus trace, score, and metadata. |
| Adapter | The boundary that turns a signature and inputs into LM messages, then parses raw output. |
| LM | A configured language-model client implementing the `DSPy.LM` behaviour. |
| Metric | A function that scores predictions against examples. |
| Optimizer | A metric-driven compiler that improves instructions, demos, programs, or artifacts. |
| Agent | A runtime composition of tools, policy, memory/context, traces, and callable behavior. |
| RLM | A recursive controller loop for exploring context through safe actions and tool calls. |

## Namespace Policy

Use `DSPEx` in beginner docs, application snippets, and operator-facing code:

```elixir
program = DSPEx.predict("question -> answer")
{:ok, prediction} = DSPEx.call(program, %{question: "Capital of France?"})
DSPEx.get(prediction, :answer)
```

Use `DSPy.*` when naming implementation modules, behaviours, and compatibility
surfaces. The namespace remains public because the project tracks DSPy ancestry
and public-export parity, but it is not the first concept a new Elixir user
needs to learn.

## Terms To Avoid In Teaching Material

| Avoid | Prefer |
| --- | --- |
| Elixir port | DSPEx, or Elixir-native system |
| teleprompter | optimizer, or metric-driven optimizer |
| Python clone | DSPy-compatible ancestry, parity bridge, or implementation equivalent |
| prompt engineering | declarative program construction |

Parity and audit documents may still mention DSPy or Python when discussing
source-backed compatibility evidence.

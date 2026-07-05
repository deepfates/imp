# DSPy Philosophy In Elixir

DSPy starts from a simple shift: treat language-model behavior as software, not
as loose prompt text. The upstream docs describe DSPy as a framework for
building AI systems by expressing tasks as structured signatures and composing
modules that can be evaluated and optimized.

This port keeps that idea but translates the mechanics into Elixir:

- Signatures are data: `%DSPy.Signature{}` declares inputs, outputs,
  instructions, and constraints.
- Programs are structs: `DSPy.Predict.Predict`, `ChainOfThought`, `ReActV2`,
  `RLM`, and related modules hold configuration, demos, adapters, and LMs.
- Boundaries are behaviours: `DSPy.LM`, `DSPy.Adapter`, `DSPy.Retrieve`, and
  `DSPy.HTTP` are explicit seams for tests and production clients.
- Optimization is metric-driven: teleprompters and V2 optimizers compile better
  programs from examples, dev sets, and scores.
- The BEAM shapes the design: immutable structs, supervised cache state,
  injectable transports, safe sandboxing, and deterministic tests replace
  Python-specific runtime patterns.

## What "Philosophical Translation" Means

This is not a line-by-line Python clone. It is an Elixir-native implementation
of the same programming model.

In Python DSPy, a signature such as `"question -> answer"` becomes a module that
formats prompts, calls an LM, parses outputs, and can be optimized. In this
repo, the same idea is represented as:

```elixir
program = DSPy.predict("question -> answer", lm: lm)
{:ok, pred} = DSPy.Predict.Predict.call(program, %{question: "Capital of France?"})
DSPy.Prediction.get(pred, :answer)
```

The important thing is not that the prompt string matches Python DSPy. The
important thing is that the task is specified declaratively, the implementation
is swappable, and the result can be evaluated, saved, streamed, optimized, and
tested.

## Core Concepts

### Signature

A signature names the task boundary. Inputs and outputs are contract fields,
not prose convention.

```elixir
signature =
  DSPy.Signature.new(%{
    inputs: [:text],
    outputs: [
      %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
      %{name: :confidence, type: :number, constraints: %{min: 0.0, max: 1.0}}
    ]
  })
```

### Module

A module is a callable program shape. The simplest one is `Predict`; others add
reasoning, tools, code execution, comparison, refinement, parallelism, or
recursive exploration.

### Adapter

An adapter translates signatures and examples into LM messages, and translates
raw model output back into `DSPy.Prediction`.

### Example

An example is a row of data plus optional input-key metadata. Optimizers use
examples as train/dev material.

### Metric

A metric turns `(example, prediction)` into a score. The score is the language
that optimizers understand.

### Optimizer

Optimizers compile a better program by searching instructions, demos, candidate
programs, or arbitrary text artifacts.

## Upstream Concept Map

| Upstream DSPy idea | Elixir shape |
| --- | --- |
| `dspy.Signature` | `DSPy.Signature`, `DSPy.Signature.Field` |
| `dspy.Predict` | `DSPy.Predict.Predict` |
| `dspy.ChainOfThought` | `DSPy.Predict.ChainOfThought` |
| `dspy.ReAct` | `DSPy.Predict.ReAct`, `DSPy.Predict.ReActV2` |
| `dspy.RLM` | `DSPy.Predict.RLM` |
| `dspy.Example` | `DSPy.Example` |
| `dspy.Prediction` | `DSPy.Prediction` |
| `dspy.Evaluate` | `DSPy.Evaluate` |
| teleprompters/optimizers | `DSPy.Teleprompt.*`, `DSPy.Optimize.*` |
| `dspy.LM` | `DSPy.LM` behaviour, `DSPy.Clients.*` |
| adapters | `DSPy.Adapter.*` |
| tools/MCP | `DSPy.Tool`, `DSPy.Agent`, `DSPy.MCP` |

## Production Principle

The codebase should be judged by gates, not vibes:

```sh
mix production.check
mix v2.check
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

The first two are deterministic. The live gate is opt-in because provider
credentials and account state are operational concerns.


# DSPy Elixir

An Elixir-native translation of [DSPy](https://dspy.ai/): signatures, LM programs,
examples, evaluation, retrieval, and teleprompter-style optimizers for the BEAM.

This is intentionally not a line-by-line Python port. It preserves DSPy's central
idea, that language-model behavior should be programmed and optimized through
declarative signatures and metrics, while using Elixir structs, behaviours, OTP
configuration, and deterministic tests.

## Quick Example

```elixir
DSPy.configure(lm: %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]})

program = DSPy.predict("question -> answer")
{:ok, prediction} = DSPy.Predict.Predict.call(program, %{question: "Capital of France?"})

DSPy.Prediction.get(prediction, :answer)
#=> "Paris"
```

## What Exists

See [TELOS.md](TELOS.md) for the completion checklist, implemented surface, and
test signals. The repo includes provider clients, adapters, programs,
retrievers, datasets, streaming, persistence, sandboxed program-of-thought,
evaluation, and teleprompter-style optimizers.

See [V2.md](V2.md) for the experimental V2 surface: optimize-anything,
GEPA-inspired Pareto mechanics, agents, MCP-style tool import, schema
constraints, and deterministic smoke fixtures.

## Test

```sh
mix test
```

## Production Gate

```sh
mix production.check
mix v2.check
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

The production gate verifies formatting, warnings-as-errors compilation,
generated upstream public-export parity, and the full deterministic integration
suite. The live gate validates real OpenAI-compatible provider execution using
local `.env` credentials.

# DSEx

DSEx is a declarative self-improving programming system for language models on the BEAM: signatures, programs, examples, evaluation, retrieval, optimization, agents, and production gates.

It stands in the DSP tradition, but it is taught and shaped as if the idea had started in Elixir: structs, behaviours, OTP boundaries, explicit calls, immutable data, supervised state, and deterministic gates.

## Quick Example

```elixir
DSEx.configure(lm: %{module: DSEx.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]})

program = DSEx.predict("question -> answer")
{:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})

DSEx.get(prediction, :answer)
#=> "Paris"
```

## What Exists

Start with [docs/README.md](docs/README.md) for the full guide set and
interactive Livebooks. The docs are organized as a learning path:
philosophy, architecture, API guide, production operations, and runnable
notebooks.

See [TELOS.md](TELOS.md) for the completion checklist, implemented surface, and
test signals. The repo includes provider clients, adapters, programs,
retrievers, datasets, streaming, persistence, sandboxed program-of-thought,
evaluation, and metric-driven optimizers.

See [V2.md](V2.md) for the V2 surface: optimize-anything,
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
the DSEx public surface, audit checks, and the full deterministic
integration suite. The live gate validates real OpenAI-compatible provider
execution using local `.env` credentials.

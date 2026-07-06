# DSEx

DSEx is a declarative self-improving programming system for language models on the BEAM: signatures, programs, examples, evaluation, retrieval, optimization, agents, and production gates.

It brings declarative language-model programming to Elixir through structs,
behaviours, OTP boundaries, explicit calls, immutable data, supervised state,
and deterministic gates.

## Quick Example

```elixir
DSEx.configure(lm: %{module: DSEx.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]})

program = DSEx.predict("question -> answer")
{:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})

DSEx.get(prediction, :answer)
#=> "Paris"
```

## Docs

Start with [docs/README.md](docs/README.md) for the manual and Livebooks.
The library includes provider clients, adapters, programs, retrievers,
datasets, streaming, persistence, sandboxed program-of-thought, evaluation,
agents, MCP-style tool import, schema constraints, optimize-anything flows,
GEPA-inspired Pareto mechanics, and metric-driven optimizers.

See [Prior Art](docs/PRIOR_ART.md) for lineage and independence from DSPy,
Ax, and GEPA/optimize_anything.

## Test

```sh
mix test
```

## Production Gate

```sh
mix production.check
mix v2.check
LIVE_PROVIDER=1 mix live.check
```

See [Production Operations](docs/PRODUCTION_OPERATIONS.md) for the current gate
contract. The live gate validates prediction, structured JSON, chain-of-thought,
streaming, ReActV2 tool calls, orchestration wrappers, and program-of-thought
sandbox execution against a real OpenAI-compatible provider using local `.env`
credentials.

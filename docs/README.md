# DSEx Manual

DSEx turns language-model work into declared, callable, measurable, improvable
Elixir programs. This manual is organized by what you are trying to do.

## Learn The Model

- [Learning Path](LEARNING_PATH.md): what to read and run in 30 minutes,
  two hours, an afternoon, and a production app.
- [Philosophy](DSEX_PHILOSOPHY.md): the mental model: signatures, programs,
  adapters, examples, metrics, and optimizers.
- [Glossary](GLOSSARY.md): short definitions for DSEx vocabulary.
- [Architecture](ARCHITECTURE.md): how the pieces fit together inside the
  library.
- [Prior Art](PRIOR_ART.md): lineage from DSPy, Ax, GEPA, and
  optimize-anything style systems.

## Build With DSEx

- [API Guide](API_GUIDE.md): task-oriented examples for normal application
  code.
- [Advanced DSEx](ADVANCED.md): artifact optimization, GEPA-style reflection,
  agents, MCP, schemas, and deterministic fixtures.

## Learn By Running Code

The notebooks in `livebooks/` are written to run with deterministic local LMs by
default. The live-provider notebook has an explicit opt-in cell for `.env`
credentials.

- [01 Programming, Not Prompting](../livebooks/01_programming_not_prompting.livemd)
- [02 Evaluate And Optimize](../livebooks/02_evaluate_and_optimize.livemd)
- [03 Agents, Tools, MCP, Recursive Control](../livebooks/03_agents_tools_mcp_rlm.livemd)
- [04 Local Gates And Live Provider Smoke](../livebooks/04_local_gates_and_live_provider_smoke.livemd)

## Operate It

- [Production Operations](PRODUCTION_OPERATIONS.md): gates, live credentials,
  redaction, security posture, package shape, and release discipline.

## First Things To Try

1. Follow the [30-minute path](LEARNING_PATH.md).
2. Run the first example in [API Guide](API_GUIDE.md).
3. Open [Livebook 01](../livebooks/01_programming_not_prompting.livemd).
4. Add one metric and one tiny dev set.
5. Run `mix production.check` before trusting a change.
6. Run `mix livebook.execute.check` after changing public examples or notebooks.

## Maintainer Evidence

The repository also keeps release-evidence notes for maintainers and reviewers.
They audit DSEx-vs-DSPy parity and performance claims, but they are intentionally
separate from the packaged user manual.

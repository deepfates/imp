# DSEx Manual

DSEx turns language-model work into declared, callable, measurable, improvable
Elixir programs. This manual is organized by what you are trying to do.

## Learn The Model

- [Philosophy](DSEX_PHILOSOPHY.md): the mental model: signatures, programs,
  adapters, examples, metrics, and optimizers.
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
- [03 Agents, Tools, MCP, RLM](../livebooks/03_agents_tools_mcp_rlm.livemd)
- [04 Production And Live Provider](../livebooks/04_production_and_live_provider.livemd)

## Operate It

- [Production Operations](PRODUCTION_OPERATIONS.md): gates, live credentials,
  redaction, security posture, and release discipline.
- [Benchmark Truth](BENCHMARK_TRUTH.md): real-dataset benchmark artifacts,
  manifests, integrity checks, and live-provider evidence.

## Validate Claims

These documents are mostly for maintainers, reviewers, and release decisions.
They are useful when you want to audit DSEx claims, but they are not required
for normal application use.

- [Parity Validation Program](PARITY_VALIDATION_PROGRAM.md): the evidence
  standard for DSEx-vs-DSPy semantic parity, optimizer lift, production
  behavior, and provider-free performance claims.
- [Coverage Matrix](COVERAGE_MATRIX.md): upstream concept coverage mapped to
  DSEx surfaces, tests, docs, and production decisions.
- [Release Criteria](RELEASE_CRITERIA.md): release gates and external
  references used to define readiness.

## First Things To Try

1. Read the first half of [Philosophy](DSEX_PHILOSOPHY.md).
2. Run the first example in [API Guide](API_GUIDE.md).
3. Open [Livebook 01](../livebooks/01_programming_not_prompting.livemd).
4. Add one metric and one tiny dev set.
5. Run `mix production.check` before trusting a change.

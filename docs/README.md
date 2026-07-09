# DSEx Manual

DSEx turns language-model work into declared, callable, measurable, improvable
Elixir programs. This manual is organized by what you are trying to do.

## Manual Spine

Every guide and notebook follows the same product story:

1. **Declare** the task as a typed signature.
2. **Run** it as a DSEx program through `DSEx.call/2`.
3. **Develop** it deterministically with `DSEx.LM.Static`.
4. **Measure** behavior with examples, metrics, and evaluation reports.
5. **Improve** the program with optimizers.
6. **Extend** it with tools, retrieval, agents, or RLM only when needed.
7. **Operate** it with ReqLLM, explicit credentials, redaction, telemetry, and
   release gates.

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

The notebooks in `livebooks/` start with the real-provider shape, then show how
to develop the same programs deterministically. Every notebook includes at
least one live-provider proof cell for the surface it teaches. Those cells skip
cleanly unless `OPENAI_API_KEY` and `OPENAI_MODEL` are present, so the notebooks
remain safe in local gates while still becoming real end-to-end demos when
credentials are loaded.

- [01 Real LM Front Door](../livebooks/01_real_lm_front_door.livemd)
- [02 Programming, Not Prompting](../livebooks/02_programming_not_prompting.livemd)
- [03 Evaluate And Optimize](../livebooks/03_evaluate_and_optimize.livemd)
- [04 Tools, Agents, MCP, Recursive Control](../livebooks/04_tools_agents_mcp_rlm.livemd)
- [05 Operate And Live Checks](../livebooks/05_operate_and_live_checks.livemd)

## Operate It

- [Production Operations](PRODUCTION_OPERATIONS.md): gates, live credentials,
  redaction, security posture, package shape, and release discipline.

## First Things To Try

1. Follow the [30-minute path](LEARNING_PATH.md).
2. Open [Livebook 01](../livebooks/01_real_lm_front_door.livemd) for the live
   provider shape.
3. Open [Livebook 02](../livebooks/02_programming_not_prompting.livemd) for the
   deterministic local version of that shape.
4. Add one metric and one tiny dev set with
   [Livebook 03](../livebooks/03_evaluate_and_optimize.livemd).
5. From the source checkout, run `mix production.check` before trusting a change.
6. From the source checkout, run `mix livebook.execute.check` after changing public examples or notebooks.

Package consumers do not need the source-checkout Mix aliases; those gates are
for DSEx maintainers validating this repository before release.

## Maintainer Evidence

The repository also keeps release-evidence notes for maintainers and reviewers.
They audit DSEx-vs-DSPy parity and performance claims, but they are intentionally
separate from the packaged user manual. In the source checkout, the benchmark
catalog is the maintainer starting point for outside-view validation work.

- [Upstream Fidelity Audit](UPSTREAM_FIDELITY_AUDIT.md): current gap map
  against DSPy, DeepWiki, GEPA, optimize_anything, and the associated papers.
- [Upstream Surface Map](UPSTREAM_SURFACE_MAP.md): generated maintainer map of
  tracked upstream surfaces and their current DSEx mapping.

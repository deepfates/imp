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
- [Research Landscape](RESEARCH_LANDSCAPE.md): the paper lineage, neighboring
  repositories, implementation comparators, and architecture implications.

## Build With DSEx

- [API Guide](API_GUIDE.md): task-oriented examples for normal application
  code.
- [Tutorial And Example Parity](TUTORIAL_EXAMPLE_PARITY.md): where each
  tutorial and real-world example family belongs in the executable DSEx path.
- [Advanced DSEx](ADVANCED.md): artifact optimization, GEPA-style reflection,
  agents, MCP, schemas, and deterministic fixtures.
- [RLM Fidelity](RLM_FIDELITY.md): the BEAM-native recursive-control design,
  upstream invariants, evidence tiers, and remaining paper-scale blocker.
- [Instruction Optimizer Fidelity](INSTRUCTION_OPTIMIZER_FIDELITY.md): pinned
  MIPROv2 and SIMBA algorithms, BEAM-native design, and evidence boundaries.
- [ComBee-Style GEPA Aggregation Fidelity](COMBEE_FIDELITY.md): hierarchical
  reflection aggregation, measured batch control, budget and timeout policy,
  and evidence boundaries.

The source checkout also contains maintainer-only authority, coverage, parity,
and release ledgers. They are intentionally excluded from the consumer package
because their commands operate on repository evidence infrastructure.

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

- [Observability and Debugging](OBSERVABILITY.md): redacted inspection,
  normalized status, progress subscriptions, and trace capture.
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
catalog and release-evidence notes are the maintainer starting point for
outside-view validation work.

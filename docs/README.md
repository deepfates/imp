# DSEx Documentation

This directory is the practical manual for DSEx. It is meant to be read
alongside the code and tests, not instead of them.

## Reading Path

1. [Philosophy](DSEX_PHILOSOPHY.md): the Elixir-native model of declarative
   self-improving programs.
2. [API Guide](API_GUIDE.md): task-oriented examples for signatures, modules,
   adapters, optimizers, agents, RLM, MCP, persistence, and providers.
3. [Prior Art](PRIOR_ART.md): project lineage, terminology, and independence.
4. [Livebook 01](../livebooks/01_programming_not_prompting.livemd):
   signatures, predictions, examples, and schema-constrained output.
5. [Livebook 02](../livebooks/02_evaluate_and_optimize.livemd): evaluation,
   optimizer reports, and artifact optimization.
6. [Livebook 03](../livebooks/03_agents_tools_mcp_rlm.livemd): tools, agents,
   MCP-style catalogs, ReActV2, and RLM.
7. [Advanced DSEx](V2.md): artifact optimization, GEPA, agents, MCP, schemas,
   and deterministic benchmark fixtures.
8. [Production Operations](PRODUCTION_OPERATIONS.md): gates, live credentials,
   security posture, and release discipline.
9. [Architecture](ARCHITECTURE.md): the modules, behaviours, data flow, and
   supervision/runtime boundaries.
10. [Completion Plan](COMPLETION_PLAN.md): release-blocking V3 criteria and
    the external references used to define production readiness.

## Livebooks

Open the notebooks in `livebooks/` when you want to learn by running code:

- `01_programming_not_prompting.livemd`
- `02_evaluate_and_optimize.livemd`
- `03_agents_tools_mcp_rlm.livemd`
- `04_production_and_live_provider.livemd`

All notebooks use deterministic fake LMs by default. The live-provider notebook
has an explicit opt-in cell for local `.env` credentials.

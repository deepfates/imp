# DSEx Documentation

This directory is the practical manual for DSEx. It is meant to be read
alongside the code and tests, not instead of them.

## Reading Path

1. [Philosophy](DSEX_PHILOSOPHY.md): the Elixir-native model of declarative
   self-improving programs.
2. [Architecture](ARCHITECTURE.md): the modules, behaviours, data flow, and
   supervision/runtime boundaries.
3. [Terminology](TERMINOLOGY.md): the canonical vocabulary for an Elixir-native
   DSEx project.
4. [API Guide](API_GUIDE.md): task-oriented examples for signatures, modules,
   adapters, optimizers, agents, RLM, MCP, persistence, and providers.
5. [Production Operations](PRODUCTION_OPERATIONS.md): gates, live credentials,
   security posture, and release discipline.

## Livebooks

Open the notebooks in `livebooks/` when you want to learn by running code:

- `01_programming_not_prompting.livemd`
- `02_evaluate_and_optimize.livemd`
- `03_agents_tools_mcp_rlm.livemd`
- `04_production_and_live_provider.livemd`

All notebooks use deterministic fake LMs by default. The live-provider notebook
has an explicit opt-in cell for local `.env` credentials.

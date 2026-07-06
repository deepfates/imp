# Prior Art

DSEx is an independent Elixir library. It is not affiliated with, endorsed by,
or API-compatible with the projects below.

DSEx exists in a lineage of work on programming language-model systems instead
of hand-writing prompt glue:

- [DSPy](https://dspy.ai/) and
  [stanfordnlp/dspy](https://github.com/stanfordnlp/dspy) popularized the
  framing of signatures, modules, metrics, evaluation, and optimizers for
  language-model programs.
- [Ax](https://axllm.dev/) and [ax-llm/ax](https://github.com/ax-llm/ax)
  show a TypeScript-centered interpretation with typed signatures,
  validation, streaming, tools, agents, and optimization.
- [GEPA](https://gepa-ai.github.io/gepa/) and its
  [optimize_anything](https://gepa-ai.github.io/gepa/blog/2026/02/18/introducing-optimize-anything/)
  work demonstrate reflective, Pareto-aware optimization for prompts and other
  text artifacts.
- [ds_ex / DSPEx](https://github.com/nshkrdotcom/ds_ex) is prior Elixir work
  on pure-BEAM DSPy-style programming. During the rebuild, it was useful as a
  reference for real BootstrapFewShot/SIMBA-style behavior and for the
  mock/fallback/live test-mode pattern.
- `dsxir` was reviewed as another Elixir attempt in the rebuild brief. Its
  process-local settings stack and Laplace-smoothed categorical TPE were useful
  references for DSEx's dynamic settings and MIPROv2 work.

The goal of DSEx is not a mechanical translation of any one codebase. It is a
BEAM-native interpretation of the same broad philosophy:

- explicit data structures over ambient prompt strings
- runtime settings through scoped process context
- supervised and injectable boundaries for provider I/O
- deterministic tests and negative controls for optimizer claims
- tool, agent, MCP, streaming, and sandbox contracts expressed as ordinary
  Elixir modules

When DSEx borrows terminology such as signature, module, metric, optimizer,
MIPROv2, GEPA, ReAct, or RLM, the local module documentation and tests define
the DSEx contract.

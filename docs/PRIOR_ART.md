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
- [BAML](https://github.com/BoundaryML/baml),
  [AdalFlow](https://github.com/SylphAI-Inc/AdalFlow),
  [TextGrad](https://github.com/zou-group/textgrad), and
  [SAMMO](https://github.com/microsoft/sammo) provide useful comparisons for
  compiler diagnostics, parameter graphs, textual feedback, and structured
  prompt transformations. They are comparators, not DSEx compatibility targets.
- [ReqLLM](https://github.com/agentjido/req_llm),
  [Jido](https://github.com/agentjido/jido), and
  [Jido AI](https://github.com/agentjido/jido_ai) are the nearest BEAM production
  complements for provider transport, multimodal content, tools, telemetry,
  supervised agents, and explicit effects.
- [ds_ex / DSPEx](https://github.com/nshkrdotcom/ds_ex) is prior Elixir work
  on pure-BEAM DSPy-style programming, and
  [gepa_ex](https://github.com/nshkrdotcom/gepa_ex) is nearby Elixir GEPA work.
  They are prior art to inspect, not authorities for parity or effectiveness.

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

The broader paper, repository, and production-system review is recorded in
[Research Landscape](RESEARCH_LANDSCAPE.md).

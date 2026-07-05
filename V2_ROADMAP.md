# Production Ready V2 Roadmap

V2 is complete only when every P0 and P1 item in this file is `PROVEN`, the
V2 audit gate passes, `mix production.check` passes, applicable live gates pass,
and the repo is clean and committed.

Statuses:

- `PROVEN`: implemented and backed by executable tests, contract tests, live
  evidence, benchmark fixtures, or docs as appropriate.
- `PARTIAL`: meaningful implementation exists, but evidence is not broad enough.
- `UNPROVEN`: not implemented or not verified enough for V2.

## V2 Requirements

| ID | Priority | Requirement | Status | Completion evidence | Completion criteria |
| --- | --- | --- | --- | --- | --- |
| V2-OA-001 | P0 | `DSPy.Optimize.Anything` optimizes arbitrary text artifacts using a declarative artifact spec, train/val examples, evaluator feedback, diagnostics, and reproducible search configuration. | PROVEN | `test/optimize_anything_test.exs` covers improvement, baseline retention, deterministic lineage, prompt/code/config/text artifact kinds, named parameters, diagnostics, evaluator error handling, and report save/load. | Keep API stable while integrating V2 benchmarks and docs. |
| V2-GEPA-001 | P0 | GEPA supports Pareto-aware reflective evolution with Actionable Side Information (ASI), mutation, candidate lineage, and system-aware merge. | PROVEN | `test/optimize_gepa_test.exs` covers per-example scores, Pareto frontier selection, ASI-driven mutation, candidate lineage, replacement branches, system-aware merge, single-task, multi-task, and held-out generalization behavior. | Add larger benchmark tasks under V2-BENCH-001. |
| V2-AGENT-001 | P0 | Agent runtime affordances cover typed agents, flows, runtime sessions, memory/context fields, tool execution, and child/specialist agents. | PROVEN | `test/agent_runtime_test.exs` covers typed input/output schemas, tool execution, tool failure, child agents, large context references, memory, streaming, and trace capture. | Add adapters for external agent runtimes as integrations require them. |
| V2-MCP-001 | P1 | MCP-style tool discovery/import exposes external tool catalogs as typed `DSPy.Tool` values without hard-coding tool schemas. | PROVEN | `test/mcp_import_test.exs` covers in-process MCP-style catalog discovery, schema import, input validation, normalized errors, and agent integration. | Add transport-backed MCP client when a real external MCP server is targeted. |
| V2-SCHEMA-001 | P0 | Signature fields support schema constraints and validation retry feedback: enum, numeric bounds, string length/pattern, arrays, nested objects, optional fields, and JSON Schema export. | UNPROVEN | None yet. | Constraint parser and builder APIs exist; adapters validate outputs and generate retry feedback; tests cover success/failure for every constraint family and prove schema export stability. |
| V2-BENCH-001 | P0 | Benchmark fixtures compare Ax-style signatures and GEPA optimize-anything tasks with reproducible scores and production-gate reporting. | UNPROVEN | None yet. | Benchmarks include at least one structured extraction task, one agent/tool task, one prompt optimization task, and one arbitrary text/code/config optimization task; results are deterministic in CI and fail on material regressions. |
| V2-DOC-001 | P1 | V2 docs explain APIs, completion evidence, examples, migration notes from V1, and honest remaining non-goals. | UNPROVEN | None yet. | README/docs include runnable examples for Optimize.Anything, Pareto GEPA, agents/MCP, schema constraints, and benchmarks; docs link to tests/gates and do not claim unsupported parity. |

## V2 Gates

V2 is not complete unless all of these pass:

```sh
mix v2.check
mix production.check
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

`mix v2.check` must run the V2 audit, V2 benchmark fixtures, and any V2-specific
contract suites.

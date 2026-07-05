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
| V2-GEPA-001 | P0 | GEPA supports Pareto-aware reflective evolution with Actionable Side Information (ASI), mutation, candidate lineage, and system-aware merge. | UNPROVEN | None yet. | Candidate pool tracks per-example scores; Pareto frontier selection is tested; ASI diagnostics influence mutations; merge combines complementary candidates; tests cover single-task, multi-task, and generalization behavior. |
| V2-AGENT-001 | P0 | Agent runtime affordances cover typed agents, flows, runtime sessions, memory/context fields, tool execution, and child/specialist agents. | UNPROVEN | None yet. | Agents can forward typed inputs through tools and child agents; large context can live by reference in a runtime session; memory/context state is inspectable; tests cover tool success/failure, nested agents, context references, streaming, and trace capture. |
| V2-MCP-001 | P1 | MCP-style tool discovery/import exposes external tool catalogs as typed `DSPy.Tool` values without hard-coding tool schemas. | UNPROVEN | None yet. | Discovery adapter parses tool list/schema responses; imported tools validate inputs and normalize outputs/errors; tests use an in-process fake MCP server/catalog and prove agent integration. |
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

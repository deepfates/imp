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
| V2-GEPA-001 | P0 | GEPA supports Pareto-aware reflective evolution with Actionable Side Information (ASI), mutation, candidate lineage, and system-aware merge. | PARTIAL | `test/optimize_gepa_test.exs` covers deterministic Pareto mechanics but lacks source-backed reflective proposer/trace parity. | Add reflection-model proposer, real train/dev split, non-tautological generalization fixtures, and clearer relationship to upstream GEPA. |
| V2-AGENT-001 | P0 | Agent runtime affordances cover typed agents, flows, runtime sessions, memory/context fields, tool execution, and child/specialist agents. | PARTIAL | `test/agent_runtime_test.exs` covers a minimal runtime; handler ergonomics currently require self-reference workarounds. | Redesign handler API to avoid process dictionary self-reference; add incremental event streaming and tool policies. |
| V2-MCP-001 | P1 | MCP-style tool discovery/import exposes external tool catalogs as typed `DSPy.Tool` values without hard-coding tool schemas. | PARTIAL | `test/mcp_import_test.exs` covers in-process catalog import but only required-key validation. | Route MCP schemas through `DSPy.Schema`; add string-key JSON-schema fixtures, duplicate-name handling, malformed catalog errors, and transport-backed client. |
| V2-SCHEMA-001 | P0 | Signature fields support schema constraints and validation retry feedback: enum, numeric bounds, string length/pattern, arrays, nested objects, optional fields, and JSON Schema export. | PROVEN | `test/schema_constraints_test.exs` covers enum, numeric bounds, string length/pattern, arrays, nested objects, optional fields, JSON Schema export, and JSON adapter retry feedback. | Add provider-native schema export when provider-specific APIs require it. |
| V2-BENCH-001 | P0 | Benchmark fixtures compare Ax-style signatures and GEPA optimize-anything tasks with reproducible scores and production-gate reporting. | PARTIAL | `test/v2_benchmark_test.exs` currently provides deterministic smoke fixtures. | Add negative controls and non-tautological train/dev benchmark tasks before claiming regression-grade coverage. |
| V2-DOC-001 | P1 | V2 docs explain APIs, completion evidence, examples, migration notes from V1, and honest remaining non-goals. | PARTIAL | `V2.md`, `README.md`, and `V2_ROADMAP.md` exist but overstate maturity. | Reword V2 docs as experimental/partial until implementation catches up. |

## V2 Gates

V2 is not complete unless all of these pass:

```sh
mix v2.check
mix production.check
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
```

`mix v2.check` must run the V2 audit, V2 benchmark fixtures, and any V2-specific
contract suites.

# DSEx Release Criteria

This document records the release criteria for a production-ready DSEx build.

The central standard is simple: DSEx should feel like an Elixir-native system
from a world where declarative self-improving programs were designed on the
BEAM from the start. It should not be a Python compatibility layer, a set of
hand-written prompt helpers, or a collection of impressive demos with hidden
production caveats.

## References

The release standard is grounded in:

- DSPy's public surface: signatures, modules, adapters, evaluation,
  optimizers, primitives, tools, MCP, cache, deployment, streaming, async,
  saving/loading, and observability: <https://dspy.ai/>
- DSPy's optimizer contract: programs, metrics, training examples, demo
  synthesis, instruction search, GEPA, and finetuning:
  <https://github.com/stanfordnlp/dspy/blob/main/docs/docs/learn/optimization/optimizers.md>
- DSPy's metric/evaluation contract: boolean, numeric, and feedback-bearing
  metric returns; trace-aware optimizer calls; failure scores:
  <https://dspy.ai/diving-deeper/metrics-and-evaluation/>
- Ax's language-port lesson: a signature is the semantic contract for
  validation, retries, tools, traces, examples, optimization, and deployment:
  <https://axllm.dev/typescript/concepts/dspy/>
- optimize_anything's generalization: any measurable text artifact can be
  optimized with per-task/per-metric feedback and Pareto-aware search:
  <https://gepa-ai.github.io/gepa/blog/2026/02/18/introducing-optimize-anything/>
- DSEx's parity validation program: golden trace parity, live matched-model
  parity, optimizer lift, production semantics, and provider-free performance
  evidence: `docs/PARITY_VALIDATION_PROGRAM.md`

## Release Scope

The production release scope is tracked under ticket `de-vwsu`.

| Ticket | Work | Release Meaning |
| --- | --- | --- |
| `de-5dt5` | Canonical upstream coverage matrix | A public truth table maps each DSPy/Ax/optimize_anything concept to DSEx status, tests, docs, and intentional deviations. |
| `de-qvwf` | Dependency and runtime hardening | Runtime choices are idiomatic Elixir and justified: HTTP, option validation, telemetry, and test infrastructure are no longer ad hoc. |
| `de-i8cc` | Split release gates by proof level | Deterministic, local integration, live inference, and costly/stateful live workflows have separate gates. |
| `de-ld5r` | Remove unsupported production fallbacks | Production-facing APIs require real backends instead of treating unsupported behavior as success. |
| `de-wrnz` | External integration E2E coverage | MCP, retrievers, save/load/rebind/deploy, and optional provider workflows are exercised end to end. |
| `de-2iou` | Metric/evaluation contract parity | Metrics preserve score, feedback, traces, failures, and optimizer-facing signal. |
| `de-x02m` | Production observability and trace model | Telemetry events make DSEx inspectable without leaking secrets. |
| `de-t7s8` | Release-grade docs, Livebooks, and examples | Documentation becomes a cohesive product manual, not historical project notes. |
| `de-k5tf` | Full parity validation program | Release claims are backed by a dashboard covering trace parity, live matched models, optimizer lift, production semantics, and provider-free performance. |

## Gate Model

Required gates:

```sh
mix production.check
mix integration.check
mix protocol.check
mix benchmark.trace.check
mix package.check
mix quality.check
LIVE_PROVIDER=1 mix live.check
```

Provider-compatible protocol workflows have explicit local gates instead of
being smuggled into the live-provider path:

```sh
mix protocol.training.check
mix protocol.retriever.check
mix protocol.mcp.check
```

If DSEx does not support one of those workflows as production surface, the API
and docs must say so directly rather than presenting unsupported behavior as a
complete feature.

## Completion Criteria

DSEx is production complete when:

1. `tk ready -T dsex` returns no production release blockers.
2. `tk dep cycle` reports no cycles.
3. `mix production.check` passes.
4. `mix integration.check` passes.
5. `mix protocol.check` passes.
6. `mix benchmark.trace.check` passes.
7. `mix package.check` passes.
8. `mix quality.check` passes.
9. GitHub Actions runs the deterministic release gates:
   `production.check`, `integration.check`, `protocol.check`,
   `package.check`, and `quality.check`.
10. `LIVE_PROVIDER=1 mix live.check` passes with local credentials.
11. Any public production claim about paid training, external retrievers, or
   external MCP servers is backed by dedicated external-service tests, or the
   claim is removed.
12. The docs and Livebooks teach DSEx as a coherent Elixir-native system.
13. `mix benchmark.dashboard` produces a current
    `parity-dashboard-*.json` artifact.
14. `mix benchmark.dashboard.full` passes, and the dashboard reports
    `full_parity: true`, before the release claims full DSPy parity.
    When this gate fails, its terminal error must name the blocking release
    requirements so the next operator can continue from the failure without
    hand-inspecting the dashboard JSON first.
15. The parity dashboard reports `performance_claim_supported: true` before the
    release claims DSEx is faster than DSPy on any named path.
16. Live latency claims cite dashboard or matrix instrumentation that separates
    provider/model time from DSEx local overhead and adapter recovery.
17. Live matched-model claims cite artifacts whose prompt/signature contract is
    current for every selected model lane.
18. Any missing parity lane is reflected in public docs as a limitation, not
    hidden behind a passing smoke benchmark.

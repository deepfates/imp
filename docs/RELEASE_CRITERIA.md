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

## Release Scope

The V3 release scope is tracked under ticket `de-vwsu`.

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

## Gate Model

Required gates:

```sh
mix production.check
mix integration.check
mix quality.check
LIVE_PROVIDER=1 mix live.check
```

Stateful or paid external workflows have explicit opt-in gates instead of being
smuggled into the default release path:

```sh
LIVE_TRAINING=1 mix live.training.check
LIVE_RETRIEVER=1 mix live.retriever.check
LIVE_MCP=1 mix live.mcp.check
```

If DSEx does not support one of those workflows as production surface, the API
and docs must say so directly rather than presenting unsupported behavior as a
complete feature.

## Completion Criteria

DSEx V3 is complete when:

1. `tk ready -T dsex` returns no V3 release blockers.
2. `tk dep cycle` reports no cycles.
3. `mix production.check` passes.
4. `mix integration.check` passes.
5. `mix quality.check` passes.
6. GitHub Actions runs the deterministic release gates:
   `production.check`, `integration.check`, and `quality.check`.
7. `LIVE_PROVIDER=1 mix live.check` passes with local credentials.
8. Any public production claim about training, retrievers, or MCP is backed by
   an integration/live gate, or the claim is removed.
9. The docs and Livebooks teach DSEx as a coherent Elixir-native system.

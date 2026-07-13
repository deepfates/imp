# DSEx Release Criteria

This document records the release criteria for a production-ready DSEx build.

For v0.1, "production-ready" means the scoped product contract in
`docs/V0_1_RELEASE_LEDGER.md`. It does not mean full DSPy parity or paper-level
replication. Research gates authorize those stronger claims independently.

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
  parity, optimizer lift, production semantics, RLM benchmark parity, and
  provider-free performance evidence: `docs/PARITY_VALIDATION_PROGRAM.md`
- DSEx's benchmark catalog: a source-grounded outside-view map of DSPy-derived
  benchmark families and which ones are runnable, sampled, deferred, or
  release-blocking: `docs/BENCHMARK_CATALOG.md`

## Release Scope

The production release scope is the current DSEx product surface plus the
evidence required to trust it. Historical planning tickets are not release
criteria; current commands, docs, tests, and artifacts are.

| Surface | Release Meaning |
| --- | --- |
| Coverage matrix | `docs/COVERAGE_MATRIX.md` maps each DSPy/Ax/optimize_anything concept to DSEx status, tests, docs, and intentional deviations. |
| Runtime boundary | Provider access goes through ReqLLM, injectable behaviours, explicit transports, option validation, telemetry, and redaction rather than hidden fallbacks. |
| Proof-level gates | Deterministic production, local integration, provider-compatible protocol, paid live inference, and parity evidence gates are separate commands with separate claims. |
| External workflows | MCP, retrievers, save/load/rebind, streaming, tools, and provider-compatible training are exercised through local integration or protocol gates before they appear as production surface. |
| Evaluation and optimization | Metrics preserve score, feedback, traces, failures, and optimizer-facing signal; optimizers emit executable compiled programs and reports. |
| Documentation | README, ExDoc, docs, and Livebooks teach DSEx as a cohesive Elixir-native system rather than a Python compatibility layer or project history. |
| Parity evidence | Release claims are backed by separate dashboard lanes for golden trace parity, live matched models, optimizer lift, Optimize Anything non-prompt effectiveness, pinned instruction-optimizer structure, production semantics, and provider-free performance. |
| Clean-room product proof | A fresh Mix project can consume the unpacked package and exercise the golden user journey through the public API: predict, optimize, save/load, ReAct tools, provider construction, and credential redaction. |

## Gate Model

Required gates:

```sh
mix production.check
mix integration.check
mix protocol.check
mix benchmark.trace.check
mix benchmark.instruction_optimizer.contract.check
mix package.check
mix livebook.check
mix livebook.execute.check
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

1. `tk ready | rg '^de-'` shows no ready DSEx production-release blockers
   that lack an owner or an explicit non-blocking release decision.
2. `tk dep cycle` reports no cycles.
3. `mix production.check` passes.
4. `mix integration.check` passes.
5. `mix protocol.check` passes.
6. `mix benchmark.trace.check` passes.
7. `mix package.check` passes, including the clean-room package-consumer
   workflow that installs the unpacked Hex artifact into a fresh Mix project and
   exercises prediction, optimization, save/load, ReAct tools, provider-client
   construction, and credential redaction through public APIs.
8. `mix livebook.check` validates the shipped notebooks under `livebooks/`.
9. `mix livebook.execute.check` executes the shipped notebooks when changing
   public examples, saving/loading examples, or learning material control flow.
10. `mix quality.check` passes.
11. GitHub Actions runs the deterministic release gates:
   `production.check`, `integration.check`, `protocol.check`,
   `package.check`, `livebook.check`, and `quality.check`.
12. `LIVE_PROVIDER=1 mix live.check` passes with local credentials.
13. Any public production claim about paid training, external retrievers, or
   external MCP servers is backed by dedicated external-service tests, or the
   claim is removed.
14. The docs and Livebooks teach DSEx as a coherent Elixir-native system.
15. `mix benchmark.dashboard` produces a current
    `parity-dashboard-*.json` artifact.
16. `mix benchmark.dashboard.full` passes, and the dashboard reports
    `full_parity: true`, before the release claims full DSPy parity.
    When this gate fails, its terminal error must name the blocking release
    requirements so the next operator can continue from the failure without
    hand-inspecting the dashboard JSON first.
    The gate also evaluates `benchmarks/claims.json`; every release-blocking
    public claim must map to fresh passing evidence before the full dashboard
    gate passes. See `docs/BENCHMARK_CLAIMS.md`.
    Source-checkout release gates that are not benchmark tasks produce
    dashboard evidence through `mix gate.package.evidence`,
    `mix gate.livebook.evidence`, `mix gate.protocol.evidence`, and
    `mix gate.live_provider.evidence`.
17. The parity dashboard reports `performance_claim_supported: true` before the
    release claims DSEx is faster than DSPy on any named path.
18. Live latency claims cite dashboard or matrix instrumentation that separates
    provider/model time from DSEx local overhead and adapter recovery.
19. Live matched-model claims cite artifacts whose prompt/signature contract is
    current for every selected model lane.
20. Live matched-model claims cite artifacts with one consistent
    `max_concurrency` setting per selected campaign artifact. Mixed or missing
    concurrency evidence blocks full parity and performance claims until rerun
    or isolated.
21. Any missing parity lane is reflected in public docs as a limitation, not
    hidden behind a passing smoke benchmark.
22. Full GEPA replication and source-fidelity claims cite per-optimizer runtime
    metric-call counts with enforced limits and concrete provenance. Configured
    budgets copied into result fields are not execution evidence, and any score
    selected by comparing test-seed outcomes keeps the GEPA dashboard lane red.

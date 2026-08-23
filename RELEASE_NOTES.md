# Imp v0.3.1

Imp is a framework for typed, optimizable language-model programs on the BEAM.
Declare a task as named inputs and outputs, call it like any other Elixir
program, measure it on examples, compile it with an optimizer, and run the
selected program under OTP.

## Install

`v0.3.1` is a private Git source release. GitHub credentials with access to the
repository are required.

```elixir
{:imp, github: "deepfates/imp", tag: "v0.3.1"}
```

Imp is not published to Hex. Use a path dependency only while developing
against a local checkout.

## What is included

- Typed signatures with scalar, collection, enum, union, optional, default,
  code, and constrained fields.
- `Predict`, `ChainOfThought`, composed `Imp.Module` programs, retrieval,
  ReActV2, CodeAct, RLM, tools, MCP, and provider streaming.
- Examples, metrics, concurrent evaluation, disjoint train/selection/test
  experiments, and optimizer reports.
- Demonstration, instruction, prompt, ensemble, rule, playbook, and
  weight-training optimizer families, including GEPA, MIPROv2, SIMBA, COPRO,
  BootstrapFewShot, RandomSearch, KNNFewShot, BootstrapFinetune, BetterTogether,
  Avatar, and Optimize Anything.
- Checksummed whole-program and parameter artifacts that exclude credentials
  and apply selected state to freshly constructed trusted code.
- OTP-native operation with bounded tasks, cancellation, per-effect
  authorization, redacted telemetry, caching, usage accounting, hot reload,
  and failure propagation.
- ReqLLM provider clients, explicit local/static test models, retriever and
  trainer extension points, and local MLX/TRL integration boundaries.

The [Learning Path](docs/LEARNING_PATH.md) builds one program from its first
provider call through evaluation, optimization, tools, persistence, and
deployment. The [deployment example](examples/deployment/README.md) shows a
supervised two-stage program with parameter reload, concurrent calls, restart,
timeouts, and crash containment. Five Livebooks cover the same system
interactively.

## What the BEAM changes

Imp preserves DSPy's program/evaluate/optimize workflow without copying
Python's object model. Programs are immutable values. Configuration can be
explicit or process-scoped. Evaluation and tool work run in supervised tasks.
Telemetry uses standard `:telemetry` events. Saved state is rebound to live
providers and callbacks at application startup instead of serializing runtime
authority.

Provider output and optimizer search are stochastic. A compiled program is a
candidate until it improves the metric that matters on data excluded from
training and selection. Imp supplies that lifecycle; applications still own
their data, metric, budget, promotion rule, and operational policy.

DSPy's Python integration ecosystem is larger. Imp exposes extension points
for providers, retrievers, adapters, tools, and trainers, but Python-only
integrations do not automatically work on the BEAM. DSPy's Flex code optimizer
is not included in this release.

The supported center is the `Imp` facade, signatures, adapters, evaluation,
static and ReqLLM execution, tools, telemetry, saving, and the deployment
pattern. Generated docs place optimizer implementations, parameter artifacts,
agent loops, training integrations, and `Imp.Run` in **Experimental optimizers
and advanced workflows**. These are implemented and tested APIs, not release
promises of effectiveness or pre-1.0 shape stability. In particular, GRPO is
an external-training boundary rather than an in-process gradient engine.

## Breaking changes from v0.2.1

- `Imp.optimize/3`, `/4`, and `/5` return `{:ok, program}` or
  `{:error, reason}`. Use the corresponding `Imp.optimize!` function when a
  failure should raise.
- `Imp.Adapters.Types` and its nested structs moved to `Imp.Adapter.Types`.
- `Imp.Agent` and `Imp.Agent.Runtime` were removed. Use ReActV2 or RLM as the
  program and ordinary Elixir supervision as the runtime. Use
  `Imp.start_run/3` only when a host needs ordered events, addressable
  cancellation, or explicit effect authorization.

## Upgrade path

1. Replace `Imp.Adapters.Types` references with `Imp.Adapter.Types`.
2. Choose the returning or raising optimizer API explicitly.
3. Replace `Imp.Agent` usage with a ReActV2/RLM program owned by your
   supervision tree.
4. Rebuild saved artifacts with `0.3.1` before promotion.
5. Run your held-out evaluation and application smoke test against the tagged
   dependency.

Generated module documentation is the complete API reference. Start with
`Imp`, `Imp.Signature`, `Imp.Module`, `Imp.Evaluate`, `Imp.Optimizer`,
`Imp.Optimizer.Artifact`, `Imp.Run`, and `Imp.Telemetry`.

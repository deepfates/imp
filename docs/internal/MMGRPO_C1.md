# mmGRPO C1 differential

The provider-free `mmgrpo-c1-v1` protocol compares a narrow semantic projection
of `Imp.Optimizer.GRPO` with DSPy 3.2.1 at commit
`29448ae12756abdd14bd8796c819247ebb83673c`. The Python side executes DSPy's
actual `GRPO.compile/3` path with a local reinforcement-job fixture and patched
trace collection; the Elixir side executes Imp's public compiler with a local
`Imp.Clients.Trainer` fixture. Neither side contacts a provider.

The comparison covers balanced dataset cycling, two-rollout group cardinality,
two-predictor attribution, successful program-reward propagation, and the
configured structured-format failure reward. Its source binding hashes the
canonical `family.optimizer_mmgrpo` authority projection, the pinned authority
manifest, both harness implementations, the fixture, and Imp's GRPO source.
Unrelated authority-ledger edits therefore do not invalidate this family.

The protocol does **not** claim exact Python RNG or shuffle order, provider or
transport behavior, model quality, training effectiveness, variable-invocation
fill strategy parity, execution-failure parity, or full optimizer parity. Imp's
durable dispatch journal, bounded callbacks, reconciliation, stable idempotency
keys, and atomic artifact rebinding remain explicit BEAM-native extensions.

After the protocol is registered and these files are committed, capture must be
performed only from a clean checkout:

```sh
mix imp.benchmark.mmgrpo_differential --require-clean
```

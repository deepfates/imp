# Local Optimize Anything retry policy

This ordinary local example optimizes a mixed-type retry-controller
configuration through `Imp.Optimize.Anything.run/3`. The artifact contains
booleans and integers; a pinned local `phi4:latest` proposes strict replacement
values, while a deterministic operational evaluator executes each candidate on
frozen retry scenarios. Valid JSON alone earns no credit.

Eight training cases provide feedback, six separate cases select between the
baseline and proposed policy, and six untouched cases open only after
selection. The selected native map is written to disk, loaded in a fresh OS
BEAM, and required to reproduce ordered untouched outcomes byte-for-byte.

The run is intentionally bounded to one proposal round, one transport attempt
per component, no cache, and no provider. A neutral, malformed, or worse
proposal is a valid outcome and leaves baseline selected.

```sh
mix deps.get
mix run run.exs
```

One result can establish an ordinary arbitrary-artifact lifecycle and a narrow
task/model outcome. It cannot establish general Optimize Anything
effectiveness, schema-v2 multi-seed evidence, upstream parity, or BEAM
superiority.

The first frozen local-model attempt is retained in
`exercised-stopped-result.json`. The model returned an object for the integer
`base_ms` component; Imp rejected the type drift before candidate evaluation,
selection, or untouched test access. The value was not extracted or normalized.

A subsequent prompt-clarified run is retained separately in
`exercised-recorder-stopped-result.json`. The bounded optimizer returned, but
the example's recorder attempted to JSON-encode a raw rejected-proposal tuple
before writing the portable result. The in-memory winner is not inferred and
the untouched test remained unopened.

The repaired recorder allowed that exact bounded condition to finish without
repeating its proposal round. `exercised-result.json` records four local-model
component calls, atomic rejection of the malformed candidate, baseline
selection at `0.56365`, untouched score `0.70059` with four of six exact cases,
and byte-identical baseline artifact behavior in a fresh OS BEAM. It proves
strict failure containment and durable consumption, but no mutation or lift.

The current runner names a separate `local-oa-retry-policy-llama3.3-v1`
condition. Before any task call, it selected the already-installed
`llama3.3:latest` artifact with digest
`a6eb4748fd2990ad2952b2335a95a7f952d1a06119a0aa6a2df6cd052a93a3fa`
for its general instruction-following capacity. It preserves the exact seed,
objective, proposal count, component-wise strict decoder, evaluator, rows,
splits, and metrics above; it performs no extraction or result-driven
normalization. New executions require an empty owned output directory. A valid
mutation may still lose to baseline on selection, and either outcome is valid.

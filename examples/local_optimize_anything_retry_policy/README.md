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

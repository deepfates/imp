# Classical optimizer lifecycle

This bounded live example exercises three demonstration optimizers through the
same ordinary support-routing program and disjoint 20/20/20 train, selection,
and test rows:

- `BootstrapFewShot` generates metric-accepted demonstrations from real teacher
  calls;
- `RandomSearch` evaluates the zero-shot, labeled, and bootstrapped candidate
  families and selects on the separate selection split; and
- `KNNFewShot` retrieves relevant train rows and bootstraps per request.

The run evaluates every selected program on untouched test rows, writes private
parameter artifacts for BootstrapFewShot and RandomSearch, writes the portable
KNN program, and invokes a fresh OS BEAM that reconstructs the live LM and
serves four representative probes from each retained state. Provider calls use
one prospective request/token/dollar budget with retries and cache disabled.
The KNN save replaces its process-owned live budget wrapper with a
credential-free ReqLLM descriptor; the fresh process binds a new budgeted
runtime instead of serializing credentials or PIDs.

From the repository root:

```sh
OPENROUTER_API_KEY=... \
IMP_CLASSICAL_OUTPUT=/secure/imp-classical-live \
mix run examples/optimizer_lifecycles/classical.exs
```

The output is a task-scoped product receipt, not a general effectiveness or
upstream-parity claim. Keep honest neutral or negative runs; diagnose them
before choosing a different treatment.

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
Its bootstrap metric crosses the code/data boundary by a stable
`Imp.Saving.Registry` key and is reconstructed from trusted code after restart.
The fresh provider probe requires error-free useful behavior rather than
byte-identical outputs: parameter identity is exact, but model sampling remains
a runtime observation.

From the repository root:

```sh
OPENROUTER_API_KEY=... \
IMP_CLASSICAL_OUTPUT=/secure/imp-classical-live \
mix run examples/optimizer_lifecycles/classical.exs
```

The output is a task-scoped product receipt, not a general effectiveness or
upstream-parity claim. Keep honest neutral or negative runs; diagnose them
before choosing a different treatment.

## Retained clean run

The `exercised-classical/` directory retains the complete clean-commit run from
`f21a456f9f2be7066251640dbeeab02a3d0f7ff4`. On untouched test rows, the live
baseline scored `0.40`; BootstrapFewShot scored `0.90`, RandomSearch `0.95`, and
KNNFewShot `0.60`, all with zero row errors. Fresh OS processes loaded the exact
retained states and scored `1.00`, `1.00`, and `0.75` on four representative
probes. The main run made 423 single-attempt transports, used 159,669 input and
5,734 output tokens, and recorded `$0.145534`; the three fresh processes have
their own bounded usage ledgers in `result.json`.

The first clean attempt usefully failed because a process-owned budget wrapper
is not portable. The second exposed the required executable-metric registry.
The lifecycle now persists a credential-free model descriptor and a stable
metric key, then reconstructs both trusted runtime capabilities after restart.
That is the intended persistence contract, not a workaround.

## Instruction and rule optimizer lifecycle

`instruction.exs` applies the same acceptance shape to `SignatureOptimizer`
and `InferRules`. It uses a separate live proposal model, makes selection on
the development split, opens the test split only after compilation, writes
parameter Artifacts, and applies them to fresh trusted program code in new OS
processes. Task and optimizer budgets are separate so their different prices
and failure envelopes remain visible.

```sh
OPENROUTER_API_KEY=... \
IMP_INSTRUCTION_OUTPUT=/secure/imp-instruction-live \
mix run examples/optimizer_lifecycles/instruction.exs
```

The `exercised-instruction/` directory retains the complete clean-commit run
from `a24a408660eaff7ac9b4ed2cd8691c5a177f8cf3`. The live zero-shot baseline
scored `0.30` on the untouched test split. `SignatureOptimizer` selected at
`1.00` and scored `0.95` on test; `InferRules` selected at `1.00` and scored
`0.90` on test. Both had zero row errors and scored `1.00` on four fresh-OS
probes after their exact private Artifacts were loaded into trusted program
code. The main task and optimizer budgets recorded 293 single-attempt calls and
`$0.143254`; fresh probes retain their own ledgers in `result.json`.

An earlier clean attempt completed the same mechanisms but InferRules did not
beat that run's `0.40` test baseline, and the acceptance runner asserted before
persisting its complete receipt. That negative remains recorded on the owning
ticket. The runner now writes the receipt before judging it; the retained run
is a second exact treatment for instrumentation repair, not multi-seed evidence.

## Ensemble lifecycle

`ensemble.exs` composes the retained BootstrapFewShot, SignatureOptimizer, and
InferRules routers with the public `Ensemble` constructor and a stable majority
reducer. It evaluates the children and composition on the held-out test split,
then reconstructs trusted code and all three child Artifacts in a fresh OS
process. This tests composition and operation without rerunning any search.

```sh
OPENROUTER_API_KEY=... \
IMP_ENSEMBLE_OUTPUT=/secure/imp-ensemble-live \
mix run examples/optimizer_lifecycles/ensemble.exs
```

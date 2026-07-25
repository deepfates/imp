# BootstrapFinetune and BetterTogether C1 differential

This provider-free tranche compares Imp with the source-authenticated DSPy 3.2.1 commit
`29448ae12756abdd14bd8796c819247ebb83673c`. The Python sidecar verifies every file in the
pinned 296-file authority materialization, verifies the family source and upstream-test hashes,
runs in a child process with credential-shaped environment names removed, and never invokes a
provider.

## Admitted scope

BootstrapFinetune observes the shared-LM multitask topology, per-predictor job topology, and
trace-call membership. It does not claim cross-runtime row-order parity. It also records DSPy
3.2.1's `pred_ind` loop-variable shadowing directly:
both predictor-specific requests receive both trace calls. Imp deliberately does not reproduce
that defect; stable predictor attribution yields one predictor's calls per job. The artifact labels
this as an intentional corrective deviation.

BetterTogether observes `p -> w -> p` parsing, baseline plus successful-prefix enumeration,
stable earlier-candidate tie selection with validation, and latest-successful-prefix selection
without validation. Shuffling is disabled in this fixture, so exact Python shuffle order is
explicitly excluded.

DSPy 3.2.1 computes an automatic holdout with `int(valset_ratio * len(trainset))`.
Independent execution of the pinned runtime confirms that its default ratio therefore produces
an empty validation set for one through nine rows and falls into latest-prefix selection. Imp
treats that truncation as incidental: with two or more rows and a positive ratio it keeps at
least one validation row, while retaining a lone row for training when no split is possible.
This BEAM-native correction has direct consumer coverage; it is outside the admitted shared C1
observations and is not evidence of BetterTogether effectiveness.

Imp's aggregate launch/cancellation deadlines for BootstrapFinetune and bounded asynchronous
training lifecycle for BetterTogether are recorded as BEAM-native extensions. They are not
represented as upstream matches.

Neither family claims provider behavior, model effectiveness, training-result quality, full
optimizer parity, or any paid-provider result.

## Capture and admission

After these tranche files are committed in a clean checkout, capture the family artifacts with:

```sh
mix imp.benchmark.bootstrap_finetune_differential
mix imp.benchmark.better_together_differential
```

The tasks refuse dirty-source capture and bind the committed Imp optimizer, task, sidecar, fixture,
authority manifest, and authority ledger hashes. Registry admission remains a separate step: this
tranche intentionally does not edit the shared claims, authorities, reproductions, or dashboard
registries while parallel work is active.

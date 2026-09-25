# Matched instruction-family IFBench comparison

This is the bounded second-task design for Imp's instruction optimizers. Its
DSPy side, `usefulness_upstream.py`, imports `ifbench_stock_module.py` from
`examples/matched_gepa_mipro_ifbench_gepa014/`, an earlier experiment that is
no longer in this repository, so it does not run from this checkout. It is
not launchable yet in any case: `contract-draft.json` deliberately grants no network
authority until the Imp and pinned DSPy 3.2.1 programs produce the same task
messages and each optimizer's legal call envelope has been executed without a
model.

The task is the pinned GEPA artifact's real two-stage IFBench program. Train,
selection, and untouched test rows retain upstream split ownership. A
deterministic constraint-ID round robin replaces the earlier ordered-prefix
slice, which overrepresented `combination:repeat_prompt`. The independent test
file intentionally contains different constraint families; that makes this a
source-disjoint generalization condition rather than another TREC receipt.

Build the frozen public rows from the already authenticated checkout:

```sh
python3 research/matched_instruction_family_ifbench/build_data.py \
  --gepa-root tmp/gepa-artifact
```

The comparison includes GEPA, MIPROv2, SIMBA, COPRO, and InferRules in Imp and
DSPy wherever the pinned public API exists. SignatureOptimizer is an explicitly
Imp-native control. DSPy COPRO scores its trainset and DSPy SIMBA exposes no
separate validation argument; the comparison preserves and reports those
semantics rather than pretending every optimizer has the same selector.

Completion can be negative. A family is not credited with effectiveness merely
because it ran, selected an artifact, or saved and loaded. Untouched outcomes,
paired uncertainty, exact costs, and family-specific deviations remain visible.

# Auto-Evaluation Differential

`mix imp.benchmark.auto_evaluation_contract` runs a provider-free behavioral differential for `Imp.Evaluate.SemanticF1` and `Imp.Evaluate.CompleteAndGrounded`.

The canonical manifest at `benchmarks/config/auto-evaluation-differential-v1.json` pins DSPy 3.2.1 commit `29448ae12756abdd14bd8796c819247ebb83673c`, its auto-evaluation source, and its upstream test by SHA-256. Scripted judgments isolate the deterministic contract: precision/recall clamping, harmonic-mean scoring, trace thresholds, decompositional fields, accepted input shapes, and independent completeness and groundedness calls. The run performs no provider or network calls.

```sh
mix imp.benchmark.auto_evaluation_contract --out benchmarks/runs/auto-evaluation-differential-v1.json
mix imp.benchmark.auto_evaluation_contract --validate benchmarks/runs/auto-evaluation-differential-v1.json
```

This T1 artifact establishes source-level behavioral fidelity only. It does not establish judge quality on natural data, model equivalence, or evaluation effectiveness.

# Matched GEPA and MIPROv2 on IFBench v2 (stopped)

This proposed treatment translates the pinned GEPA paper artifact's two-stage
IFBench task graph to stock DSPy 3.2.1's ordinary `Module.forward` contract.
It does not claim to execute the artifact class unmodified or reproduce the
paper. The permanently stopped v1 treatment and its baselines are not reused.

The translation retains the artifact's two named `ChainOfThought` predictors,
signatures, instructions, demos, configuration, and sequential dataflow. Its
deliberate mechanical differences are the top-level Python class and
serialization identity plus stock `Module.__call__` callback,
`caller_modules`, and usage instrumentation. The provider-free equivalence
gate verifies those differences add no task content, RNG consumption, metric
input, or provider call.

Run the gate from the repository root with the existing pinned source trees:

```sh
tmp/dspy-parity-venv/bin/python \
  examples/matched_gepa_mipro_ifbench_v2/equivalence_gate.py \
  --dspy-root tmp/dspy-3.2.1 \
  --gepa-root tmp/gepa-v0.1.4 \
  --gepa-artifact-root tmp/gepa-artifact \
  --modified-dspy-root tmp/gepa-study-dspy \
  --ifbench-site-packages tmp/ifbench-parity-venv/lib/python3.13/site-packages
```

The complete paired entry is `run_paired.py`. Its provider-free review mode
checks the clean Imp commit, every v2 coordinator/consumer/peer source digest,
the modified DSPy fork, the translation gate and its committed result without
passing provider authority or reading held-out bytes:

```sh
python3 examples/matched_gepa_mipro_ifbench_v2/run_paired.py --compatibility-only
```

The coordinator is the only launch entry. It captures the exact clean Imp
commit and passes it to both peers; each peer refuses a mismatch. Selection
receipts are persisted by both runtimes before either runtime may verify and
load the held-out split. On failure the coordinator gives both peers a bounded
graceful-stop window and requires cost-bearing stop artifacts from both.

The one authorized launch stopped during the first seed's upstream GEPA arm.
After baseline selection, stock DSPy evaluated a real proposed instruction but
several parse/evaluator failures left the pinned GEPA engine with fewer outputs
than examples; GEPA aborted with `IndexError: list index out of range`. The
coordinator immediately stopped Imp. Neither peer sealed all nine selections,
no selection receipt exists, and held-out bytes were never opened. The run is
incomplete and unscored, not an optimizer loss or effectiveness comparison.

The two peers reported exact provider costs of `$0.36730575` and
`$0.39300525`, totaling `$0.7603110000000001`; adding the prior conservative
workshop bound gives at most `$7.3626732500000001`. Their full stopped ledgers
and the two completed baseline artifacts are retained in this directory.
Upstream's rescue is internally complete. Imp's stopped artifact is fully
bound to the manifest, gate, and launch commit, but is deliberately not a
certified rescue: SIGTERM arrived with 194 reserved/transmitted calls, 194
transport events, and only 191 completed response records. The manifest is now
permanently non-launchable.

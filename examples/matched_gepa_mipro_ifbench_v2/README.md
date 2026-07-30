# Matched GEPA and MIPROv2 on IFBench v2 (unsealed)

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

`contract.json` is a review draft and is intentionally non-launchable. No
provider runner may receive network authority until the coordinator reviews
the compatibility contract, source bindings, gate result, and revised cost.
The current conservative workshop spend is at most `$6.60236225`; repeating
the complete treatment from zero has an unchanged `$74.552832` maximum and an
`$81.15519425 / $100` conservative aggregate maximum.

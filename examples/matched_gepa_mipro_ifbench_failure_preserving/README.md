# Future matched IFBench treatment: failure-preserving stock DSPy

This is a provider-disabled compatibility boundary, not a sealed experiment.
The terminal v2 treatment at `../matched_gepa_mipro_ifbench_v2` remains
permanently stopped, incomplete, and unscored. No calls, baselines, selections,
or outcomes roll forward.

The proposed successor would retain v2's stock-DSPy-adapted two-stage IFBench
task graph, data splits, scorer, messages, models, seeds, optimizer settings,
semantic stopping rules, budgets, and held-out barrier. Its sole algorithmic
compatibility declaration is explicit: the upstream GEPA arm uses
`scripts/dspy_gepa_failure_compat.py`, which repairs DSPy 3.2.1 trace output
cardinality for program and metric exceptions. Every requested example retains
one ordered output, `failure_score`, and structured error evidence. Arbitrary
exceptions are diagnostic-only and cannot enter reflection. DSPy's existing
`add_format_failure_as_feedback` parse-error opt-in is unchanged. Baseline and
MIPROv2 continue through unpatched stock DSPy 3.2.1.

This is therefore a **patched stock-DSPy compatibility-layer comparison**, not
an unmodified DSPy 3.2.1 run, an unmodified GEPA paper artifact, or a paper
reproduction. `upstream_compat.py` is the only allowed future compile entry for
the GEPA arm. Provider launch remains forbidden until a new manifest binds an
exact clean commit, all runner and gate hashes, current catalog/privacy/cost
truth, and receives independent seal review.

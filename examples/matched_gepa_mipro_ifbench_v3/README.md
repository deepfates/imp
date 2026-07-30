# Matched IFBench v3: provider-disabled runnable boundary

This is a complete provider-disabled runnable surface, not a sealed experiment.
The terminal v2 treatment at `../matched_gepa_mipro_ifbench_v2` remains
permanently stopped, incomplete, and unscored. No calls, baselines, selections,
or outcomes roll forward.

This separately named successor retains v2's stock-DSPy-adapted two-stage IFBench
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
reproduction. `run_upstream.py` scopes the compatibility layer only around the
GEPA compile call; the coordinator is the only launch entry and both direct
peers reject a missing or mismatched exact commit before provider work.

`python3 examples/matched_gepa_mipro_ifbench_v3/run_paired.py --compatibility-only`
reruns both content-bound provider-free gates from a clean checkout. It never
receives provider authority and does not read held-out bytes. Provider launch
remains forbidden until the manifest binds an exact clean commit, all runner
and gate hashes, current catalog/privacy/cost truth, and receives a new
independent seal review.

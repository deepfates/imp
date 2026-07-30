# Matched IFBench v3 (stopped)

This was a separately sealed matched treatment. Its single authorized launch is
permanently stopped, incomplete, and unscored.
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
receives provider authority and does not read held-out bytes.

The one authorized launch stopped during the first seed's upstream GEPA arm.
Both peers completed and sealed the baseline selection stage. The upstream
public `dspy.GEPA.compile` path then passed `acceptance_criterion` to the pinned
GEPA optimizer, whose `optimize` entry does not accept that keyword, and raised
`TypeError` before its first GEPA model call. The coordinator gracefully stopped
Imp. Neither peer sealed all nine selections, held-out bytes were never opened,
and no arm is scored; this is a public-workflow compatibility failure, not an
optimizer loss or effectiveness result.

The peers report completed-response costs of `$0.11817375` for Imp and
`$0.10520175000000005` upstream, totaling `$0.22337550000000005`. Imp was
stopped with one transmitted request still in flight, retained separately from
68 completed responses; the full 69-call reservation was `$0.490176`.
Upstream retained 63 transmitted/completed responses and a `$0.447552`
reservation. The full stopped ledgers and sealed baseline artifacts are kept in
this directory. Provider authority is closed and this treatment must not be
resumed or rerun.

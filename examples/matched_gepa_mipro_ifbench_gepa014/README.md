# Matched IFBench successor: DSPy 3.2.1 + GEPA 0.1.4

This directory contains the permanently stopped, zero-call successor to the v3
matched IFBench treatment. Its live attempt at commit `6579ec6` made no model
transport and spent `$0`: the authenticated upstream peer rejected conflicting
GEPA distribution metadata, and its Imp peer was terminated during catalog
verification. The two stopped result files remain immutable under `tmp/`; this
surface no longer grants provider authority and cannot be relaunched.

The only semantic compatibility change is authenticated source composition:
the exact DSPy 3.2.1 source is loaded with the exact GEPA 0.1.4 source before
either package is imported. No option is dropped or translated. In particular,
`acceptance_criterion: strict_improvement` reaches GEPA 0.1.4 unchanged.
The effective GEPA identity is the imported module path plus the authenticated
source commit/tree/content and `gepa.optimize` signature. The checkout's stale
`0.1.3` egg-info and DSPy's installed `0.0.27` distribution are retained as
diagnostic environment facts; neither is allowed to override the loaded source.

Pinned DSPy 3.2.1 MIPRO evaluator containment is also unchanged: an ordinary
candidate evaluation `Exception` produces that candidate's zero score. This is
matched-upstream behavior for this comparison, not Imp's general error policy.
Typed route, model identity, privacy, transport, attempt, token, cost, and
budget guards remain fatal `OperationalSafetyAbort` values outside that
containment boundary.

The scientific task, rows, seeds, messages, routes, budgets, optimizer
opportunity, metrics, held-out barrier, and negative-result acceptance are
copied exactly from v3 and content-bound in `contract-draft.json`. The held-out
file remained unopened.

`run_paired.py --shadow-only` is the provider-free production-boundary check.
It starts the exact peer commands in cold processes with no provider credential,
authenticates the same source/import/bootstrap paths, starts Imp's required
transport applications explicitly, and drives one task plus one optimizer call
per runtime through an owned local TLS/OpenAI-compatible server. This replaces
the former metadata-only `--no-start` preflight, then shuts down the server and
verifies its transport ledger. It is an engineering check, not a treatment.

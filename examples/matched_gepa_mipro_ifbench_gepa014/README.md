# Matched IFBench successor: DSPy 3.2.1 + GEPA 0.1.4

This directory contains an **unsealed, provider-disabled successor manifest**
for the permanently stopped v3 matched IFBench treatment. It does not authorize
network access and does not reuse any v2/v3 baseline, selection, artifact, or
outcome.

The only semantic compatibility change is authenticated source composition:
the exact DSPy 3.2.1 source is loaded with the exact GEPA 0.1.4 source before
either package is imported. No option is dropped or translated. In particular,
`acceptance_criterion: strict_improvement` reaches GEPA 0.1.4 unchanged.

Pinned DSPy 3.2.1 MIPRO evaluator containment is also unchanged: an ordinary
candidate evaluation `Exception` produces that candidate's zero score. This is
matched-upstream behavior for this comparison, not Imp's general error policy.
Typed route, model identity, privacy, transport, attempt, token, cost, and
budget guards remain fatal `OperationalSafetyAbort` values outside that
containment boundary.

The scientific task, rows, seeds, messages, routes, budgets, optimizer
opportunity, metrics, held-out barrier, and negative-result acceptance are
copied exactly from v3 and content-bound in `contract-draft.json`. The held-out
file remains unopened. A later seal must bind a clean launch commit and complete
paired runnable surface before any provider authority can exist.


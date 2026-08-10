---
id: imp-u3af
status: closed
deps: [imp-90uc, imp-g22q, imp-emrr, imp-pk5c, imp-nbyg, imp-7aah, imp-sqkr]
links: []
created: 2026-08-07T18:49:14Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [benchmarks, pilot, preregistration]
---
# In-band matched pilot before Heavy spend

One small matched cell (few dollars) run AFTER the gate fixes, with the expected result band preregistered from DSPy's known behavior on the task. In-band → the Heavy run is confirmation and confidence in a favorable result is justified; out-of-band → we found the defect at pilot price instead of campaign price.

## Acceptance Criteria

Preregistered prediction band written before launch; pilot completes both arms; result compared to band with a written verdict; out-of-band triggers defect hunt, not a bigger run.


## Notes

**2026-08-10T02:21:57Z**

PILOT COMPLETE (2026-08-09): 18/18 cells, P1 pass; P2/P3 not evaluable — bands were tighter than the measured noise floor (preregistration design error, disclosed in the final verdict addendum). Adversarially-verified findings: imp chain integrity clean; runtime row-level parity PASS (192 paired rows p=0.164); neither optimizer moved (upstream stock 9/9, imp evolved champions noise-equal); root cause = sealed 1024-token cap (vs source's explicit 16384) + 2%-of-paper budget. Full verdict in PREREGISTRATION.md; corrected successor parameters in HEAVY_DESIGN_DRAFT.md (realistic ~$150-300; reservation policy is the binding redesign). Total pilot spend ~$8.

---
id: imp-94ax
status: open
deps: [imp-88sn]
links: []
created: 2026-08-09T16:00:58Z
type: feature
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [benchmarks, economics, resume, preregistration]
---
# Preregister the resume-economics comparison (BEAM durability as its own claim)

Imp's durable-checkpoint resume (replay verified work free; upstream gepa v0.1.4 resets its evaluation cache and re-pays) is a genuine BEAM differentiator — deliberately DISABLED (resume_cache: :drop) in the matched fidelity campaign so it cannot confound the optimizer-parity claim. Measure it as its own preregistered claim: under a fixed interruption schedule (kill both arms at preregistered points), imp reaches equal optimization quality at lower total spend because resume replays fingerprint-verified work while upstream re-evaluates. Publishable precisely because the fidelity comparison beside it ran with the advantage off.

## Acceptance Criteria

Preregistered protocol (interruption schedule, spend accounting, quality bar) written before launch; both arms run under it; result reported as cost-to-quality curves with the resume ledger disclosed.


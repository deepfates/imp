---
id: imp-v03h
status: closed
deps: []
links: []
created: 2026-08-21T04:50:53Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [budgets, telemetry, optimizers, product]
---
# Make live optimizer spend and usage a public program capability

Imp's provider-backed optimization paths need one public, semver'd boundary for prospective request/token/USD reservation, actual provider usage reconciliation, retry attribution, and a durable audit snapshot. Today equivalent machinery is partly optimizer-specific and partly hidden in benchmark-only Imp.BenchmarkTruth code. This is a product capability: users should be able to bound and inspect optimization spend without adopting a benchmark runner.

## Acceptance Criteria

An ordinary public optimizer workflow can declare request/input/output/USD ceilings; every provider attempt is prospectively reserved; reported usage and cost are reconciled; ambiguous started work is conservatively charged; cap violations fail closed with structured data; retries cannot escape accounting; the selected Artifact retains the ledger through selection and the Result retains the final post-test ledger; docs and provider-free perturbation tests cover success, retry, timeout, crash, and over-cap behavior.

## Notes

**2026-08-21T05:08:00Z**

Implemented at the packaged runtime boundary. The former benchmark-only
CampaignBudget/BudgetedLM implementation now lives as documented
`Imp.Optimizer.Budget` and `Imp.LM.Budgeted`, with facade constructors. Each
public wrapper call records only its own process-scoped ReqLLM telemetry,
enforces one actual Req transport attempt, and shares concurrent reservations
safely; source-checkout benchmark modules delegate through a compatibility shim
without double-counting. `Imp.Experiment.check/5` accepts `:budget`, puts the
through-selection snapshot in the selected credential-free Artifact, and puts
the final post-test snapshot in Result provenance.

Verification: production compile with warnings as errors; focused 55 tests;
unpacked package 14/14; full `mix fast.check` with 53 doctests, 9 properties,
and 2,753 tests, zero failures (10 skipped). The first broad run exposed an
unrelated async build-lock stdout race in a fresh-process OA test; making that
module non-async removed the shared-build race and the complete rerun passed.

---
id: imp-v03h
status: open
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

An ordinary public optimizer workflow can declare request/input/output/USD ceilings; every provider attempt is prospectively reserved; reported usage and cost are reconciled; ambiguous started work is conservatively charged; cap violations fail closed with structured data; retries cannot escape accounting; Result/Artifact reports retain the final ledger; docs and provider-free perturbation tests cover success, retry, timeout, crash, and over-cap behavior.


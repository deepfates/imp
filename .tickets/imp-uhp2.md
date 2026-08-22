---
id: imp-uhp2
status: open
deps: [imp-7yim]
links: []
created: 2026-08-22T13:38:12Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [providers, streaming, tools, operations]
---
# Exercise realistic composed programs across providers and OTP failures

Exercise the product as a real BEAM application: composed named predictors and tools, materially different live provider routes, streaming where supported, bounded work, persistence, restart, concurrency, supervision, and observable failure. Repair ordinary-path defects rather than treating transport demos or isolated unit seams as completion.

## Acceptance Criteria

At least two materially different supported provider routes execute representative composed programs; named predictor updates and tool calls survive composition; supported streaming is genuinely incremental and unsupported cases fail loudly; budgets, usage, retries, timeouts, cancellation, provider errors, and partial failures are observable and bounded; selected state persists without credentials and reloads after a fresh process restart; concurrent supervised service preserves isolation and recovery; tests include adversarial failure injection without relying on maintainer-only machinery.

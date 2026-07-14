# Public Claim Inventory

`benchmarks/claims.json` is the machine-readable inventory of public DSEx
release claims. The benchmark dashboard evaluates that file alongside the
evidence lanes and adds a `public_claims` release-gate check.

This inventory governs full parity, comparative effectiveness, and benchmark
claims. It is additive to the scoped v0.1 product contract in
`docs/V0_1_RELEASE_LEDGER.md`; deferred research rows may keep
`benchmark.dashboard.telos.full` red without invalidating a product-only v0.1
candidate, provided those claims are not presented as current capabilities.

The rule is simple: v0.1 release-blocking claims must trace to fresh passing
evidence before `mix benchmark.dashboard.full` passes. Broader telos claims
must trace to fresh passing evidence before `mix benchmark.dashboard.telos.full`
passes. Claims that are true only for a narrower path must say so in the claim
statement and in the linked docs.

The inventory has two policy scopes. `v0.1` rows are scoped product claims for
the named APIs, workflows, and evidence cases in those rows. `telos` rows are
future research targets for comparative effectiveness, parity, or replication;
they remain release-blocking gaps and must not be read as current product
capabilities. A `full` requirement means full evidence for that row's precise
scope, not full parity for an entire subsystem or the whole upstream project.

## Shape

Each claim has:

- `id`: stable claim identifier.
- `statement`: the human-readable public claim.
- `category`: package, docs, parity, optimizer, performance, operations, or a
  similarly concrete release area.
- `surface`: the APIs or user stories covered by the claim.
- `claim_type`: feature completeness, conformance, live-provider proof,
  functional effectiveness, or performance.
- `comparison`: `dspy`, `dsex_native`, or a narrower comparison target.
- `decision`: `proven_target` or `active_gap` for the named release scope.
- `release`: the release whose policy owns the decision, such as `v0.1` or
  `post-v0.1`.
- `scope`: the precise boundary of the claim.
- `limitations`: explicit exclusions or evidence still required.
- `release_blocking`: whether this claim blocks the full dashboard for its
  release profile.
- `sources`: docs, tests, fixtures, or papers that explain the claim.
- `requirements`: evidence rows the dashboard can evaluate.

Requirements currently point at dashboard lanes and name the required evidence
level:

```json
{
  "id": "live_matched_model.full",
  "kind": "live_parity",
  "lane": "live_matched_model",
  "evidence": "full",
  "threshold": "required live lanes satisfy their policies"
}
```

`"evidence": "full"` requires the lane to report `full_evidence: true`.
`"evidence": "passing"` is reserved for claims whose wording only promises
passing smoke or wiring evidence.

## Operating Loop

Run the dashboard before making release claims:

```sh
mix gate.package.evidence
mix gate.livebook.evidence
mix gate.protocol.evidence
mix gate.live_provider.evidence
mix benchmark.dashboard
mix benchmark.dashboard.full
mix benchmark.dashboard.telos
mix benchmark.dashboard.telos.full
```

The `gate.*.evidence` aliases run real source-checkout gates and write
`gate-evidence-*.json` artifacts under `tmp/gate-evidence/`. The dashboard
consumes those artifacts as the `product_package`, `livebook_execute`,
`protocol_gates`, and `live_provider_smoke` lanes. `gate.live_provider.evidence`
loads `.env` and sets `LIVE_PROVIDER=1`; it still requires provider credentials
in the ignored local `.env` file.

Live matched-model evidence also consumes `benchmarks/model_availability.json`
for documented external model unavailability. That file can unblock a historical
lane only when the historical endpoint itself is no longer a stable provider
baseline; it cannot replace current-model coverage.

RLM research claims require exact paper-scale authority. The checked-in RLM
protocol still marks the exact S-NIAH instances, BrowseComp+ query/document
selection, and OOLONG-Pairs scorer as unavailable with explicit acquisition
markers. T0 fixture replay, T1 operational contracts, and sampled T2 evidence
cannot be promoted to the exact T3 research claim while those authorities are
unavailable.

GEPA research claims use the `gepa_replication` lane, not the generic
`optimizer_lift` lane. The dashboard only accepts those claims when a fresh
non-smoke `gepa-replication-*.json` artifact covers the required GEPA paper
families and reports baseline, DSPy GEPA, DSEx GEPA, MIPROv2, metric-call
budget, token/cost, wall-clock, seed variance, and train/dev/test gap. The
dashboard recomputes full evidence from the row contract: campaign provenance,
dataset scope, split counts, dataset checksums, source commits, concrete
comparator sources, distinct split digests, and positive live token/cost
accounting are required. Capped `--max-per-split` dataset roots are explicitly
rejected for full GEPA claims. SIMBA may be reported as extra comparator
evidence when present, but it is not required by the upstream GEPA artifact.

Optimize Anything non-prompt effectiveness uses its own `optimize_anything`
lane. Full evidence requires executable code, agent-configuration, and
scheduling artifact families; at least three live provider-backed seeds per
family; positive mean held-out lift; a strict majority of improving runs;
positive usage and cost; and durable checkpoint provenance. Smoke artifacts
and authored comparator scores cannot authorize the claim. This lane proves
the scoped DSEx-native effectiveness statement, not paper-scale upstream
parity.

Local MLX weight-training effectiveness uses the `local_mlx_weight_training`
lane. Full evidence requires a clean, independently validated campaign over the
pinned Banking77 split and Qwen MLX snapshot, successful official fusion,
positive held-out accuracy and macro-F1 lift, and exact fused/save-load row
equivalence. This proves the local training and deployment substrate only; it
does not authorize paid-provider, BetterTogether, GRPO, or DSPy-matched parity.

Failure-recovery live evidence is limited to two required rows: provider retry,
timeout, and idempotency; and integration retrieval plus tool-agent recovery.
The campaign does not create or cancel a live provider training job, so its
failure-recovery policy makes no live provider-training claim.

When a profile-specific full dashboard fails, the terminal error names both the
blocking lane requirements and the blocked public claims. That failure is the
work queue for that profile: either produce the missing evidence, narrow or
remove the claim, or mark a genuinely impossible external dependency as
unavailable in the relevant evidence artifact.

Do not add a marketing or README claim without adding or updating a row in
`benchmarks/claims.json`. Do not mark a claim non-blocking merely because the
evidence is inconvenient. Unfinished telos work remains an `active_gap` and
release-blocking until its evidence passes. A claim may become non-blocking
only after an explicit product decision changes the telos, not as a way to make
the current dashboard green.

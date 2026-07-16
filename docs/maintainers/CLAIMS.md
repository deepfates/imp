# Claims And Proof Obligations

`benchmarks/claims.json` is the sole machine-readable inventory of public Imp
claims and research targets. It declares intended scope and proof obligations;
it never stores current status. The benchmark dashboard evaluates those
obligations against admitted artifacts and adds a `public_claims` profile-gate
check.

This inventory governs product, conformance, comparative effectiveness, and
benchmark claims. It is additive to the scoped product procedure in
`docs/maintainers/RELEASE.md`; deferred research rows may keep
`benchmark.dashboard.telos.ready` red without invalidating a product-only v0.1
candidate, provided those claims are not presented as current capabilities.

The rule is simple: v0.1 release-blocking claims must trace to fresh passing
evidence before `mix benchmark.dashboard.ready` passes. Broader telos claims
must trace to fresh passing evidence before `mix benchmark.dashboard.telos.ready`
passes. Claims that are true only for a narrower path must say so in the claim
statement and in the linked docs.

The inventory has two policy scopes. `v0.1` rows are scoped product claims for
the named APIs, workflows, and evidence cases in those rows. `telos` rows are
research targets for comparative effectiveness, conformance, or replication;
they remain blocking within the `telos` profile and must not be read as current
product capabilities. A `full` requirement means complete evidence for that
row's precise scope, not blanket parity for a subsystem or upstream project.

## Evidence Rungs

Every claim stops at an explicit rung:

| Rung | Meaning |
| --- | --- |
| C0 | The API exists and is callable. |
| C1 | Behavior conforms to a pinned authority for the declared scope. |
| C2 | The capability executes through its real operational boundary. |
| C3 | Held-out evidence supports effectiveness on the declared portfolio. |
| C4 | An exact paper protocol is reproduced from public authority. |
| C5 | Powered paired evidence supports comparative advantage. |

Higher rungs do not erase lower contracts. A C3 result cannot repair C1
semantic divergence, and an operational C2 sample cannot authorize an
effectiveness claim. Exact authority that is genuinely unavailable blocks only
the C4 claim; a separately named adapted protocol may still earn C3.

## Shape

Each claim has:

- `id`: stable claim identifier.
- `statement`: the human-readable public claim.
- `category`: package, docs, parity, optimizer, performance, operations, or a
  similarly concrete release area.
- `surface`: the APIs or user stories covered by the claim.
- `claim_type`: feature completeness, conformance, live-provider proof,
  functional effectiveness, or performance.
- `comparison`: `dspy`, `imp_native`, or a narrower comparison target.
- `claim_state`: `asserted`, `target`, or `retired`. This is intent, not proof.
- `target_rung`: the exact C0-C5 evidence rung required by the claim.
- `release`: the profile that owns the claim, such as `v0.1` or `telos`.
- `scope`: the precise boundary of the claim.
- `limitations`: explicit exclusions or evidence still required.
- `gate_policy`: `blocking` or `informational`. Informational claims remain
  visible but cannot block readiness.
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
mix benchmark.dashboard.ready
mix benchmark.dashboard.telos
mix benchmark.dashboard.telos.ready
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
families and reports baseline, DSPy GEPA, Imp GEPA, MIPROv2, metric-call
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
the scoped Imp-native effectiveness statement, not paper-scale upstream
parity.

Local MLX weight-training effectiveness uses the `local_mlx_weight_training`
lane. Full evidence requires a clean, independently validated campaign over the
pinned Banking77 split and Qwen MLX snapshot, successful official fusion,
positive held-out accuracy and macro-F1 lift, and exact fused/save-load row
equivalence. This proves the local training and deployment substrate only; it
does not authorize paid-provider, BetterTogether, GRPO, or DSPy-matched parity.

Failure-recovery operational evidence is limited to two required local rows:
provider-shaped timeout/retry/idempotency and integration retrieval plus exact
tool-agent failure/retry/submit recovery. The campaign uses injected local
transports, a static LM, and dummy canaries only. It makes no external-provider
or live provider-training claim.

RAG, tool, and agent evidence is split into individual C1 claims for the exact
provider-free RAG, ReAct, ReActV2, MCP import, agent policy, CodeAct,
ProgramOfThought, streaming, async, and credential-redaction rows. Exact DSPy
comparison is claimed only for memory RAG and successful ReAct lookup; the
other rows are explicitly Imp-native fixture contracts. Bounded HotPotQA
retrieval is a separate differential. The CC0 BFCL-shaped scorer check is only C1/T1
fixture agreement: independent Elixir and Python implementations score twelve
original positives and nine mutations. It executes neither official BFCL nor
DSPy scorer code and establishes no model generation/tool-selection quality,
official BFCL performance, or operational behavior. A separate C2 differential
executes an identical queued-action failure schedule through actual Imp and
source-authenticated DSPy 3.2.1 ReAct, but fixture-owned retry/idempotency and
an injected timeout exception do not establish model recovery effectiveness or
wall-clock timeout parity.
Historical selected live paths do not satisfy the C4 target.

When a profile gate fails, the terminal error names both the
blocking lane requirements and the blocked public claims. That failure is the
work queue for that profile: either produce the missing evidence, narrow or
remove the claim, or mark a genuinely impossible external dependency as
unavailable in the relevant evidence artifact.

Do not add a marketing or README claim without adding or updating a row in
`benchmarks/claims.json`. Do not duplicate current state in this file,
`benchmarks/reproductions.json`, or Markdown; regenerate the dashboard instead.
Do not mark a claim non-blocking merely because its evidence is inconvenient.
Unfinished telos work remains a `target` and blocking within that profile
until its proof obligation passes or an explicit product decision changes the
claim.
